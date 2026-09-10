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
        # Resolve-OSyncConfigPath lives in Config.ps1 (since 575644a anchored
        # config.paths to the tool root) and PipExport.ps1 calls it.
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
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

        # Test tool root with manifests\requirements.txt (paths.* are
        # tool-root-relative by the config contract - the fixture root doubles
        # as the tool root here; the different-drive case is covered by
        # Config.Tests.ps1).
        $script:RepoRoot = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $script:RepoRoot 'manifests') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:RepoRoot 'manifests\requirements.txt') -Value @('six==1.17.0', 'isodate==0.7.2') -Encoding UTF8
        $script:RequirementsPath = Join-Path $script:RepoRoot 'manifests\requirements.txt'

        # Minimal valid config shape consumed by Export-OSyncPip
        # (Get-OSyncConfig validation is todo-11 territory). toolRoot is the
        # derived property Get-OSyncConfig stamps; Resolve-OSyncConfigPath
        # resolves paths.* against it (never config.repoRoot).
        function New-OTestConfig {
            param(
                [string]$RepoRoot = $script:RepoRoot,
                [bool]$AllowSdist = $false,
                [string[]]$DownloadArgs = $script:DefaultArgs,
                # paths.pipLocalDirs (T4): the KEY is ABSENT unless
                # -WithPipLocalDirs is given (absent = feature OFF, the
                # delivery stays byte-identical). With the switch, an empty
                # array means "present but OFF" and a populated array enables
                # the local-wheel flow.
                [switch]$WithPipLocalDirs,
                [string[]]$PipLocalDirs = @()
            )
            $paths = [pscustomobject]@{ requirements = 'manifests\requirements.txt' }
            if ($WithPipLocalDirs) {
                $paths | Add-Member -NotePropertyName pipLocalDirs -NotePropertyValue $PipLocalDirs -Force
            }
            return [pscustomobject]@{
                role      = 'A'
                repoRoot  = $RepoRoot
                toolRoot  = $RepoRoot
                stateDir  = Join-Path $RepoRoot 'state'
                paths     = $paths
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

    Context 'ConvertFrom-OSyncWheelFileName - PEP 427 parsing' {
        It 'parses a plain 5-part wheel name' {
            $w = ConvertFrom-OSyncWheelFileName -FileName 'six-1.17.0-py2.py3-none-any.whl'
            $w.Name | Should -Be 'six'
            $w.Version | Should -Be '1.17.0'
            $w.Pin | Should -Be 'six==1.17.0'
        }

        It 'accepts a 6-part name whose build tag starts with a digit' {
            # dist-version-BUILD-python-abi-platform: part[2] = '1' is the
            # PEP 427 build tag.
            $w = ConvertFrom-OSyncWheelFileName -FileName 'my_pkg-2.0-1-cp312-cp312-win_amd64.whl'
            $w.Name | Should -Be 'my_pkg'
            $w.Version | Should -Be '2.0'
            $w.Pin | Should -Be 'my_pkg==2.0'
        }

        It 'keeps a PEP 440 local version segment (+abc) verbatim' {
            $w = ConvertFrom-OSyncWheelFileName -FileName 'foo-1.0.1+abc-py3-none-any.whl'
            $w.Version | Should -Be '1.0.1+abc'
            $w.Pin | Should -Be 'foo==1.0.1+abc'
        }

        It 'returns $null for too-few parts' {
            ConvertFrom-OSyncWheelFileName -FileName 'foo-1.0.whl' | Should -BeNullOrEmpty
            ConvertFrom-OSyncWheelFileName -FileName 'foo.whl' | Should -BeNullOrEmpty
        }

        It 'returns $null for a 6-part name whose build tag is not numeric' {
            ConvertFrom-OSyncWheelFileName -FileName 'foo-1.0-x-py3-none-any.whl' | Should -BeNullOrEmpty
        }
    }

    Context 'Get-OSyncPipLocalWheelPlan' {
        It 'scans TOP-LEVEL wheels only (a wheel in a subdirectory is ignored)' {
            $d = Join-Path $TestDrive 'plan-top'
            New-Item -ItemType Directory -Path (Join-Path $d 'nested') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'nested\isodate-0.7.2-py3-none-any.whl') -Force | Out-Null

            $plan = Get-OSyncPipLocalWheelPlan -Dirs @($d)

            $plan.Wheels.Count | Should -Be 1
            $plan.Wheels[0].File | Should -Be 'six-1.17.0-py2.py3-none-any.whl'
            $plan.Wheels[0].Name | Should -Be 'six'
            $plan.Wheels[0].Version | Should -Be '1.17.0'
            $plan.Wheels[0].Pin | Should -Be 'six==1.17.0'
            $plan.Wheels[0].Path | Should -Be (Join-Path $d 'six-1.17.0-py2.py3-none-any.whl')
        }

        It 'buckets sdists and unparseable wheels and reports missing dirs' {
            $d = Join-Path $TestDrive 'plan-buckets'
            New-Item -ItemType Directory -Path $d -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'private-1.0.tar.gz') -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $d 'broken.whl') -Force | Out-Null
            $missing = Join-Path $TestDrive 'plan-missing'

            $plan = Get-OSyncPipLocalWheelPlan -Dirs @($d, $missing)

            $plan.Wheels.Count | Should -Be 1
            $plan.Sdists.Count | Should -Be 1
            $plan.Sdists[0].File | Should -Be 'private-1.0.tar.gz'
            $plan.Sdists[0].Dir | Should -Be $d
            $plan.Unparseable.Count | Should -Be 1
            $plan.Unparseable[0].File | Should -Be 'broken.whl'
            $plan.Unparseable[0].Dir | Should -Be $d
            $plan.MissingDirs.Count | Should -Be 1
            $plan.MissingDirs[0].Dir | Should -Be $missing
        }

        It 'returns empty buckets for an empty dir list' {
            $plan = Get-OSyncPipLocalWheelPlan -Dirs @()
            $plan.Wheels.Count | Should -Be 0
            $plan.Sdists.Count | Should -Be 0
            $plan.Unparseable.Count | Should -Be 0
            $plan.MissingDirs.Count | Should -Be 0
        }
    }

    Context 'Add-OSyncRequirementsPins' {
        It 'appends a pin with the local marker, preserving a UTF-8 BOM and CRLF' {
            $p = Join-Path $TestDrive 'req-bom-crlf.txt'
            [System.IO.File]::WriteAllText($p, "six==1.17.0`r`n", (New-Object System.Text.UTF8Encoding($true)))

            $appended = Add-OSyncRequirementsPins -RequirementsPath $p `
                -PinLines @('my_pkg==2.0  # local: my_pkg-2.0-1-cp312-cp312-win_amd64.whl')

            $appended.Count | Should -Be 1
            $appended[0] | Should -Be 'my_pkg==2.0  # local: my_pkg-2.0-1-cp312-cp312-win_amd64.whl'
            $bytes = [System.IO.File]::ReadAllBytes($p)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
            $text | Should -Be "six==1.17.0`r`nmy_pkg==2.0  # local: my_pkg-2.0-1-cp312-cp312-win_amd64.whl`r`n"
        }

        It 'appends without a BOM and keeps LF line endings on an LF file' {
            $p = Join-Path $TestDrive 'req-nobom-lf.txt'
            [System.IO.File]::WriteAllText($p, "six==1.17.0`n", (New-Object System.Text.UTF8Encoding($false)))

            $null = Add-OSyncRequirementsPins -RequirementsPath $p `
                -PinLines @('foo==1.0  # local: foo-1.0-py3-none-any.whl')

            $bytes = [System.IO.File]::ReadAllBytes($p)
            ($bytes[0] -eq 0xEF) | Should -BeFalse
            [System.Text.Encoding]::UTF8.GetString($bytes) |
                Should -Be "six==1.17.0`nfoo==1.0  # local: foo-1.0-py3-none-any.whl`n"
        }

        It 'inserts the EOL separator when the file lacks a trailing newline' {
            $p = Join-Path $TestDrive 'req-noeol.txt'
            [System.IO.File]::WriteAllText($p, 'six==1.17.0', (New-Object System.Text.UTF8Encoding($false)))

            $null = Add-OSyncRequirementsPins -RequirementsPath $p `
                -PinLines @('foo==1.0  # local: foo-1.0-py3-none-any.whl')

            [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p)) |
                Should -Be "six==1.17.0`r`nfoo==1.0  # local: foo-1.0-py3-none-any.whl`r`n"
        }

        It 'skips a pin already present under a different PEP 503 spelling and leaves the file untouched' {
            $p = Join-Path $TestDrive 'req-dedup.txt'
            [System.IO.File]::WriteAllText($p, "my.pkg==1.0`n", (New-Object System.Text.UTF8Encoding($false)))
            $before = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash

            $appended = Add-OSyncRequirementsPins -RequirementsPath $p `
                -PinLines @('my_pkg==2.0  # local: my_pkg-2.0-py3-none-any.whl')

            $appended.Count | Should -Be 0
            (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash | Should -Be $before
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

        It 'throws when the requirements file does not exist (tool-root-relative path)' {
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

    Context 'Export-OSyncPip - local wheel dirs (paths.pipLocalDirs)' {
        It 'copies local wheels into staging and appends their pins to the STAGING requirements copy only' {
            $staging = Join-Path $TestDrive 'local-happy'
            $localDir = Join-Path $TestDrive 'local-wheels-happy'
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $localDir 'my_pkg-2.0-1-cp312-cp312-win_amd64.whl') -Force | Out-Null
            $sourceHash = (Get-FileHash -LiteralPath $script:RequirementsPath -Algorithm SHA256).Hash

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig -WithPipLocalDirs -PipLocalDirs @($localDir)) -StagingDir $staging

            # wheel copied into <staging>\pip
            (Test-Path -LiteralPath (Join-Path $staging 'pip\my_pkg-2.0-1-cp312-cp312-win_amd64.whl')) | Should -BeTrue
            # staging requirements.txt = original content + appended pinned line
            $lines = @([System.IO.File]::ReadAllText((Join-Path $staging 'pip\requirements.txt')) -split "`r?`n")
            $lines | Should -Contain 'six==1.17.0'
            $lines | Should -Contain 'my_pkg==2.0  # local: my_pkg-2.0-1-cp312-cp312-win_amd64.whl'
            # the ORIGINAL manifest is never modified
            (Get-FileHash -LiteralPath $script:RequirementsPath -Algorithm SHA256).Hash | Should -Be $sourceHash

            $report.status | Should -Be 'ok'
            # wheelCount/ok keep their PyPI-only semantics (the local wheel is
            # copied after the PyPI enumeration).
            $report.wheelCount | Should -Be 1
            ($report.ok -join ',') | Should -Be 'six-1.17.0-py2.py3-none-any.whl'
            $report.local.Count | Should -Be 1
            $report.local[0].file | Should -Be 'my_pkg-2.0-1-cp312-cp312-win_amd64.whl'
            $report.local[0].name | Should -Be 'my_pkg'
            $report.local[0].version | Should -Be '2.0'
            $report.local[0].pin | Should -Be 'my_pkg==2.0'
            $report.local[0].action | Should -Be 'copied'
        }

        It 'keeps the delivered requirements.txt byte-identical when paths.pipLocalDirs is absent' {
            $staging = Join-Path $TestDrive 'local-key-absent'
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig) -StagingDir $staging

            (Get-FileHash -LiteralPath (Join-Path $staging 'pip\requirements.txt') -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $script:RequirementsPath -Algorithm SHA256).Hash
            $report.local.Count | Should -Be 0
        }

        It 'never copies a local sdist: warning + skipped-sdist entry, no-sdist assertion still passes' {
            $staging = Join-Path $TestDrive 'local-sdist'
            $localDir = Join-Path $TestDrive 'local-wheels-sdist'
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $localDir 'private-1.0.tar.gz') -Force | Out-Null

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
            Mock Write-OSyncLog { }

            $report = Export-OSyncPip -Config (New-OTestConfig -WithPipLocalDirs -PipLocalDirs @($localDir)) -StagingDir $staging

            $report.status | Should -Be 'ok'
            (Test-Path -LiteralPath (Join-Path $staging 'pip\private-1.0.tar.gz')) | Should -BeFalse
            $report.local.Count | Should -Be 1
            $report.local[0].file | Should -Be 'private-1.0.tar.gz'
            $report.local[0].action | Should -Be 'skipped-sdist'
            Should -Invoke Write-OSyncLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*private-1.0.tar.gz*'
            }
        }

        It 'skips an unparseable wheel name: warning + skipped-unparseable entry, no copy' {
            $staging = Join-Path $TestDrive 'local-unparseable'
            $localDir = Join-Path $TestDrive 'local-wheels-unparseable'
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            New-Item -ItemType File -Path (Join-Path $localDir 'broken.whl') -Force | Out-Null

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
            Mock Write-OSyncLog { }

            $report = Export-OSyncPip -Config (New-OTestConfig -WithPipLocalDirs -PipLocalDirs @($localDir)) -StagingDir $staging

            (Test-Path -LiteralPath (Join-Path $staging 'pip\broken.whl')) | Should -BeFalse
            $report.local.Count | Should -Be 1
            $report.local[0].file | Should -Be 'broken.whl'
            $report.local[0].action | Should -Be 'skipped-unparseable'
            Should -Invoke Write-OSyncLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*broken.whl*'
            }
        }

        It 'copies a wheel whose pin already exists but does NOT append a duplicate pin (PEP 503 dedup)' {
            $staging = Join-Path $TestDrive 'local-pin-exists'
            $localDir = Join-Path $TestDrive 'local-wheels-pin-exists'
            New-Item -ItemType Directory -Path $localDir -Force | Out-Null
            # six is already pinned in the shared manifest as six==1.17.0.
            New-Item -ItemType File -Path (Join-Path $localDir 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'isodate-0.7.2-py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig -WithPipLocalDirs -PipLocalDirs @($localDir)) -StagingDir $staging

            (Test-Path -LiteralPath (Join-Path $staging 'pip\six-1.17.0-py2.py3-none-any.whl')) | Should -BeTrue
            $report.local.Count | Should -Be 1
            $report.local[0].action | Should -Be 'copied-pin-exists'
            # nothing appended -> the staging copy is still byte-identical
            (Get-FileHash -LiteralPath (Join-Path $staging 'pip\requirements.txt') -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $script:RequirementsPath -Algorithm SHA256).Hash
        }

        It 'treats an empty pipLocalDirs array as OFF and still emits exactly ONE report object' {
            $staging = Join-Path $TestDrive 'local-empty'
            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }

            $report = Export-OSyncPip -Config (New-OTestConfig -WithPipLocalDirs -PipLocalDirs @()) -StagingDir $staging

            $report -is [System.Array] | Should -BeFalse
            @($report).Count | Should -Be 1
            $report.local.Count | Should -Be 0
            (Get-FileHash -LiteralPath (Join-Path $staging 'pip\requirements.txt') -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $script:RequirementsPath -Algorithm SHA256).Hash
        }

        It 'warns and reports missing-dir for a non-existent local dir' {
            $staging = Join-Path $TestDrive 'local-missing-dir'
            $missing = Join-Path $TestDrive 'local-dir-does-not-exist'

            Mock Resolve-OSyncPython { 'python.exe' }
            Mock Invoke-OSyncPipDownload {
                param([string]$PythonPath, [string]$Requirements, [string]$Destination, [string[]]$DownloadArgs)
                New-Item -ItemType File -Path (Join-Path $Destination 'six-1.17.0-py2.py3-none-any.whl') -Force | Out-Null
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
            Mock Write-OSyncLog { }

            $report = Export-OSyncPip -Config (New-OTestConfig -WithPipLocalDirs -PipLocalDirs @($missing)) -StagingDir $staging

            $report.status | Should -Be 'ok'
            $report.local.Count | Should -Be 1
            $report.local[0].file | Should -Be $missing
            $report.local[0].action | Should -Be 'missing-dir'
            Should -Invoke Write-OSyncLog -Times 1 -Exactly -ParameterFilter {
                $Level -eq 'Warning' -and $Message -like '*local-dir-does-not-exist*'
            }
        }
    }
}
