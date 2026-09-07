#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\PipExport.ps1 - the A-side pip wheel-repo
    export.

.DESCRIPTION
    All pip invocations are MOCKED (Mock Invoke-OSyncPipDownload / Mock
    Resolve-OSyncPython) - no network access and no real python needed.
    Everything runs under $TestDrive; the real config/manifests are never
    touched.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\PipExport.Tests.ps1 -PassThru"
      pwsh      -NoProfile -Command "Invoke-Pester tests\PipExport.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files are
    dot-sourced and helper functions are defined INSIDE BeforeAll; data shared
    with the It blocks uses $script: scope (same pattern as the other test
    files in this plan).
#>

Describe 'PipExport' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')

        # The pinned B-side default (plan todo 7): only-binary + win_amd64 /
        # Python 3.12 / cp312. Get-OSyncPipDownloadArgs must reproduce it
        # when the config supplies no args.
        $script:DefaultArgs = @(
            '--only-binary=:all:',
            '--platform', 'win_amd64',
            '--python-version', '3.12',
            '--implementation', 'cp',
            '--abi', 'cp312'
        )

        # Test repo root with manifests\requirements.txt (paths.* are
        # repo-root-relative by the config contract).
        $script:RepoRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:RepoRoot 'manifests') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:RepoRoot 'manifests\requirements.txt') -Value @('six==1.17.0', 'isodate==0.7.2') -Encoding UTF8
        $script:RequirementsPath = Join-Path $script:RepoRoot 'manifests\requirements.txt'

        # Minimal valid config shape consumed by Export-OSyncPip
        # (Get-OSyncConfig validation is todo-11 territory).
        function New-OTestConfig {
            param(
                [string]$RepoRoot = $script:RepoRoot,
                [bool]$AllowSdist = $false,
                [string[]]$DownloadArgs = $script:DefaultArgs
            )
            return [pscustomobject]@{
                role      = 'A'
                repoRoot  = $RepoRoot
                stateDir  = Join-Path $RepoRoot 'state'
                paths     = [pscustomobject]@{ requirements = 'manifests\requirements.txt' }
                pip       = [pscustomobject]@{
                    downloadArgs  = $DownloadArgs
                    upgradeOnApply = $true
                    allowSdist    = $AllowSdist
                }
            }
        }
    }

    Context 'Get-OSyncPipDownloadArgs - argument assembly' {
        It 'returns the pinned B-side platform default when no args are supplied' {
            $args = Get-OSyncPipDownloadArgs -DownloadArgs @()
            $args.Count | Should -Be 9
            ($args -join ' ') | Should -Be ($script:DefaultArgs -join ' ')
            $args | Should -Contain '--only-binary=:all:'
            $args | Should -Contain 'win_amd64'
            $args | Should -Contain '3.12'
            $args | Should -Contain 'cp312'
        }

        It 'returns the built-in default for a null config value (pin never dropped)' {
            $args = Get-OSyncPipDownloadArgs -DownloadArgs $null
            ($args -join ' ') | Should -Be ($script:DefaultArgs -join ' ')
        }

        It 'passes caller-supplied args through verbatim' {
            $custom = @('--only-binary=:all:', '--platform', 'win_amd64', '--python-version', '3.12', '--implementation', 'cp', '--abi', 'cp312', '--no-deps')
            $args = Get-OSyncPipDownloadArgs -DownloadArgs $custom
            ($args -join ' ') | Should -Be ($custom -join ' ')
        }
    }

    Context 'Test-OSyncPythonInterpreter' {
        It 'accepts an executable that prints a Python version and exits 0' {
            $ok = Join-Path $TestDrive 'ok.cmd'
            Set-Content -LiteralPath $ok -Value @('@echo Python 3.12.10', '@exit /b 0') -Encoding ASCII
            Test-OSyncPythonInterpreter -PythonPath $ok | Should -BeTrue
        }

        It 'rejects an executable that exits non-zero' {
            $bad = Join-Path $TestDrive 'bad.cmd'
            Set-Content -LiteralPath $bad -Value @('@echo Python 3.12.10', '@exit /b 1') -Encoding ASCII
            Test-OSyncPythonInterpreter -PythonPath $bad | Should -BeFalse
        }

        It 'rejects a stub that exits 0 without printing a version' {
            $stub = Join-Path $TestDrive 'stub.cmd'
            Set-Content -LiteralPath $stub -Value '@exit /b 0' -Encoding ASCII
            Test-OSyncPythonInterpreter -PythonPath $stub | Should -BeFalse
        }

        It 'rejects a missing file' {
            Test-OSyncPythonInterpreter -PythonPath (Join-Path $TestDrive 'missing.exe') | Should -BeFalse
        }
    }

    Context 'Resolve-OSyncPython' {
        It 'uses the python command from PATH when it is a working interpreter' {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\somewhere\python.exe' } }
            Mock Test-OSyncPythonInterpreter { $true }
            Resolve-OSyncPython -FallbackPath 'C:\does-not-exist\python.exe' | Should -Be 'C:\somewhere\python.exe'
        }

        It 'iterates MULTIPLE PATH candidates and picks the first WORKING one (store stub rejected)' {
            # Regression: real Python 3.12 + the WindowsApps store stub are
            # BOTH on PATH in the elevated production context. Get-Command
            # returns an array; the old code passed the array to the [string]
            # -PythonPath parameter and threw ParameterBindingException.
            Mock Get-Command {
                @(
                    [pscustomobject]@{ Source = 'C:\WindowsApps\python.exe' },
                    [pscustomobject]@{ Source = 'C:\Python312\python.exe' }
                )
            }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Python312\python.exe')
            }
            Resolve-OSyncPython | Should -Be 'C:\Python312\python.exe'
        }

        It 'stops at the FIRST working candidate without probing the rest' {
            Mock Get-Command {
                @(
                    [pscustomobject]@{ Source = 'C:\first\python.exe' },
                    [pscustomobject]@{ Source = 'C:\second\python.exe' }
                )
            }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                $script:ProbedPaths += $PythonPath
                return ($PythonPath -eq 'C:\first\python.exe')
            }
            $script:ProbedPaths = @()
            Resolve-OSyncPython | Should -Be 'C:\first\python.exe'
            $script:ProbedPaths | Should -Be @('C:\first\python.exe')
        }

        It 'falls back when ALL PATH candidates are stubs' {
            Mock Get-Command {
                @(
                    [pscustomobject]@{ Source = 'C:\WindowsApps\python.exe' },
                    [pscustomobject]@{ Source = 'C:\WindowsApps\python3.exe' }
                )
            }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Program Files\Python312\python.exe')
            }
            Resolve-OSyncPython | Should -Be 'C:\Program Files\Python312\python.exe'
        }

        It 'falls back to the pinned C:\Program Files\Python312\python.exe when the PATH candidate is a stub' {
            Mock Get-Command { [pscustomobject]@{ Source = 'C:\WindowsApps\python.exe' } }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Program Files\Python312\python.exe')
            }
            Resolve-OSyncPython | Should -Be 'C:\Program Files\Python312\python.exe'
        }

        It 'falls back when python is not on PATH at all' {
            Mock Get-Command { $null }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Program Files\Python312\python.exe')
            }
            Resolve-OSyncPython | Should -Be 'C:\Program Files\Python312\python.exe'
        }

        It 'throws naming the fallback when neither yields a working interpreter' {
            Mock Get-Command { $null }
            Mock Test-OSyncPythonInterpreter { $false }
            { Resolve-OSyncPython -FallbackPath 'C:\nope\python.exe' } |
                Should -Throw -ExpectedMessage "*C:\nope\python.exe*"
        }
    }

    Context 'Assert-OSyncNoSdist' {
        It 'passes on a directory containing only wheels' {
            $d = Join-Path $TestDrive 'wheels-only'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
            Assert-OSyncNoSdist -PipDir $d | Should -BeTrue
        }

        It 'throws and names the offending file when a .tar.gz sdist is present' {
            $d = Join-Path $TestDrive 'with-sdist'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'evil-1.0.tar.gz') -Force | Out-Null
            { Assert-OSyncNoSdist -PipDir $d -AllowSdist $false } |
                Should -Throw -ExpectedMessage "*evil-1.0.tar.gz*"
        }

        It 'skips the check entirely when AllowSdist is true' {
            $d = Join-Path $TestDrive 'allow-sdist'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'ok-1.0.tar.gz') -Force | Out-Null
            Assert-OSyncNoSdist -PipDir $d -AllowSdist $true | Should -BeTrue
        }
    }

    Context 'Get-OSyncPipFailures' {
        It 'extracts the requirement name from a "Could not find a version" error' {
            $out = "ERROR: Could not find a version that satisfies the requirement nosuchpkg==9.9 (from versions: none)"
            $f = Get-OSyncPipFailures -PipOutput $out
            $f.Count | Should -Be 1
            $f[0].requirement | Should -Be 'nosuchpkg==9.9'
        }

        It 'extracts the requirement name from a "The user requested" error' {
            $out = "ERROR: The user requested binonly==1.0; binonly is not available as a binary."
            $f = Get-OSyncPipFailures -PipOutput $out
            $f.Count | Should -Be 1
            $f[0].requirement | Should -Be 'binonly==1.0'
        }

        It 'falls back to the raw ERROR lines when nothing parseable is found' {
            $out = "Collecting six`r`nERROR: Some network failure occurred"
            $f = Get-OSyncPipFailures -PipOutput $out
            $f.Count | Should -Be 1
            $f[0].requirement | Should -Be '<unknown>'
            $f[0].error | Should -BeLike '*network failure*'
        }
    }

    Context 'Invoke-OSyncPipDownload (real native invocation, no network)' {
        It 'captures native stderr without throwing under ErrorActionPreference=Stop' {
            # A .cmd that writes to stderr and exits 0 stands in for pip's
            # progress/warning chatter. With EAP=Stop, PS 5.1 would otherwise
            # turn that stderr into a terminating NativeCommandError.
            $stubPy = Join-Path $TestDrive 'stubpy.cmd'
            Set-Content -LiteralPath $stubPy -Value @('@echo some-stderr-text 1>&2', '@exit /b 0') -Encoding ASCII
            $dest = Join-Path $TestDrive 'eap-dest'
            $savedEap = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                $r = Invoke-OSyncPipDownload -PythonPath $stubPy -Requirements $script:RequirementsPath -Destination $dest -DownloadArgs $script:DefaultArgs
                $r.ExitCode | Should -Be 0
                $r.Output | Should -BeLike '*some-stderr-text*'
            }
            finally {
                $ErrorActionPreference = $savedEap
            }
        }
    }

    Context 'Export-OSyncPip (mocked pip invocation)' {
        It 'returns a SINGLE report object - no leaked log paths in the pipeline' {
            # Regression: Write-OSyncLog RETURNS the JSONL path string; a bare
            # call leaks it into the success stream and Export-OSyncPip then
            # emits [logpath, logpath, ..., report] instead of the report.
            # Member enumeration masks the bug for .status/.ok, so assert on
            # the collection shape itself.
            $staging = Join-Path $TestDrive 'single-object'
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig) -StagingDir $staging

            $report -is [System.Array] | Should -BeFalse
            $report.GetType().Name | Should -Be 'PSCustomObject'
            @($report).Count | Should -Be 1
            ($report | Where-Object { $_ -is [string] }) | Should -BeNullOrEmpty
            $report.status | Should -Be 'ok'
        }

        It 'downloads via pip, copies requirements.txt and reports the wheels' {
            $staging = Join-Path $TestDrive 'happy'
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                $script:CapturedPython = $PythonPath
                $script:CapturedReq = $Requirements
                $script:CapturedArgs = @($DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                New-Item -ItemType File -Path (Join-Path $Destination 'isodate-0.7.2-py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'Successfully downloaded six-1.17.0-py2.py3-none-any.whl' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig) -StagingDir $staging

            $script:CapturedPython | Should -Be 'python.exe'
            $script:CapturedReq | Should -Be $script:RequirementsPath
            ($script:CapturedArgs -join ' ') | Should -Be ($script:DefaultArgs -join ' ')
            $report.status | Should -Be 'ok'
            $report.wheelCount | Should -Be 2
            ($report.ok -join ',') | Should -Be 'isodate-0.7.2-py3-none-any.whl,six-1.17.0-py2.py3-none-any.whl'
            (Test-Path -LiteralPath (Join-Path $staging 'pip\export-report.json')) | Should -BeTrue
            # requirements.txt copied byte-identical
            (Get-FileHash -LiteralPath (Join-Path $staging 'pip\requirements.txt') -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $script:RequirementsPath -Algorithm SHA256).Hash
        }

        It 'applies the platform-pin default when the config downloadArgs is empty' {
            $staging = Join-Path $TestDrive 'emptyargs'
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                $script:CapturedEmptyArgs = @($DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $null = Export-OSyncPip -Config (New-OTestConfig -DownloadArgs @()) -StagingDir $staging
            ($script:CapturedEmptyArgs -join ' ') | Should -Be ($script:DefaultArgs -join ' ')
        }

        It 'passes the config downloadArgs through to the pip invocation' {
            $staging = Join-Path $TestDrive 'customargs'
            $custom = @('--only-binary=:all:', '--platform', 'win_arm64', '--python-version', '3.11', '--implementation', 'cp', '--abi', 'cp311')
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                $script:CapturedCustomArgs = @($DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $null = Export-OSyncPip -Config (New-OTestConfig -DownloadArgs $custom) -StagingDir $staging
            ($script:CapturedCustomArgs -join ' ') | Should -Be ($custom -join ' ')
        }

        It 'records the failure in the report and rethrows when pip exits non-zero' {
            $staging = Join-Path $TestDrive 'fail'
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                return [pscustomobject]@{
                    ExitCode = 1
                    Output   = "ERROR: Could not find a version that satisfies the requirement nosuchpkg==9.9 (from versions: none)"
                }
            }

            { Export-OSyncPip -Config (New-OTestConfig) -StagingDir $staging } |
                Should -Throw -ExpectedMessage "*pip download failed*exit code 1*"

            $reportPath = Join-Path $staging 'pip\export-report.json'
            (Test-Path -LiteralPath $reportPath) | Should -BeTrue
            $saved = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $saved.status | Should -Be 'failed'
            $saved.failed.Count | Should -Be 1
            $saved.failed[0].requirement | Should -Be 'nosuchpkg==9.9'
        }

        It 'fails the export when an sdist shows up in the staging pip dir' {
            $staging = Join-Path $TestDrive 'sdist'
            $pipDir = Join-Path $staging 'pip'
            New-Item -ItemType Directory -Path $pipDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $pipDir 'evil-0.1.tar.gz') -Force | Out-Null

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            { Export-OSyncPip -Config (New-OTestConfig) -StagingDir $staging } |
                Should -Throw -ExpectedMessage "*evil-0.1.tar.gz*"
        }

        It 'allows sdists when config.pip.allowSdist is true' {
            $staging = Join-Path $TestDrive 'sdist-allowed'
            $pipDir = Join-Path $staging 'pip'
            New-Item -ItemType Directory -Path $pipDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $pipDir 'pkg-1.0.tar.gz') -Force | Out-Null

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig -AllowSdist $true) -StagingDir $staging
            $report.status | Should -Be 'ok'
        }

        It 'throws when the requirements file does not exist (repo-root-relative path)' {
            $cfg = New-OTestConfig -RepoRoot (Join-Path $TestDrive 'noreq')
            Mock Resolve-OSyncPython { 'python.exe' }
            { Export-OSyncPip -Config $cfg -StagingDir (Join-Path $TestDrive 'x') } |
                Should -Throw -ExpectedMessage "*requirements file not found*"
        }

        It 'aborts when no python interpreter can be resolved' {
            Mock Resolve-OSyncPython { throw 'Resolve-OSyncPython: no usable python interpreter found' }
            { Export-OSyncPip -Config (New-OTestConfig) -StagingDir (Join-Path $TestDrive 'y') } |
                Should -Throw -ExpectedMessage "*no usable python interpreter*"
        }
    }
}
