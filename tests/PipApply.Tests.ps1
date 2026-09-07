#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\PipApply.ps1 - the B-side pip offline
    apply (--no-index wheel-repo install).

.DESCRIPTION
    All python invocations are MOCKED (Mock Invoke-OSyncPipInstall /
    Mock Invoke-OSyncPipList / Mock Resolve-OSyncApplyPython) - no real
    python and no network needed. Everything runs under $TestDrive; the real
    config/state are never touched.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\PipApply.Tests.ps1 -PassThru"
      pwsh      -NoProfile -Command "Invoke-Pester tests\PipApply.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files are
    dot-sourced and helper functions are defined INSIDE BeforeAll; data shared
    with the It blocks uses $script: scope (same pattern as the other test
    files in this plan).
#>

Describe 'PipApply' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipApply.ps1')

        # Work copy: <work>\pip\requirements.txt (the todo-7 export product
        # shape - wheels + requirements.txt in the pip category dir).
        $script:WorkDir = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path (Join-Path $script:WorkDir 'pip') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkDir 'pip\requirements.txt') -Value @('six==1.17.0', 'isodate==0.7.2') -Encoding UTF8

        # Minimal valid config shape consumed by Invoke-OSyncPipApply
        # (Get-OSyncConfig validation is todo-11 territory).
        function New-OTestConfig {
            param(
                [bool]$UpgradeOnApply = $true,
                [string]$StateDir = (Join-Path $TestDrive 'state')
            )
            return [pscustomobject]@{
                role     = 'B'
                stateDir = $StateDir
                pip      = [pscustomobject]@{ upgradeOnApply = $UpgradeOnApply }
            }
        }

        # The exact command the plan pins (todo 14):
        #   python -m pip install --no-index --find-links=<WorkDir>\pip
        #       -r <WorkDir>\pip\requirements.txt [--upgrade]
        $script:ExpectedBase = @(
            '-m', 'pip', 'install',
            '--no-index',
            '--find-links', (Join-Path $script:WorkDir 'pip'),
            '-r', (Join-Path $script:WorkDir 'pip\requirements.txt')
        )
    }

    Context 'Get-OSyncPipApplyArgs - command assembly' {
        It 'assembles the pinned offline command without --upgrade by default' {
            $args = Get-OSyncPipApplyArgs -WorkDir $script:WorkDir -UpgradeOnApply $false
            ($args -join ' ') | Should -Be ($script:ExpectedBase -join ' ')
            $args | Should -Contain '--no-index'
            $args | Should -Not -Contain '--upgrade'
        }

        It 'appends --upgrade when UpgradeOnApply is true' {
            $args = Get-OSyncPipApplyArgs -WorkDir $script:WorkDir -UpgradeOnApply $true
            $args | Should -Contain '--upgrade'
            ($args -join ' ') | Should -Be (($script:ExpectedBase + '--upgrade') -join ' ')
        }

        It 'points --find-links and -r at the WorkDir pip directory' {
            $args = Get-OSyncPipApplyArgs -WorkDir $script:WorkDir -UpgradeOnApply $false
            $i = [array]::IndexOf($args, '--find-links')
            $i | Should -BeGreaterThan 0
            $args[$i + 1] | Should -Be (Join-Path $script:WorkDir 'pip')
            $j = [array]::IndexOf($args, '-r')
            $j | Should -BeGreaterThan 0
            $args[$j + 1] | Should -Be (Join-Path $script:WorkDir 'pip\requirements.txt')
        }

        It 'never contains --index-url or any network source parameter' {
            $args = Get-OSyncPipApplyArgs -WorkDir $script:WorkDir -UpgradeOnApply $true
            $joined = $args -join ' '
            $joined | Should -Not -Match '--index-url'
            $joined | Should -Not -Match '--extra-index-url'
            $joined | Should -Not -Match 'https?://'
        }
    }

    Context 'Get-OSyncMachinePath' {
        It 'returns the machine PATH from the HKLM environment' {
            # Smoke test against the real registry: every Windows box has a
            # machine PATH containing System32.
            $p = Get-OSyncMachinePath
            $p | Should -Not -BeNullOrEmpty
            $p | Should -Match 'System32'
        }
    }

    Context 'Resolve-OSyncApplyPython - HKLM machine PATH re-derivation' {
        It 'resolves python.exe from the HKLM machine PATH' {
            Mock Get-OSyncMachinePath { 'C:\tools;C:\Program Files\Python312' }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Program Files\Python312\python.exe')
            }
            Resolve-OSyncApplyPython | Should -Be 'C:\Program Files\Python312\python.exe'
        }

        It 'skips machine PATH directories without a working python.exe' {
            Mock Get-OSyncMachinePath { 'C:\no-python;C:\Program Files\Python312' }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Program Files\Python312\python.exe')
            }
            Resolve-OSyncApplyPython | Should -Be 'C:\Program Files\Python312\python.exe'
        }

        It 'falls back to the pinned C:\Program Files\Python312\python.exe when the machine PATH has no python' {
            Mock Get-OSyncMachinePath { 'C:\tools' }
            Mock Test-OSyncPythonInterpreter {
                param([string]$PythonPath)
                return ($PythonPath -eq 'C:\Program Files\Python312\python.exe')
            }
            Resolve-OSyncApplyPython | Should -Be 'C:\Program Files\Python312\python.exe'
        }

        It 'throws an explicit error mentioning the bootstrap when nothing resolves' {
            Mock Get-OSyncMachinePath { 'C:\tools' }
            Mock Test-OSyncPythonInterpreter { $false }
            { Resolve-OSyncApplyPython } | Should -Throw -ExpectedMessage '*bootstrap*'
        }

        It 'throws when the machine PATH cannot be read' {
            Mock Get-OSyncMachinePath { $null }
            Mock Test-OSyncPythonInterpreter { $false }
            { Resolve-OSyncApplyPython } | Should -Throw -ExpectedMessage '*bootstrap*'
        }
    }

    Context 'Invoke-OSyncPipInstall / Invoke-OSyncPipList (real native invocation)' {
        It 'captures native stderr without throwing under ErrorActionPreference=Stop' {
            # A .cmd that writes to stderr and exits 0 stands in for pip's
            # progress/warning chatter. With EAP=Stop, PS 5.1 would otherwise
            # turn that stderr into a terminating NativeCommandError.
            $stubPy = Join-Path $TestDrive 'stubpy.cmd'
            Set-Content -LiteralPath $stubPy -Value @('@echo some-stderr-text 1>&2', '@exit /b 0') -Encoding ASCII
            $savedEap = $ErrorActionPreference
            $ErrorActionPreference = 'Stop'
            try {
                $r = Invoke-OSyncPipInstall -PythonPath $stubPy -Arguments @('-m', 'pip', 'install', '--no-index')
                $r.ExitCode | Should -Be 0
                $r.Output | Should -BeLike '*some-stderr-text*'
            }
            finally {
                $ErrorActionPreference = $savedEap
            }
        }

        It 'reports a non-zero exit code from the native call' {
            $stubPy = Join-Path $TestDrive 'failpy.cmd'
            Set-Content -LiteralPath $stubPy -Value '@exit /b 7' -Encoding ASCII
            $r = Invoke-OSyncPipList -PythonPath $stubPy
            $r.ExitCode | Should -Be 7
        }
    }

    Context 'Invoke-OSyncPipApply (mocked python invocation)' {
        It 'installs with the assembled args and writes the pip list snapshot to state.pip' {
            Mock Resolve-OSyncApplyPython { 'C:\Program Files\Python312\python.exe' }
            Mock Invoke-OSyncPipInstall {
                param([string]$PythonPath, [string[]]$Arguments)
                $script:CapturedInstallArgs = @($Arguments)
                return [pscustomobject]@{ ExitCode = 0; Output = 'Successfully installed six-1.17.0 isodate-0.7.2' }
            }
            Mock Invoke-OSyncPipList {
                return [pscustomobject]@{
                    ExitCode = 0
                    Output   = '[{"name":"pip","version":"25.0.1"},{"name":"six","version":"1.17.0"},{"name":"isodate","version":"0.7.2"}]'
                }
            }

            $cfg = New-OTestConfig
            $result = Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config $cfg

            $result.status | Should -Be 'ok'
            $result.packages | Should -Be 3
            ($script:CapturedInstallArgs -join ' ') | Should -Be (($script:ExpectedBase + '--upgrade') -join ' ')

            $state = Get-OSyncState -Category pip -StateDir $cfg.stateDir
            $state.pip['six'].version | Should -Be '1.17.0'
            $state.pip['isodate'].version | Should -Be '0.7.2'
            $state.pip['pip'].version | Should -Be '25.0.1'
        }

        It 'omits --upgrade when config.pip.upgradeOnApply is false' {
            Mock Resolve-OSyncApplyPython { 'python.exe' }
            Mock Invoke-OSyncPipInstall {
                param([string]$PythonPath, [string[]]$Arguments)
                $script:CapturedNoUpgradeArgs = @($Arguments)
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
            Mock Invoke-OSyncPipList { return [pscustomobject]@{ ExitCode = 0; Output = '[]' } }

            $null = Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config (New-OTestConfig -UpgradeOnApply $false)
            ($script:CapturedNoUpgradeArgs -join ' ') | Should -Be ($script:ExpectedBase -join ' ')
        }

        It 'does NOT update state and throws when pip install fails' {
            Mock Resolve-OSyncApplyPython { 'python.exe' }
            Mock Invoke-OSyncPipInstall {
                return [pscustomobject]@{
                    ExitCode = 1
                    Output   = 'ERROR: Could not find a version that satisfies the requirement six==1.17.0 (from versions: none)'
                }
            }
            # Behavior-based guard (learnings: Should -Invoke -Times can see
            # stale history across re-mocks): the snapshot must never run.
            Mock Invoke-OSyncPipList { throw 'Invoke-OSyncPipList must not be called on install failure' }

            # Dedicated state dir: the happy-path test already wrote records
            # into the shared default $TestDrive\state.
            $cfg = New-OTestConfig -StateDir (Join-Path $TestDrive 'state-fail-install')
            { Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config $cfg } |
                Should -Throw -ExpectedMessage '*pip install failed*exit code 1*state NOT updated*'

            $state = Get-OSyncState -Category pip -StateDir $cfg.stateDir
            $state.pip.Keys.Count | Should -Be 0
        }

        It 'does NOT update state and throws when the pip list snapshot fails' {
            Mock Resolve-OSyncApplyPython { 'python.exe' }
            Mock Invoke-OSyncPipInstall { return [pscustomobject]@{ ExitCode = 0; Output = 'ok' } }
            Mock Invoke-OSyncPipList { return [pscustomobject]@{ ExitCode = 2; Output = 'ERROR: broken' } }

            $cfg = New-OTestConfig -StateDir (Join-Path $TestDrive 'state-fail-list')
            { Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config $cfg } |
                Should -Throw -ExpectedMessage '*pip list*state NOT updated*'

            $state = Get-OSyncState -Category pip -StateDir $cfg.stateDir
            $state.pip.Keys.Count | Should -Be 0
        }

        It 'throws mentioning the bootstrap when no python can be resolved' {
            Mock Resolve-OSyncApplyPython { throw 'Resolve-OSyncApplyPython: no usable python interpreter found ... bootstrap ... incomplete' }
            { Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config (New-OTestConfig) } |
                Should -Throw -ExpectedMessage '*bootstrap*'
        }

        It 'throws when requirements.txt is missing from the work copy' {
            $badWork = Join-Path $TestDrive 'no-requirements'
            { Invoke-OSyncPipApply -WorkDir $badWork -Config (New-OTestConfig) } |
                Should -Throw -ExpectedMessage '*requirements.txt*'
        }

        It 'uses the -PythonPath override (QA seam) without consulting the machine PATH' {
            Mock Resolve-OSyncApplyPython { throw 'Resolve-OSyncApplyPython must not be called when -PythonPath is given' }
            Mock Test-OSyncPythonInterpreter { $true }
            Mock Invoke-OSyncPipInstall {
                param([string]$PythonPath, [string[]]$Arguments)
                $script:CapturedOverridePython = $PythonPath
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
            Mock Invoke-OSyncPipList { return [pscustomobject]@{ ExitCode = 0; Output = '[]' } }

            $null = Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config (New-OTestConfig) -PythonPath 'C:\venv\Scripts\python.exe'
            $script:CapturedOverridePython | Should -Be 'C:\venv\Scripts\python.exe'
        }

        It 'rejects an unusable -PythonPath override' {
            Mock Test-OSyncPythonInterpreter { $false }
            { Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config (New-OTestConfig) -PythonPath 'C:\nope\python.exe' } |
                Should -Throw -ExpectedMessage '*override*'
        }

        It 'returns a SINGLE summary object - no leaked log paths in the pipeline' {
            # Regression: Write-OSyncLog RETURNS the JSONL path string; a bare
            # call leaks it into the success stream and the caller would get
            # [logpath, logpath, ..., summary] instead of the summary.
            Mock Resolve-OSyncApplyPython { 'python.exe' }
            Mock Invoke-OSyncPipInstall { return [pscustomobject]@{ ExitCode = 0; Output = 'ok' } }
            Mock Invoke-OSyncPipList { return [pscustomobject]@{ ExitCode = 0; Output = '[{"name":"six","version":"1.17.0"}]' } }

            $result = Invoke-OSyncPipApply -WorkDir $script:WorkDir -Config (New-OTestConfig)
            $result -is [System.Array] | Should -BeFalse
            $result.GetType().Name | Should -Be 'PSCustomObject'
            @($result).Count | Should -Be 1
            ($result | Where-Object { $_ -is [string] }) | Should -BeNullOrEmpty
        }
    }
}