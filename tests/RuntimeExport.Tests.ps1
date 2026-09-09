#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\RuntimeExport.ps1 - the A-side runtime
    bootstrap payload export (VC_redist, portable Verdaccio, runtime-winget
    entries, tool self-bootstrap snapshot).

.DESCRIPTION
    All downloads are MOCKED (Mock Invoke-OSyncDownload / Mock
    Invoke-OSyncWingetDownload) and npm is a fake npm.cmd prepended to PATH -
    unit tests never hit the network; the real downloads happen once in the
    QA evidence run. Everything runs under $TestDrive; the real
    config/manifests are never touched.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\RuntimeExport.Tests.ps1 -PassThru"
      pwsh      -NoProfile -Command "Invoke-Pester tests\RuntimeExport.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files are
    dot-sourced and helper functions are defined INSIDE BeforeAll; data
    shared with the It blocks uses $script: scope (same pattern as the other
    test files in this plan). The download mocks are defined in BeforeEach so
    every It gets a fresh invocation history.
#>

Describe 'RuntimeExport' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')

        # --- fake appInstaller artifacts ---
        # Only the VC_redist piece remains (user decision, 2026-09): the App
        # Installer chain (msixbundle/VCLibs/UI.Xaml) is no longer exported.
        $script:FakeVcredist = Join-Path $TestDrive 'fake-vcredist.exe'
        [System.IO.File]::WriteAllText($script:FakeVcredist, 'fake VC_redist payload', [System.Text.Encoding]::ASCII)

        # The hash that gets pinned into the test config.
        $script:FakeVcredistHash = Get-OSyncFileSha256 -Path $script:FakeVcredist

        # --- runtime-winget.txt fixtures ---
        $script:ValidRuntimeWinget = Join-Path $TestDrive 'runtime-winget-valid.txt'
        Set-Content -LiteralPath $script:ValidRuntimeWinget -Value @(
            '# Runtime bootstrap entries',
            'Python.Python.3.12@3.12.10',
            'OpenJS.NodeJS.LTS@24.19.0'
        ) -Encoding UTF8

        $script:NoPythonRuntimeWinget = Join-Path $TestDrive 'runtime-winget-nopython.txt'
        Set-Content -LiteralPath $script:NoPythonRuntimeWinget -Value @(
            '# Runtime bootstrap entries',
            'OpenJS.NodeJS.LTS@24.19.0'
        ) -Encoding UTF8

        $script:NoNodeRuntimeWinget = Join-Path $TestDrive 'runtime-winget-nonode.txt'
        Set-Content -LiteralPath $script:NoNodeRuntimeWinget -Value @(
            '# Runtime bootstrap entries',
            'Python.Python.3.12@3.12.10'
        ) -Encoding UTF8

        $script:NoRuntimeLines = Join-Path $TestDrive 'runtime-winget-empty.txt'
        Set-Content -LiteralPath $script:NoRuntimeLines -Value @(
            '# Runtime bootstrap entries',
            '7zip.7zip@26.02'
        ) -Encoding UTF8

        $script:WithFailingEntry = Join-Path $TestDrive 'runtime-winget-failing.txt'
        Set-Content -LiteralPath $script:WithFailingEntry -Value @(
            'Python.Python.3.12@3.12.10',
            'OpenJS.NodeJS.LTS@24.19.0',
            'Foo.Bar999@1.0.0'
        ) -Encoding UTF8

        # --- fake tool source dir (self-bootstrap snapshot source) ---
        $script:ToolSourceDir = Join-Path $TestDrive 'toolsrc'
        New-Item -ItemType Directory -Path (Join-Path $script:ToolSourceDir 'src\lib') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:ToolSourceDir 'config') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:ToolSourceDir 'src\lib\RuntimeExport.ps1') -Value 'fake lib' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ToolSourceDir 'config\packagesync.b.json') -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:ToolSourceDir 'README.md') -Value 'fake readme' -Encoding UTF8

        # --- fake npm.cmd: on `install` it creates the verdaccio layout in
        # --- the --prefix dir (the LAST argument, quoted) ---
        $script:fakeBin = Join-Path $TestDrive 'fake-bin'
        New-Item -ItemType Directory -Path $script:fakeBin -Force | Out-Null
        $fakeNpm = @'
@echo off
rem When FAKE_NPM_ARGSLOG is defined, append this invocation's args to it.
if defined FAKE_NPM_ARGSLOG echo %*>> "%FAKE_NPM_ARGSLOG%"
echo %* | findstr /C:"install" >nul
if errorlevel 1 exit /b %FAKE_NPM_EXIT%
for %%A in (%*) do set LAST=%%~A
if "%LAST%"=="" exit /b %FAKE_NPM_EXIT%
mkdir "%LAST%\node_modules\verdaccio\bin" 2>nul
echo fake > "%LAST%\node_modules\verdaccio\bin\verdaccio"
mkdir "%LAST%\node_modules\.bin" 2>nul
echo fake > "%LAST%\node_modules\.bin\verdaccio.cmd"
exit /b %FAKE_NPM_EXIT%
'@
        [System.IO.File]::WriteAllText((Join-Path $script:fakeBin 'npm.cmd'), $fakeNpm, [System.Text.Encoding]::ASCII)
        $env:FAKE_NPM_EXIT = '0'
        $script:originalPath = $env:PATH
        $env:PATH = $script:fakeBin + ';' + $env:PATH

        # --- test repo root (logs land here) ---
        $script:RepoRoot = Join-Path $TestDrive 'repo'

        # --- config builder ---
        function New-OTestConfig {
            param(
                [string]$RuntimeWhitelistPath = $script:ValidRuntimeWinget,
                [string]$RepoRoot = $script:RepoRoot,
                [string]$ToolSourceDir = $script:ToolSourceDir,
                [string[]]$PipDownloadArgs = @('--only-binary=:all:', '--platform', 'win_amd64', '--python-version', '3.12', '--implementation', 'cp', '--abi', 'cp312'),
                [string]$VcRedistSha256 = $script:FakeVcredistHash,
                [bool]$PipEnabled = $true,
                [bool]$NpmEnabled = $true
            )
            return [pscustomobject]@{
                role       = 'A'
                repoRoot   = $RepoRoot
                httpBind   = '127.0.0.1'
                httpPort   = 8788
                categories = [pscustomobject]@{ winget = $true; pip = $PipEnabled; npm = $NpmEnabled; dotfiles = $true }
                paths      = [pscustomobject]@{ runtimeWhitelist = $RuntimeWhitelistPath }
                winget     = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
                pip        = [pscustomobject]@{ downloadArgs = @($PipDownloadArgs) }
                pins       = [pscustomobject]@{
                    appInstaller = [pscustomobject]@{
                        vcRedistUrl    = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
                        vcRedistSha256 = $VcRedistSha256
                    }
                    npm = [pscustomobject]@{ verdaccioVersion = '6.10.2' }
                }
            }
        }

        # Captures a throwing call: returns the ErrorRecord or $null.
        function Invoke-OTestThrowing {
            param([scriptblock]$ScriptBlock)
            $caught = $null
            try { & $ScriptBlock }
            catch { $caught = $_ }
            return $caught
        }
    }

    AfterAll {
        $env:PATH = $script:originalPath
    }

    BeforeEach {
        # Fresh download mock per test: dispatches on the URI and copies the
        # matching fake artifact to $OutFile (parent dir creation included -
        # the real Invoke-OSyncDownload creates it too).
        Mock Invoke-OSyncDownload {
            $parent = Split-Path -Parent $OutFile
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            if ($Uri -match 'vc_redist') {
                Copy-Item -LiteralPath $script:FakeVcredist -Destination $OutFile -Force
            }
            else {
                throw "unexpected download URI in test mock: $Uri"
            }
        }

        # Fresh winget download mock: seeds the observed winget download
        # layout (YAML + sibling installer) into the --download-directory
        # (the LAST argument, quoted). Foo.Bar999 fails with exit 1.
        Mock Invoke-OSyncWingetDownload {
            $dir = [string]$Arguments[$Arguments.Count - 1]
            $dir = $dir.Trim('"')
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ($Arguments -contains 'Foo.Bar999') {
                return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = 'no package found' }
            }
            if ($Arguments -contains 'Python.Python.3.12') {
                $yaml = @(
                    'PackageIdentifier: Python.Python.3.12',
                    'PackageVersion: 3.12.10',
                    'Installers:',
                    '- Architecture: x64',
                    '  InstallerType: exe',
                    '  InstallerUrl: https://www.python.org/ftp/python/3.12.10/python-3.12.10-amd64.exe',
                    '  InstallerSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                ) -join "`r`n"
                [System.IO.File]::WriteAllText((Join-Path $dir 'Python_3.12.10_Machine_X64_exe_en-US.yaml'), $yaml, (New-Object System.Text.UTF8Encoding($true)))
                [System.IO.File]::WriteAllBytes((Join-Path $dir 'Python_3.12.10_Machine_X64_exe_en-US.exe'), [byte[]]@(1, 2, 3))
            }
            elseif ($Arguments -contains 'OpenJS.NodeJS.LTS') {
                $yaml = @(
                    'PackageIdentifier: OpenJS.NodeJS.LTS',
                    'PackageVersion: 24.19.0',
                    'Installers:',
                    '- Architecture: x64',
                    '  InstallerType: exe',
                    '  InstallerUrl: https://nodejs.org/dist/v24.19.0/node-v24.19.0-x64.msi',
                    '  InstallerSha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
                ) -join "`r`n"
                [System.IO.File]::WriteAllText((Join-Path $dir 'NodeJS_24.19.0_Machine_X64_msi_en-US.yaml'), $yaml, (New-Object System.Text.UTF8Encoding($true)))
                [System.IO.File]::WriteAllBytes((Join-Path $dir 'NodeJS_24.19.0_Machine_X64_msi_en-US.msi'), [byte[]]@(4, 5, 6))
            }
            else {
                return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = 'no such package' }
            }
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = 'ok' }
        }
    }

    Context 'Assert-OSyncRuntimeWinget - runtime whitelist validation' {
        It 'accepts a valid file (pip+npm enabled) and returns the python/node lines' {
            $result = Assert-OSyncRuntimeWinget -Path $script:ValidRuntimeWinget -Config (New-OTestConfig)
            $result.PythonLine | Should -Be 'Python.Python.3.12@3.12.10'
            $result.NodeLine | Should -Be 'OpenJS.NodeJS.LTS@24.19.0'
        }

        It 'throws when the file is missing' {
            $err = Invoke-OTestThrowing { Assert-OSyncRuntimeWinget -Path (Join-Path $TestDrive 'nope.txt') -Config (New-OTestConfig) }
            $err.Exception.Message | Should -Match 'not found'
        }

        It 'throws with an explicit error when the Python line is missing (pip enabled)' {
            $err = Invoke-OTestThrowing { Assert-OSyncRuntimeWinget -Path $script:NoPythonRuntimeWinget -Config (New-OTestConfig) }
            $err.Exception.Message | Should -Match 'Python\.Python\.3'
            $err.Exception.Message | Should -Match 'categories\.pip'
        }

        It 'throws with an explicit error when the Node line is missing (npm enabled)' {
            $err = Invoke-OTestThrowing { Assert-OSyncRuntimeWinget -Path $script:NoNodeRuntimeWinget -Config (New-OTestConfig) }
            $err.Exception.Message | Should -Match 'OpenJS\.NodeJS'
            $err.Exception.Message | Should -Match 'categories\.npm'
        }

        It 'exempts the not-needed entries when only winget/dotfiles are enabled' {
            $config = New-OTestConfig -PipEnabled $false -NpmEnabled $false
            $result = Assert-OSyncRuntimeWinget -Path $script:NoRuntimeLines -Config $config
            $result.PythonLine | Should -BeNullOrEmpty
            $result.NodeLine | Should -BeNullOrEmpty
        }

        It 'requires only the Python line when npm is disabled' {
            $config = New-OTestConfig -PipEnabled $true -NpmEnabled $false
            $result = Assert-OSyncRuntimeWinget -Path $script:NoNodeRuntimeWinget -Config $config
            $result.PythonLine | Should -Be 'Python.Python.3.12@3.12.10'
            $result.NodeLine | Should -BeNullOrEmpty
        }
    }

    Context 'Test-OSyncPipCrossAssertion - pip args vs runtime Python' {
        It 'matches when --python-version and --abi agree with the runtime Python' {
            $r = Test-OSyncPipCrossAssertion -DownloadArgs @('--python-version', '3.12', '--abi', 'cp312') -RuntimePythonVersion '3.12.10'
            $r.Match | Should -BeTrue
            $r.RuntimePython | Should -Be '3.12'
        }

        It 'fails when --python-version disagrees' {
            $r = Test-OSyncPipCrossAssertion -DownloadArgs @('--python-version', '3.11', '--abi', 'cp312') -RuntimePythonVersion '3.12.10'
            $r.Match | Should -BeFalse
            $r.Reason | Should -Match '3\.11'
        }

        It 'fails when --abi disagrees' {
            $r = Test-OSyncPipCrossAssertion -DownloadArgs @('--python-version', '3.12', '--abi', 'cp311') -RuntimePythonVersion '3.12.10'
            $r.Match | Should -BeFalse
            $r.Reason | Should -Match 'cp311'
        }

        It 'falls back to the pinned defaults (3.12/cp312) when the args are missing' {
            $r = Test-OSyncPipCrossAssertion -DownloadArgs @('--only-binary=:all:') -RuntimePythonVersion '3.12.10'
            $r.Match | Should -BeTrue
            $r.PythonVersion | Should -Be '3.12'
            $r.Abi | Should -Be 'cp312'
        }

        It 'fails when there is no Python line to compare against' {
            $r = Test-OSyncPipCrossAssertion -DownloadArgs @('--python-version', '3.12', '--abi', 'cp312') -RuntimePythonVersion $null
            $r.Match | Should -BeFalse
        }
    }

    Context 'Export-OSyncRuntime - happy path (all mocked)' {
        It 'exports the full payload and returns a SINGLE report object (no leaked log paths)' {
            $staging = Join-Path $TestDrive 'staging-happy'
            $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $report -is [System.Array] | Should -BeFalse
            $report.GetType().Name | Should -Be 'PSCustomObject'
            @($report).Count | Should -Be 1
            @($report | Where-Object { $_ -is [string] }).Count | Should -Be 0
            $report.category | Should -Be 'runtime'
            $report.status | Should -Be 'ok'
        }

        It 'lands Python/Node dirs under <staging>\winget with rewritten leak-free YAML' {
            $staging = Join-Path $TestDrive 'staging-winget'
            $null = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $pythonYaml = Join-Path $staging 'winget\Python.Python.3.12\Python_3.12.10_Machine_X64_exe_en-US.yaml'
            $nodeYaml = Join-Path $staging 'winget\OpenJS.NodeJS.LTS\NodeJS_24.19.0_Machine_X64_msi_en-US.yaml'
            Test-Path -LiteralPath $pythonYaml -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath $nodeYaml -PathType Leaf | Should -BeTrue

            $pythonText = [System.IO.File]::ReadAllText($pythonYaml, [System.Text.Encoding]::UTF8)
            $nodeText = [System.IO.File]::ReadAllText($nodeYaml, [System.Text.Encoding]::UTF8)
            Test-OSyncWingetYamlNoLeak -Text $pythonText | Should -BeTrue
            Test-OSyncWingetYamlNoLeak -Text $nodeText | Should -BeTrue
            $pythonText -match 'http://127\.0\.0\.1:8788/winget/Python\.Python\.3\.12/Python_3\.12\.10_Machine_X64_exe_en-US\.exe' | Should -BeTrue
            $nodeText -match 'http://127\.0\.0\.1:8788/winget/OpenJS\.NodeJS\.LTS/NodeJS_24\.19\.0_Machine_X64_msi_en-US\.msi' | Should -BeTrue

            # NO packages.txt may be written by the runtime export (the
            # winget category owns it; runtime entries are tracked by
            # runtime\runtime-winget.txt).
            Test-Path -LiteralPath (Join-Path $staging 'winget\packages.txt') | Should -BeFalse
        }

        It 'stages the VC_redist piece with a passing hash (App Installer chain no longer exported)' {
            $staging = Join-Path $TestDrive 'staging-appinstaller'
            $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $dir = Join-Path $staging 'runtime\appinstaller'
            Test-Path -LiteralPath (Join-Path $dir 'VC_redist.x64.exe') -PathType Leaf | Should -BeTrue
            # The App Installer pieces are NOT exported anymore.
            Test-Path -LiteralPath (Join-Path $dir 'Microsoft.DesktopAppInstaller.msixbundle') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $dir 'Microsoft.VCLibs.x64.14.00.Desktop.appx') | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $dir 'Microsoft.UI.Xaml.2.8.appx') | Should -BeFalse

            $report.appInstaller.pieces.Count | Should -Be 1
            $report.appInstaller.pieces[0].Name | Should -Be 'vcredist'
            $report.appInstaller.pieces[0].Sha256 | Should -Be $script:FakeVcredistHash
        }

        It 'copies runtime-winget.txt into the runtime payload' {
            $staging = Join-Path $TestDrive 'staging-txt'
            $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $target = Join-Path $staging 'runtime\runtime-winget.txt'
            Test-Path -LiteralPath $target -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $target -Raw) | Should -Be (Get-Content -LiteralPath $script:ValidRuntimeWinget -Raw)
            $report.runtimeWingetTxt | Should -Be $target
        }

        It 'snapshots the tool: src tree + packagesync.b.json + README.md' {
            $staging = Join-Path $TestDrive 'staging-tool'
            $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            Test-Path -LiteralPath (Join-Path $staging 'runtime\tool\src\lib\RuntimeExport.ps1') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $staging 'runtime\tool\packagesync.b.json') -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $staging 'runtime\tool\README.md') -PathType Leaf | Should -BeTrue
            $report.tool.src | Should -Be (Join-Path $staging 'runtime\tool\src')
        }

        It 'stages the portable Verdaccio with node_modules\verdaccio\bin\verdaccio' {
            $staging = Join-Path $TestDrive 'staging-verdaccio'
            $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $bin = Join-Path $staging 'runtime\verdaccio\node_modules\verdaccio\bin\verdaccio'
            Test-Path -LiteralPath $bin -PathType Leaf | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $staging 'runtime\verdaccio\node_modules\.bin\verdaccio.cmd') -PathType Leaf | Should -BeTrue
            $report.verdaccio.version | Should -Be '6.10.2'
            $report.verdaccio.bin | Should -Be $bin
            $report.verdaccio.launch | Should -Match 'node\.exe'
            # The temp build dir is removed after the robocopy.
            Test-Path -LiteralPath (Join-Path $staging 'runtime\.verdaccio-build') | Should -BeFalse
        }

        It 'reports the pip cross-assertion result in the report' {
            $staging = Join-Path $TestDrive 'staging-cross'
            $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $report.pipCrossAssert.Match | Should -BeTrue
            $report.runtimeWinget.python | Should -Be '3.12.10'
            $report.runtimeWinget.node | Should -Be '24.19.0'
        }
    }

    Context 'Export-OSyncRuntime - hash gate paths' {
        It 'PIN-ME prints the actual hash and exits non-zero BEFORE any winget download' {
            $staging = Join-Path $TestDrive 'staging-pinme'
            # Behavior proof: if the export tried to download winget packages
            # before the PIN-ME gate, this mock throws and the test fails.
            Mock Invoke-OSyncWingetDownload { throw 'Invoke-OSyncWingetDownload must not be called before the PIN-ME gate' }

            $err = Invoke-OTestThrowing {
                Export-OSyncRuntime -Config (New-OTestConfig -VcRedistSha256 'PIN-ME') -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir
            }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -Match 'PIN-ME'
            $err.Exception.Message | Should -Match ('vcredist={0}' -f $script:FakeVcredistHash)
        }

        It 'aborts naming the file when the piece hash is corrupted' {
            $staging = Join-Path $TestDrive 'staging-mismatch'
            $wrong = ('a' * 64)
            $err = Invoke-OTestThrowing {
                Export-OSyncRuntime -Config (New-OTestConfig -VcRedistSha256 $wrong) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir
            }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -Match 'mismatch'
            $err.Exception.Message | Should -Match 'VC_redist\.x64\.exe'
            $err.Exception.Message | Should -Match $wrong
        }
    }

    Context 'Export-OSyncRuntime - cross-assertion failure' {
        It 'fails the export BEFORE any download when pip args disagree with the runtime Python' {
            $staging = Join-Path $TestDrive 'staging-crossfail'
            Mock Invoke-OSyncDownload { throw 'Invoke-OSyncDownload must not be called before the cross-assertion' }
            Mock Invoke-OSyncWingetDownload { throw 'Invoke-OSyncWingetDownload must not be called before the cross-assertion' }

            $err = Invoke-OTestThrowing {
                Export-OSyncRuntime -Config (New-OTestConfig -PipDownloadArgs @('--python-version', '3.11', '--abi', 'cp311')) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir
            }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -Match 'cross-assertion'
            $err.Exception.Message | Should -Match '3\.11'
        }
    }

    Context 'Export-OSyncRuntime - per-package winget failure handling' {
        It 'records a failing runtime entry and still exports the others' {
            $staging = Join-Path $TestDrive 'staging-wingetfail'
            $report = Export-OSyncRuntime -Config (New-OTestConfig -RuntimeWhitelistPath $script:WithFailingEntry) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

            $report.status | Should -Be 'ok'
            $report.runtimeWinget.failed.Count | Should -Be 1
            $report.runtimeWinget.failed[0].Id | Should -Be 'Foo.Bar999'
            $report.runtimeWinget.exported.Count | Should -Be 2
            Test-Path -LiteralPath (Join-Path $staging 'winget\Python.Python.3.12') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $staging 'winget\OpenJS.NodeJS.LTS') | Should -BeTrue
        }
    }

    Context 'Export-OSyncRuntime - portable Verdaccio build dir (local npm prefix)' {
        # npm's arborist 'realpathCached' infinitely recurses on UNC prefixes
        # (RangeError: Maximum call stack size exceeded), so the portable
        # Verdaccio npm install must run with a LOCAL --prefix even when the
        # staging dir is UNC; <staging>\runtime\verdaccio is only ever written
        # via robocopy. The build-dir selection is a helper so it can be
        # unit-tested directly (the full flow cannot reach the npm install
        # with a fake UNC staging - the earlier appInstaller/winget steps
        # write into staging).
        It 'derives the build dir as a fresh non-UNC path under the OS temp dir' {
            $dir = Get-ORuntimeVerdaccioBuildDir
            try {
                $dir | Should -Not -BeNullOrEmpty
                $dir | Should -Not -Match '^\\\\'
                $dir | Should -BeLike ('{0}*' -f [System.IO.Path]::GetTempPath())
                $dir | Should -BeLike '*osync-runtime-verdaccio-*'
                Test-Path -LiteralPath $dir -PathType Container | Should -BeTrue
            }
            finally {
                if (Test-Path -LiteralPath $dir -PathType Container) {
                    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        It 'returns a distinct build dir on every call' {
            $a = Get-ORuntimeVerdaccioBuildDir
            $b = Get-ORuntimeVerdaccioBuildDir
            try {
                $a | Should -Not -Be $b
            }
            finally {
                Remove-Item -LiteralPath $a -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $b -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        It 'runs the portable Verdaccio npm install with a LOCAL --prefix (never under staging)' {
            $argsLogDir = Join-Path $TestDrive 'verdaccio-build'
            New-Item -ItemType Directory -Path $argsLogDir -Force | Out-Null
            $argsLog = Join-Path $argsLogDir 'npm-args.log'
            $env:FAKE_NPM_ARGSLOG = $argsLog
            try {
                $staging = Join-Path $TestDrive 'staging-localprefix'
                $report = Export-OSyncRuntime -Config (New-OTestConfig) -StagingDir $staging -WingetExePath 'C:\fake\winget.exe' -ToolSourceDir $script:ToolSourceDir

                # The payload still lands at <staging>\runtime\verdaccio via
                # robocopy, and no build dir remains under staging.
                $bin = Join-Path $staging 'runtime\verdaccio\node_modules\verdaccio\bin\verdaccio'
                Test-Path -LiteralPath $bin -PathType Leaf | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $staging 'runtime\.verdaccio-build') | Should -BeFalse
                $report.verdaccio.dir | Should -Be (Join-Path $staging 'runtime\verdaccio')

                # The npm invocation's --prefix must be a LOCAL scratch dir:
                # never under the staging dir (TestDrive itself lives under
                # %TEMP%, so "under temp" alone would not discriminate).
                $installLine = @(Get-Content -LiteralPath $argsLog -ErrorAction Stop |
                    Where-Object { $_ -like 'install *--prefix*' } | Select-Object -Last 1)
                $installLine.Count | Should -Be 1
                $prefix = [regex]::Match($installLine[0], '--prefix\s+(\S+)').Groups[1].Value
                $prefix | Should -Not -Be ''
                $prefix | Should -Not -Match '^\\\\'
                $prefix | Should -Not -BeLike ('{0}*' -f $staging)
                $prefix | Should -BeLike '*osync-runtime-verdaccio-*'
            }
            finally {
                Remove-Item Env:FAKE_NPM_ARGSLOG -ErrorAction SilentlyContinue
            }
        }
    }
}