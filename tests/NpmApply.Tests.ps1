#Requires -Version 5.1
<#
  NpmApply.Tests.ps1 - Pester 5 tests for src\lib\NpmApply.ps1.

  Pure unit tests: the scheduled-task functions, the port checks, the npm CLI
  and the machine env var are MOCKED; the npmrc rewrite, the yml assertion,
  the robocopy refresh and the state update run for real against $TestDrive.
  No network access, no real npm, no real scheduled tasks.

  Run:
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\NpmApply.Tests.ps1 -PassThru"
    pwsh      -NoProfile -Command "Invoke-Pester tests\NpmApply.Tests.ps1 -PassThru"
#>

BeforeAll {
    # Dot-source the lib files in dependency order (same pattern as the other
    # test files in this plan).
    . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
    . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
    . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
    . (Join-Path $PSScriptRoot '..\src\lib\NpmExport.ps1')
    . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
    . (Join-Path $PSScriptRoot '..\src\lib\NpmApply.ps1')

    $script:naRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-na-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:naRoot -Force | Out-Null

    # --- helpers (Pester 5 runs It blocks in child scopes of BeforeAll,
    # --- so functions must be defined here, not at file top level) ---

    function New-NaConfig {
        param([string]$StateDir, [int]$Port = 4873)
        return [pscustomobject]@{
            role          = 'B'
            repoRoot      = 'C:\OfflineRepo'
            stateDir      = $StateDir
            verdaccioPort = $Port
        }
    }

    function New-NaWorkDir {
        # Builds a work copy npm dir: verdaccio-b.yml (valid or leaked) +
        # packages.txt + storage dir.
        param([string]$Root, [int]$Port = 4873, [switch]$BadYaml)
        $npmDir = Join-Path $Root 'npm'
        New-Item -ItemType Directory -Path (Join-Path $npmDir 'storage') -Force | Out-Null
        $yaml = if ($BadYaml) {
            (New-OSyncVerdaccioBYaml -Port $Port) + "`nuplinks:`n  npmjs:`n    url: https://registry.npmjs.org`n"
        }
        else {
            New-OSyncVerdaccioBYaml -Port $Port
        }
        [System.IO.File]::WriteAllText((Join-Path $npmDir 'verdaccio-b.yml'), $yaml, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $npmDir 'packages.txt'), "is-odd@3.0.1`n", (New-Object System.Text.UTF8Encoding($false)))
        return $npmDir
    }

    function New-NaNodeInstall {
        # Builds a fake node install dir with a built-in npmrc.
        param([string]$Root)
        $dir = Join-Path $Root 'node'
        New-Item -ItemType Directory -Path (Join-Path $dir 'node_modules\npm') -Force | Out-Null
        $npmrc = Join-Path $dir 'node_modules\npm\npmrc'
        [System.IO.File]::WriteAllText($npmrc, "prefix=`${APPDATA}\npm`n", (New-Object System.Text.UTF8Encoding($false)))
        return $dir
    }

    # Default mocks for the apply happy path (overridden per test).
    function Set-NaDefaultMocks {
        Mock Get-OSyncVerdaccioTaskState { 'Ready' }
        Mock Start-OSyncVerdaccioTask { }
        Mock Stop-OSyncVerdaccioTask { throw 'Stop-OSyncVerdaccioTask must not be called' }
        Mock Test-OSyncPortListening { $false }
        Mock Wait-OSyncPortListening { $true }
        Mock Resolve-OSyncNodeInstallDir { $script:naNodeInstall }
        Mock Set-OSyncMachineEnvVar { }
        Mock Invoke-ONpmCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'view' -and $Arguments[1] -like 'osync-nonexistent*') {
                return [pscustomobject]@{ ExitCode = 1; Output = @('npm error code E404'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'view') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('{ "name": "is-odd", "version": "3.0.1" }'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'config') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('http://127.0.0.1:4873/'); TimedOut = $false }
            }
            throw "unexpected Invoke-ONpmCli args: $($Arguments -join ' ')"
        }
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:naRoot) {
        Remove-Item -LiteralPath $script:naRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Resolve-OSyncNodeInstallDir' {
    It 'finds node.exe from the machine PATH' {
        $nodeDir = Join-Path $TestDrive 'nodejs'
        New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $nodeDir 'node.exe'), 'x')
        Resolve-OSyncNodeInstallDir -MachinePath "C:\Windows\System32;$nodeDir" | Should -Be $nodeDir
    }

    It 'skips entries without node.exe and finds it in a later entry' {
        $nodeDir = Join-Path $TestDrive 'nodejs'
        New-Item -ItemType Directory -Path $nodeDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $nodeDir 'node.exe'), 'x')
        Resolve-OSyncNodeInstallDir -MachinePath "C:\does-not-exist;$nodeDir" | Should -Be $nodeDir
    }

    It 'throws when node.exe is nowhere in the machine PATH' {
        $err = $null
        try { Resolve-OSyncNodeInstallDir -MachinePath 'C:\Windows\System32;C:\Windows' | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*node.exe*'
    }

    It 'throws on an empty machine PATH' {
        $err = $null
        try { Resolve-OSyncNodeInstallDir -MachinePath '' | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*machine PATH*'
    }
}

Describe 'Set-OSyncNpmRegistryConfig' {
    BeforeEach {
        $script:naCfg = New-NaConfig -StateDir (Join-Path $TestDrive 'state')
        $script:naNode = New-NaNodeInstall -Root (Join-Path $TestDrive 'node-root')
    }

    It 'appends the registry line and preserves other lines' {
        $npmrc = Join-Path $script:naNode 'node_modules\npm\npmrc'
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Should -Be $true
        $text = [System.IO.File]::ReadAllText($npmrc)
        $text | Should -Match '(?m)^prefix=\$\{APPDATA\}\\npm\s*$'
        $text | Should -Match '(?m)^registry=http://127\.0\.0\.1:4873/\s*$'
    }

    It 'creates the npmrc when it does not exist' {
        $node = Join-Path $TestDrive 'empty-node'
        New-Item -ItemType Directory -Path (Join-Path $node 'node_modules\npm') -Force | Out-Null
        Set-OSyncNpmRegistryConfig -NodeInstallDir $node -Port 4873 -Config $script:naCfg | Should -Be $true
        $text = [System.IO.File]::ReadAllText((Join-Path $node 'node_modules\npm\npmrc'))
        $text | Should -Match '(?m)^registry=http://127\.0\.0\.1:4873/\s*$'
    }

    It 'is idempotent - a second call does not duplicate the line' {
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Should -Be $true
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Should -Be $false
        $text = [System.IO.File]::ReadAllText((Join-Path $script:naNode 'node_modules\npm\npmrc'))
        ([regex]::Matches($text, '(?m)^registry=http://127\.0\.0\.1:4873/')).Count | Should -Be 1
    }

    It 'backs up to .osyncbak on first modification and never overwrites it' {
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Out-Null
        $bak = Join-Path $script:naNode 'node_modules\npm\npmrc.osyncbak'
        Test-Path -LiteralPath $bak -PathType Leaf | Should -Be $true
        $bakText = [System.IO.File]::ReadAllText($bak)
        $bakText | Should -Not -Match 'registry='
        # A later modification (different port) must not overwrite the backup.
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4899 -Config $script:naCfg | Out-Null
        $bakText2 = [System.IO.File]::ReadAllText($bak)
        $bakText2 | Should -Be $bakText
    }

    It 'does not create a backup when the line is already present' {
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Out-Null
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Out-Null
        $bak = Join-Path $script:naNode 'node_modules\npm\npmrc.osyncbak'
        $bakText = [System.IO.File]::ReadAllText($bak)
        $bakText | Should -Not -Match 'registry='
    }

    It 'handles a file without a trailing newline' {
        $npmrc = Join-Path $script:naNode 'node_modules\npm\npmrc'
        [System.IO.File]::WriteAllText($npmrc, 'prefix=${APPDATA}\npm', (New-Object System.Text.UTF8Encoding($false)))
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Out-Null
        $text = [System.IO.File]::ReadAllText($npmrc)
        $text | Should -Match '(?m)^prefix=\$\{APPDATA\}\\npm\s*$'
        $text | Should -Match '(?m)^registry=http://127\.0\.0\.1:4873/\s*$'
    }

    It 'preserves a UTF-8 BOM' {
        $npmrc = Join-Path $script:naNode 'node_modules\npm\npmrc'
        $bytes = [System.IO.File]::ReadAllBytes($npmrc)
        $withBom = New-Object byte[] ($bytes.Length + 3)
        [Array]::Copy($bytes, 0, $withBom, 3, $bytes.Length)
        $withBom[0] = 0xEF; $withBom[1] = 0xBB; $withBom[2] = 0xBF
        [System.IO.File]::WriteAllBytes($npmrc, $withBom)
        Set-OSyncNpmRegistryConfig -NodeInstallDir $script:naNode -Port 4873 -Config $script:naCfg | Out-Null
        $after = [System.IO.File]::ReadAllBytes($npmrc)
        $after[0] | Should -Be 0xEF
        $after[1] | Should -Be 0xBB
        $after[2] | Should -Be 0xBF
    }
}

Describe 'Invoke-ONpmCli' {
    BeforeAll {
        $script:fakeBin = Join-Path $script:naRoot 'fake-bin'
        New-Item -ItemType Directory -Path $script:fakeBin -Force | Out-Null
        $fakeNpm = @'
@echo off
echo %*
exit /b %FAKE_NPM_EXIT%
'@
        [System.IO.File]::WriteAllText((Join-Path $script:fakeBin 'npm.cmd'), $fakeNpm, [System.Text.Encoding]::ASCII)
        $sleepNpm = @'
@echo off
ping -n 60 127.0.0.1 >nul
exit /b 0
'@
        [System.IO.File]::WriteAllText((Join-Path $script:fakeBin 'sleep.cmd'), $sleepNpm, [System.Text.Encoding]::ASCII)
    }

    It 'runs a command via cmd.exe and returns exit code + output' {
        $env:FAKE_NPM_EXIT = '0'
        $r = Invoke-ONpmCli -NpmExe (Join-Path $script:fakeBin 'npm.cmd') -Arguments @('view', 'is-odd@3.0.1', '--registry', 'http://127.0.0.1:4873') -TimeoutSeconds 30
        $r.TimedOut | Should -Be $false
        $r.ExitCode | Should -Be 0
        ($r.Output -join ' ') | Should -Match 'view is-odd@3.0.1'
    }

    It 'reports the native exit code' {
        $env:FAKE_NPM_EXIT = '1'
        $r = Invoke-ONpmCli -NpmExe (Join-Path $script:fakeBin 'npm.cmd') -Arguments @('view', 'ghost') -TimeoutSeconds 30
        $r.ExitCode | Should -Be 1
    }

    It 'times out and kills the process tree' {
        $r = Invoke-ONpmCli -NpmExe (Join-Path $script:fakeBin 'sleep.cmd') -Arguments @('x') -TimeoutSeconds 2
        $r.TimedOut | Should -Be $true
    }
}

Describe 'Resolve-OSyncNpmExe' {
    It 'prefers npm.cmd over npm.ps1 (cmd.exe cannot execute a .ps1)' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'npm.cmd') { return [pscustomobject]@{ Source = 'C:\Program Files\nodejs\npm.cmd' } }
            return $null
        }
        Resolve-OSyncNpmExe | Should -Be 'C:\Program Files\nodejs\npm.cmd'
    }

    It 'falls back to npm.exe when npm.cmd is absent' {
        Mock Get-Command {
            param($Name)
            if ($Name -eq 'npm.exe') { return [pscustomobject]@{ Source = 'C:\custom\npm.exe' } }
            return $null
        }
        Resolve-OSyncNpmExe | Should -Be 'C:\custom\npm.exe'
    }

    It 'throws when npm is not available' {
        Mock Get-Command { $null }
        $err = $null
        try { Resolve-OSyncNpmExe | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*npm*'
    }
}

Describe 'Invoke-OSyncNpmApply' {
    BeforeEach {
        # $TestDrive is shared across It blocks in Pester 5 - every test needs
        # its own stateDir/work/node dirs so no test sees another's leftovers.
        $script:naStateDir = Join-Path $TestDrive ('state-' + [guid]::NewGuid().ToString('N'))
        $script:naCfg = New-NaConfig -StateDir $script:naStateDir
        $script:naWork = Join-Path $TestDrive ('work-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:naWork -Force | Out-Null
        $script:naNpmDir = New-NaWorkDir -Root $script:naWork
        $script:naNodeInstall = New-NaNodeInstall -Root (Join-Path $TestDrive ('node-root-' + [guid]::NewGuid().ToString('N')))
        Set-NaDefaultMocks
    }

    It 'happy path: refreshes the local copy, starts the task, rewrites npmrc, updates state' {
        $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg
        $result.registryOk | Should -Be $true
        $result.registryUrl | Should -Be 'http://127.0.0.1:4873'

        # local copy refreshed via real robocopy
        Test-Path -LiteralPath (Join-Path $script:naStateDir 'verdaccio\verdaccio-b.yml') -PathType Leaf | Should -Be $true
        Test-Path -LiteralPath (Join-Path $script:naStateDir 'verdaccio\storage') -PathType Container | Should -Be $true

        # task started, never stopped (task was Ready)
        Should -Invoke Start-OSyncVerdaccioTask -Times 1 -Exactly
        Should -Invoke Stop-OSyncVerdaccioTask -Times 0 -Exactly

        # npmrc rewritten + backup
        $npmrc = Join-Path $script:naNodeInstall 'node_modules\npm\npmrc'
        [System.IO.File]::ReadAllText($npmrc) | Should -Match '(?m)^registry=http://127\.0\.0\.1:4873/\s*$'
        Test-Path -LiteralPath ($npmrc + '.osyncbak') -PathType Leaf | Should -Be $true

        # machine env var set
        Should -Invoke Set-OSyncMachineEnvVar -Times 1 -Exactly -ParameterFilter { $Name -eq 'NPM_CONFIG_REGISTRY' -and $Value -eq 'http://127.0.0.1:4873/' }

        # state updated
        $state = Get-OSyncState -Category 'npm' -StateDir $script:naStateDir
        $state.npm.registryOk | Should -Be $true
        $state.npm.at | Should -Not -BeNullOrEmpty
    }

    It 'returns a SINGLE report object - no leaked robocopy/log values in the pipeline' {
        $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg
        $result -is [System.Array] | Should -Be $false
        $result.GetType().Name | Should -Be 'PSCustomObject'
        @($result).Count | Should -Be 1
        @($result) | Where-Object { $_ -is [string] -or $_ -is [int] } | Should -BeNullOrEmpty
    }

    It 'stops a running task before the copy and restarts it after (strict order)' {
        Mock Get-OSyncVerdaccioTaskState { 'Running' }
        Mock Stop-OSyncVerdaccioTask { }
        $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg
        $result.registryOk | Should -Be $true
        Should -Invoke Stop-OSyncVerdaccioTask -Times 1 -Exactly
        Should -Invoke Start-OSyncVerdaccioTask -Times 1 -Exactly
    }

    It 'throws when the scheduled task does not exist, naming the seam' {
        Mock Get-OSyncVerdaccioTaskState { $null }
        $err = $null
        try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*PakageSync-Verdaccio*'
        $err.Exception.Message | Should -BeLike '*SkipVerdaccioTask*'
    }

    It 'throws with the port when the port is already in use before starting the task' {
        Mock Test-OSyncPortListening { $true }
        $err = $null
        try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*4873*'
    }

    It 'throws with the port when the port wait times out' {
        Mock Wait-OSyncPortListening { $false }
        $err = $null
        try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*4873*'
    }

    It 'throws when verdaccio-b.yml leaks an uplink' {
        $badWork = Join-Path $TestDrive 'bad-work'
        New-Item -ItemType Directory -Path $badWork -Force | Out-Null
        $null = New-NaWorkDir -Root $badWork -BadYaml
        $err = $null
        try { Invoke-OSyncNpmApply -WorkDir $badWork -Config $script:naCfg | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*uplinks*'
    }

    It 'throws when the nonexistent package does not fail fast' {
        Mock Invoke-ONpmCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'view' -and $Arguments[1] -like 'osync-nonexistent*') {
                return [pscustomobject]@{ ExitCode = -1; Output = @(); TimedOut = $true }
            }
            if ($Arguments[0] -eq 'view') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('{ "version": "3.0.1" }'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'config') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('http://127.0.0.1:4873/'); TimedOut = $false }
            }
            throw 'unexpected'
        }
        $err = $null
        try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*fail fast*'
    }

    It 'throws when a new process without flags does not resolve the local registry' {
        Mock Invoke-ONpmCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'view' -and $Arguments[1] -like 'osync-nonexistent*') {
                return [pscustomobject]@{ ExitCode = 1; Output = @('E404'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'view') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('{ "version": "3.0.1" }'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'config') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('https://registry.npmjs.org/'); TimedOut = $false }
            }
            throw 'unexpected'
        }
        $err = $null
        try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*npm config get registry*'
    }

    It '-SkipVerdaccioTask skips task management and the /MIR refresh' {
        Mock Get-OSyncVerdaccioTaskState { throw 'task functions must not be called with -SkipVerdaccioTask' }
        Mock Start-OSyncVerdaccioTask { throw 'task functions must not be called with -SkipVerdaccioTask' }
        Mock Stop-OSyncVerdaccioTask { throw 'task functions must not be called with -SkipVerdaccioTask' }
        Mock Invoke-OSyncRobocopy { throw 'robocopy must not be called with -SkipVerdaccioTask' }
        $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg -SkipVerdaccioTask
        $result.registryOk | Should -Be $true
        # no local copy created
        Test-Path -LiteralPath (Join-Path $script:naStateDir 'verdaccio') -PathType Container | Should -Be $false
    }

    It '-VerdaccioEndpoint skips task management, the refresh and the port wait' {
        Mock Get-OSyncVerdaccioTaskState { throw 'must not be called' }
        Mock Start-OSyncVerdaccioTask { throw 'must not be called' }
        Mock Stop-OSyncVerdaccioTask { throw 'must not be called' }
        Mock Invoke-OSyncRobocopy { throw 'must not be called' }
        Mock Wait-OSyncPortListening { throw 'must not be called' }
        Mock Invoke-ONpmCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'view' -and $Arguments[1] -like 'osync-nonexistent*') {
                return [pscustomobject]@{ ExitCode = 1; Output = @('E404'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'view') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('{ "version": "3.0.1" }'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'config') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('http://127.0.0.1:4999/'); TimedOut = $false }
            }
            throw 'unexpected'
        }
        $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg -VerdaccioEndpoint 'http://127.0.0.1:4999'
        $result.registryUrl | Should -Be 'http://127.0.0.1:4999'
        $result.registryOk | Should -Be $true
    }

    It 'uses config.verdaccioPort for the registry URL and the env var' {
        $cfg = New-NaConfig -StateDir $script:naStateDir -Port 4899
        Mock Invoke-ONpmCli {
            param([string[]]$Arguments)
            if ($Arguments[0] -eq 'view' -and $Arguments[1] -like 'osync-nonexistent*') {
                return [pscustomobject]@{ ExitCode = 1; Output = @('E404'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'view') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('{ "version": "3.0.1" }'); TimedOut = $false }
            }
            if ($Arguments[0] -eq 'config') {
                return [pscustomobject]@{ ExitCode = 0; Output = @('http://127.0.0.1:4899/'); TimedOut = $false }
            }
            throw 'unexpected'
        }
        $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $cfg
        $result.registryUrl | Should -Be 'http://127.0.0.1:4899'
        Should -Invoke Set-OSyncMachineEnvVar -Times 1 -Exactly -ParameterFilter { $Value -eq 'http://127.0.0.1:4899/' }
    }

    Context 'bun frontend verification' {
        BeforeEach {
            # bun frontend present: an empty dummy file under <stateDir>\bun
            # passes the Test-Path gate (the apply never executes a real bun -
            # Invoke-OBunCli is mocked).
            $script:naBunExe = Join-Path $script:naStateDir 'bun\bun.exe'
            New-Item -ItemType Directory -Path (Split-Path -Parent $script:naBunExe) -Force | Out-Null
            [System.IO.File]::WriteAllText($script:naBunExe, 'x')

            Mock Invoke-OBunCli {
                param([string]$BunExe, [string[]]$Arguments, [string]$RegistryUrl)
                if ($Arguments[0] -eq 'info' -and $Arguments[1] -like 'osync-nonexistent*') {
                    return [pscustomobject]@{ ExitCode = 1; Output = @('error: package not found (404)'); TimedOut = $false }
                }
                if ($Arguments[0] -eq 'info') {
                    return [pscustomobject]@{ ExitCode = 0; Output = @('3.0.1'); TimedOut = $false }
                }
                throw "unexpected Invoke-OBunCli args: $($Arguments -join ' ')"
            }
        }

        It 'gate: no bun.exe -> bun section disabled, Invoke-OBunCli never called, apply still succeeds' {
            Remove-Item -LiteralPath $script:naBunExe -Force
            Mock Invoke-OBunCli { throw 'Invoke-OBunCli must not be called when bun.exe is absent' }
            $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg
            $result.registryOk | Should -Be $true
            $result.bun.enabled | Should -Be $false
            Should -Invoke Invoke-OBunCli -Times 0 -Exactly
            # skipped bun leaves state.npm.bun untouched
            $state = Get-OSyncState -Category 'npm' -StateDir $script:naStateDir
            $state.npm.Contains('bun') | Should -Be $false
        }

        It 'picks the first bun-packages.txt entry when the delivered bun list exists' {
            [System.IO.File]::WriteAllText((Join-Path $script:naNpmDir 'bun-packages.txt'), "left-pad@1.3.0`nis-odd@3.0.1`n", (New-Object System.Text.UTF8Encoding($false)))
            Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null
            Should -Invoke Invoke-OBunCli -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'info' -and $Arguments[1] -eq 'left-pad@1.3.0' -and $Arguments[2] -eq 'version' }
        }

        It 'falls back to the packages.txt spec when no bun list was delivered' {
            Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null
            Should -Invoke Invoke-OBunCli -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'info' -and $Arguments[1] -eq 'is-odd@3.0.1' -and $Arguments[2] -eq 'version' }
        }

        It 'success: bun info + ghost fail-fast persist state.npm.bun.bunOk and the report carries the bun section' {
            $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg
            $result.bun.enabled | Should -Be $true
            $result.bun.bunExe | Should -Be $script:naBunExe
            $result.bun.viewSpec | Should -Be 'is-odd@3.0.1'
            $result.bun.ghostName | Should -Match '^osync-nonexistent-[0-9a-f]{8}$'
            $result.bun.ghostElapsedSec | Should -Not -BeNullOrEmpty
            # ghost package ran with the version subcommand and exited fast non-zero
            Should -Invoke Invoke-OBunCli -Times 1 -Exactly -ParameterFilter { $Arguments[1] -like 'osync-nonexistent*' -and $Arguments[2] -eq 'version' }
            $state = Get-OSyncState -Category 'npm' -StateDir $script:naStateDir
            $state.npm['bun']['bunOk'] | Should -Be $true
            $state.npm['bun']['at'] | Should -Not -BeNullOrEmpty
        }

        It 'throws when bun info fails (exit != 0)' {
            Mock Invoke-OBunCli {
                param([string[]]$Arguments)
                return [pscustomobject]@{ ExitCode = 1; Output = @('error: GET http://127.0.0.1:4873/is-odd - 500'); TimedOut = $false }
            }
            $err = $null
            try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
            catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*bun info is-odd@3.0.1 version*'
        }

        It 'throws when bun info times out' {
            Mock Invoke-OBunCli {
                param([string[]]$Arguments)
                return [pscustomobject]@{ ExitCode = -1; Output = @(); TimedOut = $true }
            }
            $err = $null
            try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
            catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*bun info is-odd@3.0.1 version*'
        }

        It 'throws when bun info returns no version in its output' {
            Mock Invoke-OBunCli {
                param([string[]]$Arguments)
                return [pscustomobject]@{ ExitCode = 0; Output = @('npm notice'); TimedOut = $false }
            }
            $err = $null
            try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
            catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*returned no version*'
        }

        It 'throws when the bun ghost package hangs (uplink suspicion)' {
            Mock Invoke-OBunCli {
                param([string[]]$Arguments)
                if ($Arguments[1] -like 'osync-nonexistent*') {
                    return [pscustomobject]@{ ExitCode = -1; Output = @(); TimedOut = $true }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = @('3.0.1'); TimedOut = $false }
            }
            $err = $null
            try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
            catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*fail fast*'
        }

        It 'throws when the bun ghost package unexpectedly succeeds' {
            Mock Invoke-OBunCli {
                param([string[]]$Arguments)
                if ($Arguments[1] -like 'osync-nonexistent*') {
                    return [pscustomobject]@{ ExitCode = 0; Output = @('1.0.0'); TimedOut = $false }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = @('3.0.1'); TimedOut = $false }
            }
            $err = $null
            try { Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null }
            catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*unexpectedly succeeded*'
        }

        It 'injects the registry URL ending in "/" and carrying the config port into every bun call' {
            Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg | Out-Null
            Should -Invoke Invoke-OBunCli -Times 2 -Exactly -ParameterFilter { $RegistryUrl -eq 'http://127.0.0.1:4873/' }
        }

        It '-VerdaccioEndpoint: the bun registry URL honors the endpoint override' {
            Mock Get-OSyncVerdaccioTaskState { throw 'task functions must not be called with -VerdaccioEndpoint' }
            Mock Start-OSyncVerdaccioTask { throw 'task functions must not be called with -VerdaccioEndpoint' }
            Mock Stop-OSyncVerdaccioTask { throw 'task functions must not be called with -VerdaccioEndpoint' }
            Mock Invoke-OSyncRobocopy { throw 'robocopy must not be called with -VerdaccioEndpoint' }
            Mock Wait-OSyncPortListening { throw 'port wait must not be called with -VerdaccioEndpoint' }
            Mock Invoke-ONpmCli {
                param([string[]]$Arguments)
                if ($Arguments[0] -eq 'view' -and $Arguments[1] -like 'osync-nonexistent*') {
                    return [pscustomobject]@{ ExitCode = 1; Output = @('E404'); TimedOut = $false }
                }
                if ($Arguments[0] -eq 'view') {
                    return [pscustomobject]@{ ExitCode = 0; Output = @('{ "version": "3.0.1" }'); TimedOut = $false }
                }
                if ($Arguments[0] -eq 'config') {
                    return [pscustomobject]@{ ExitCode = 0; Output = @('http://127.0.0.1:4999/'); TimedOut = $false }
                }
                throw 'unexpected'
            }
            $result = Invoke-OSyncNpmApply -WorkDir $script:naWork -Config $script:naCfg -VerdaccioEndpoint 'http://127.0.0.1:4999'
            $result.bun.enabled | Should -Be $true
            Should -Invoke Invoke-OBunCli -Times 2 -Exactly -ParameterFilter { $RegistryUrl -eq 'http://127.0.0.1:4999/' }
        }
    }
}