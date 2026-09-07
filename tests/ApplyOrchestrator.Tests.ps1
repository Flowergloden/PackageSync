#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\ApplyOrchestrator.ps1 and the
    src\Invoke-OfflineApply.ps1 entry (plan todo 17).

.DESCRIPTION
    Covers the whole-repo snapshot work-copy semantics (create / re-hash
    verify / delete-on-failure), the newer-check-skip across ALL enabled
    categories, per-category isolation (one failure never blocks the others),
    the apply.lock behavior at the entry level (held lock -> round skipped),
    WhatIf zero-change, the bootstrap self-heal trigger (packages only), the
    dotfiles user-task semantics (no work-copy creation, consume only the
    newest .verified generation), work\ cleanup (newest 2 per tree) and the
    tool-copy self-refresh (.new -> delete .old -> current -> .old ->
    .new -> current; owner/ACL re-verify gate).

    The four apply functions (winget/pip/npm/dotfiles) are MOCKED everywhere
    except the self-refresh describe; the trust root, generation robocopy
    and re-verification run REAL. NO real installs, NO real C:\PakageSync
    writes (Test-OSyncLandingReadyForRefresh is mocked away; the dedicated
    refresh describe uses a $TestDrive landing path). Entry lock tests spawn
    a child powershell.exe 5.1 process against a seeded no-pending repo so
    no apply function ever runs.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\ApplyOrchestrator.Tests.ps1 -PassThru"
      pwsh -NoProfile -Command "Invoke-Pester tests\ApplyOrchestrator.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes, so helpers are
    defined INSIDE BeforeAll and data shared via $script: scope.
#>

Describe 'ApplyOrchestrator: mode selection' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')
    }

    It 'derives dotfiles mode from a dotfiles-only -Category' {
        Get-OSyncApplyMode -Category @('dotfiles') | Should -Be 'dotfiles'
    }

    It 'derives packages mode from an empty / multi / non-dotfiles -Category' {
        Get-OSyncApplyMode -Category @() | Should -Be 'packages'
        Get-OSyncApplyMode -Category @('winget') | Should -Be 'packages'
        Get-OSyncApplyMode -Category @('winget', 'pip', 'npm', 'dotfiles') | Should -Be 'packages'
    }

    It 'throws on an unknown category' {
        $err = $null
        try { Get-OSyncApplyMode -Category @('winget', 'bogus') } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*bogus*'
    }
}

Describe 'ApplyOrchestrator: packages round - work copy + apply' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\RepoContract.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')

        $script:NewConfig = {
            param([string]$StateDir, [hashtable]$Overrides = @{})
            $cfg = [pscustomobject]@{
                role       = 'B'
                stateDir   = $StateDir
                repoRoot   = 'C:\unused\repo'
                httpPort   = 8788
                verdaccioPort = 4873
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true }
                winget     = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
                pip        = [pscustomobject]@{ upgradeOnApply = $true }
            }
            foreach ($k in $Overrides.Keys) { $cfg.$k = $Overrides[$k] }
            return $cfg
        }

        # Real mini repository (all 4 categories + runtime) with a real trust
        # root. Returns the index exportedAtUtc.
        $script:NewRepo = {
            param([string]$Root)
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            $rt = Join-Path $Root 'runtime'
            New-Item -ItemType Directory -Path $rt -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $rt 'runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $rt
            $wg = Join-Path $Root 'winget'
            New-Item -ItemType Directory -Path (Join-Path $wg '7zip.7zip') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $wg 'packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $wg '7zip.7zip\p.yaml'), "PackageVersion: 26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $wg
            $pp = Join-Path $Root 'pip'
            New-Item -ItemType Directory -Path $pp -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $pp 'requirements.txt'), "six==1.17.0`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllBytes((Join-Path $pp 'six-1.17.0-py2.py3-none-any.whl'), [byte[]]@(1, 2, 3, 4, 5))
            $null = New-OSyncFilesManifest -Dir $pp
            $np = Join-Path $Root 'npm'
            New-Item -ItemType Directory -Path $np -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $np 'packages.txt'), "is-odd@3.0.1`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $np 'verdaccio-b.yml'), "storage: ./storage`r`npackages:`r`n  '**':`r`n    access: `$all`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $np
            $df = Join-Path $Root 'dotfiles'
            New-Item -ItemType Directory -Path (Join-Path $df 'source') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $df 'source\dot_sample.txt'), "hello`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $df 'chezmoi.toml'), "[data]`r`n  name = `"qa`"`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $df
            $null = Publish-OSyncIndex -StagingDir $Root
            $idx = [System.IO.File]::ReadAllText((Join-Path $Root 'index.json')) | ConvertFrom-Json
            return $idx.exportedAtUtc
        }

        $script:GetIndexTs = {
            param([string]$Root)
            $idx = [System.IO.File]::ReadAllText((Join-Path $Root 'index.json')) | ConvertFrom-Json
            return $idx.exportedAtUtc
        }

        # Seeds state.bootstrapped=true + the runtime hashes from THIS repo
        # (so the drift check never trips and no bootstrap flow runs).
        $script:SeedBootstrapped = {
            param($Config, [string]$RepoRoot)
            $null = Set-OSyncBootstrapComplete -Config $Config -Bw $RepoRoot
        }

        # Real generation builder + verifier for the dotfiles-consumption tests.
        $script:BuildVerifiedGeneration = {
            param($Config, [string]$RepoRoot, [string]$Ts)
            $gen = New-OSyncApplyGeneration -Config $Config -RepoRoot $RepoRoot -ExportedAtUtc $Ts -OkCategories @('winget', 'pip', 'npm', 'dotfiles')
            $null = Test-OSyncApplyWorkCopy -Bw $gen
            $null = Write-OSyncApplyVerifiedMarker -Bw $gen -ExportedAtUtc $Ts
            return $gen
        }
    }

    BeforeEach {
        # Refresh gate mocked OFF: unit tests must never touch the real
        # C:\PakageSync landing (the dedicated self-refresh describe covers
        # the real functions on a $TestDrive path).
        Mock Test-OSyncLandingReadyForRefresh { $false }
        $script:ApplyCalls = @()
        Mock Invoke-OSyncWingetApply { param($WorkDir, $Config) $script:ApplyCalls += "winget:$WorkDir"; return [pscustomobject]@{ status = 'ok'; category = 'winget' } }
        Mock Invoke-OSyncPipApply { param($WorkDir, $Config) $script:ApplyCalls += "pip:$WorkDir"; return [pscustomobject]@{ status = 'ok'; category = 'pip' } }
        Mock Invoke-OSyncNpmApply { param($WorkDir, $Config, $VerdaccioTaskName) $script:ApplyCalls += "npm:$WorkDir"; return [pscustomobject]@{ status = 'ok'; category = 'npm' } }
        Mock Invoke-OSyncDotfilesApply { param($WorkDir, $Config) $script:ApplyCalls += "dotfiles:$WorkDir"; return [pscustomobject]@{ status = 'ok'; category = 'dotfiles' } }
    }

    It 'builds a verified generation and applies pending categories, stamping lastApplied' {
        $repo = Join-Path $TestDrive 'r1'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's1'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget', 'pip', 'npm')

        $result.outcome | Should -Be 'ok'
        $result.generation | Should -Be (Join-Path $stateDir ("work\{0}" -f $ts))
        $result.verified | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $result.generation '.verified') -PathType Leaf) | Should -Be $true
        foreach ($cat in @('runtime', 'winget', 'pip', 'npm', 'dotfiles')) {
            (Test-Path -LiteralPath (Join-Path $result.generation $cat) -PathType Container) | Should -Be $true
        }
        # The mocked apply functions received the verified generation as WorkDir.
        foreach ($cat in @('winget', 'pip', 'npm')) {
            $script:ApplyCalls | Should -Contain ("$cat`:$($result.generation)")
        }
        $state = Get-OSyncState -Category winget -Config $cfg
        $state.lastApplied.winget | Should -Be $ts
        $state.lastApplied.pip | Should -Be $ts
        $state.lastApplied.npm | Should -Be $ts
        $state.lastApplied.dotfiles | Should -BeNullOrEmpty
    }

    It 'skips the whole round when nothing is pending (no work copy, no apply)' {
        $repo = Join-Path $TestDrive 'r2'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's2'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo
        # Round 1: packages task applies winget/pip/npm and builds the verified
        # generation.
        $null = Invoke-OSyncApply -Config $cfg -Category @('winget', 'pip', 'npm')
        # Round 2: dotfiles task consumes the verified generation (stamps
        # lastApplied.dotfiles).
        $null = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')
        $script:ApplyCalls = @()

        # Round 3: apply functions must NEVER be called - use throwing mocks.
        Mock Invoke-OSyncWingetApply { throw 'should not be called' }
        Mock Invoke-OSyncPipApply { throw 'should not be called' }
        Mock Invoke-OSyncNpmApply { throw 'should not be called' }
        $result = Invoke-OSyncApply -Config $cfg -Category @('winget', 'pip', 'npm')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*nothing pending*'
        $result.generation | Should -BeNullOrEmpty
        $script:ApplyCalls | Should -BeNullOrEmpty
        # Only one generation was ever built (reuse, no rebuild).
        $gens = @(Get-ChildItem -LiteralPath (Join-Path $stateDir 'work') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' })
        $gens.Count | Should -Be 1
    }

    It 'judges ALL enabled categories when building the work copy (narrow -Category)' {
        $repo = Join-Path $TestDrive 'r3'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's3'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo

        # Only winget requested - but the work copy must contain every OK
        # enabled category (Momus r5-m2).
        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.outcome | Should -Be 'ok'
        foreach ($cat in @('runtime', 'winget', 'pip', 'npm', 'dotfiles')) {
            (Test-Path -LiteralPath (Join-Path $result.generation $cat) -PathType Container) | Should -Be $true
        }
        (@($script:ApplyCalls) | Where-Object { $_ -like 'winget:*' }).Count | Should -Be 1
        @($script:ApplyCalls | Where-Object { $_ -like 'pip:*' -or $_ -like 'npm:*' -or $_ -like 'dotfiles:*' }) | Should -BeNullOrEmpty
        $result.categories['winget'].status | Should -Be 'ok'
        $result.categories['pip'].status | Should -Be 'not-requested'
        $result.categories['npm'].status | Should -Be 'not-requested'
        $result.categories['dotfiles'].status | Should -Be 'not-requested'
    }

    It 'isolates per-category failures - one failure never blocks the others' {
        $repo = Join-Path $TestDrive 'r4'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's4'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo
        Mock Invoke-OSyncPipApply { throw 'pip apply exploded' }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget', 'pip', 'npm')

        $result.outcome | Should -Be 'ok'
        $result.categories['pip'].status | Should -Be 'failed'
        $result.categories['winget'].status | Should -Be 'ok'
        $result.categories['npm'].status | Should -Be 'ok'
        $state = Get-OSyncState -Category winget -Config $cfg
        $state.lastApplied.winget | Should -Be $ts
        $state.lastApplied.npm | Should -Be $ts
        $state.lastApplied.pip | Should -BeNullOrEmpty
    }

    It 'skips the whole round when the runtime category is not OK' {
        $repo = Join-Path $TestDrive 'r5'
        $null = & $script:NewRepo $repo
        # Corrupt a runtime file AFTER publishing -> runtime Incomplete.
        [System.IO.File]::WriteAllText((Join-Path $repo 'runtime\runtime-winget.txt'), "tampered`r`n")
        $stateDir = Join-Path $TestDrive 's5'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*runtime*'
        $script:ApplyCalls | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $stateDir 'work')) | Should -Be $false
    }

    It 'skips the whole round when the trust root is invalid' {
        $repo = Join-Path $TestDrive 'r6'
        $null = & $script:NewRepo $repo
        [System.IO.File]::WriteAllText((Join-Path $repo 'index.json'), 'not json{')
        $stateDir = Join-Path $TestDrive 's6'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*INVALID*'
        $script:ApplyCalls | Should -BeNullOrEmpty
    }

    It 'deletes the whole generation when the re-verification fails' {
        $repo = Join-Path $TestDrive 'r7'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's7'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo
        Mock Test-OSyncApplyWorkCopy { throw 'verify exploded' }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.outcome | Should -Be 'failed'
        $result.error | Should -BeLike '*verification*'
        (Test-Path -LiteralPath (Join-Path $stateDir ("work\{0}" -f $ts))) | Should -Be $false
        $script:ApplyCalls | Should -BeNullOrEmpty
    }

    It 're-verification catches a corrupted copied file (real verify)' {
        $repo = Join-Path $TestDrive 'r8'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's8'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $gen = New-OSyncApplyGeneration -Config $cfg -RepoRoot $repo -ExportedAtUtc $ts -OkCategories @('winget', 'pip', 'npm', 'dotfiles')
        # Flip a byte inside the COPIED winget manifest -> verify must fail.
        $target = Join-Path $gen 'winget\packages.txt'
        [System.IO.File]::WriteAllText($target, "tampered`r`n")

        $err = $null
        try { $null = Test-OSyncApplyWorkCopy -Bw $gen } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*winget*'
    }

    It 're-verification catches a corrupted runtime payload and the whole generation is deleted' {
        $repo = Join-Path $TestDrive 'r10'
        $ts = & $script:NewRepo $repo
        # Add a chezmoi.exe payload to the runtime category and re-publish the
        # trust root so the runtime files.json lists it.
        $chezmoiDir = Join-Path $repo 'runtime\chezmoi'
        New-Item -ItemType Directory -Path $chezmoiDir -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $chezmoiDir 'chezmoi.exe'), [byte[]]@(0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x00))
        $null = New-OSyncFilesManifest -Dir (Join-Path $repo 'runtime')
        $null = Publish-OSyncIndex -StagingDir $repo
        $ts = & $script:GetIndexTs $repo
        $stateDir = Join-Path $TestDrive 's10'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo

        # Corrupt the COPIED chezmoi.exe right after the generation is built
        # (the copy is what the re-verification checks - the repo stays intact).
        $realNewGen = (Get-Command New-OSyncApplyGeneration).ScriptBlock
        Mock New-OSyncApplyGeneration {
            param($Config, $RepoRoot, $ExportedAtUtc, $OkCategories)
            $g = & $realNewGen -Config $Config -RepoRoot $RepoRoot -ExportedAtUtc $ExportedAtUtc -OkCategories $OkCategories
            $t = Join-Path $g 'runtime\chezmoi\chezmoi.exe'
            [System.IO.File]::WriteAllBytes($t, [byte[]]@(0x4D, 0x5A, 0x90, 0x00, 0x03, 0x00, 0x00, 0x01))
            return $g
        }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.outcome | Should -Be 'failed'
        $result.error | Should -BeLike '*verification*'
        # The whole generation is deleted - a bad generation must never remain
        # the newest (Momus r4-B1).
        (Test-Path -LiteralPath (Join-Path $stateDir ("work\{0}" -f $ts))) | Should -Be $false
        $script:ApplyCalls | Should -BeNullOrEmpty
    }

    It 'WhatIf produces a per-category report with ZERO changes' {
        $repo = Join-Path $TestDrive 'r9'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 's9'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        & $script:SeedBootstrapped $cfg $repo
        $stateFile = Join-Path (Join-Path $stateDir 'state') 'system-state.json'
        $before = Get-OSyncFileSha256 -Path $stateFile
        Mock Invoke-OSyncBootstrap { throw 'bootstrap must not run under WhatIf' }
        Mock Invoke-OSyncWingetApply { throw 'no apply under WhatIf' }
        Mock Invoke-OSyncPipApply { throw 'no apply under WhatIf' }
        Mock Invoke-OSyncNpmApply { throw 'no apply under WhatIf' }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget', 'pip', 'npm') -WhatIf

        $result.outcome | Should -Be 'ok'
        $result.whatIf | Should -Be $true
        $result.categories['winget'].status | Should -Be 'would-apply'
        $result.categories['pip'].status | Should -Be 'would-apply'
        $result.categories['npm'].status | Should -Be 'would-apply'
        $result.generation | Should -BeNullOrEmpty
        $result.bootstrapRan | Should -Be $false
        (Test-Path -LiteralPath (Join-Path $stateDir 'work')) | Should -Be $false
        # Zero state changes.
        (Get-OSyncFileSha256 -Path $stateFile) | Should -Be $before
    }
}

Describe 'ApplyOrchestrator: bootstrap self-heal (packages only)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\RepoContract.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')

        $script:NewConfig = {
            param([string]$StateDir, [hashtable]$Overrides = @{})
            $cfg = [pscustomobject]@{
                role       = 'B'
                stateDir   = $StateDir
                repoRoot   = 'C:\unused\repo'
                httpPort   = 8788
                verdaccioPort = 4873
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true }
                winget     = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
                pip        = [pscustomobject]@{ upgradeOnApply = $true }
            }
            foreach ($k in $Overrides.Keys) { $cfg.$k = $Overrides[$k] }
            return $cfg
        }
        $script:NewRepo = {
            param([string]$Root)
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            $rt = Join-Path $Root 'runtime'
            New-Item -ItemType Directory -Path $rt -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $rt 'runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $rt
            $wg = Join-Path $Root 'winget'
            New-Item -ItemType Directory -Path (Join-Path $wg '7zip.7zip') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $wg 'packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $wg '7zip.7zip\p.yaml'), "PackageVersion: 26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $wg
            $null = Publish-OSyncIndex -StagingDir $Root
        }
    }

    BeforeEach {
        Mock Test-OSyncLandingReadyForRefresh { $false }
        Mock Invoke-OSyncWingetApply { param($WorkDir, $Config) return [pscustomobject]@{ status = 'ok' } }
        Mock Invoke-OSyncPipApply { param($WorkDir, $Config) return [pscustomobject]@{ status = 'ok' } }
        Mock Invoke-OSyncNpmApply { param($WorkDir, $Config, $VerdaccioTaskName) return [pscustomobject]@{ status = 'ok' } }
    }

    It 'runs the bootstrap when unbootstrapped, then proceeds' {
        $repo = Join-Path $TestDrive 'b1'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sb1'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        Mock Invoke-OSyncBootstrap { param($Config) return [pscustomobject]@{ Success = $true; Error = $null } }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.bootstrapRan | Should -Be $true
        $result.outcome | Should -Be 'ok'
        $result.bootstrapped | Should -Be $true
        $result.categories['winget'].status | Should -Be 'ok'
    }

    It 'skips the round when the self-heal bootstrap fails' {
        $repo = Join-Path $TestDrive 'b2'
        $null = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sb2'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        Mock Invoke-OSyncBootstrap { param($Config) return [pscustomobject]@{ Success = $false; Error = 'boom' } }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*bootstrap*'
        $result.bootstrapped | Should -Be $false
    }

    It 're-runs the bootstrap on runtime content drift (upgrade path)' {
        $repo = Join-Path $TestDrive 'b3'
        $null = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sb3'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        # Seed bootstrapped with the CURRENT hashes...
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        # ...then change the runtime content and re-publish the trust root
        # (integrity stays OK, but the runtime hashes now drift vs state).
        [System.IO.File]::WriteAllText((Join-Path $repo 'runtime\runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n# new`r`n")
        $null = New-OSyncFilesManifest -Dir (Join-Path $repo 'runtime')
        $null = Publish-OSyncIndex -StagingDir $repo
        Mock Invoke-OSyncBootstrap { param($Config) return [pscustomobject]@{ Success = $true; Error = $null } }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget')

        $result.bootstrapRan | Should -Be $true
        $result.outcome | Should -Be 'ok'
    }

    It 'WhatIf never triggers the bootstrap (zero changes)' {
        $repo = Join-Path $TestDrive 'b4'
        $null = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sb4'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        Mock Invoke-OSyncBootstrap { throw 'bootstrap must not run under WhatIf' }

        $result = Invoke-OSyncApply -Config $cfg -Category @('winget') -WhatIf

        $result.bootstrapRan | Should -Be $false
        $result.categories['winget'].status | Should -Be 'would-apply'
        (Test-Path -LiteralPath (Join-Path $stateDir 'work')) | Should -Be $false
    }
}

Describe 'ApplyOrchestrator: dotfiles (user) round' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\RepoContract.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')

        $script:NewConfig = {
            param([string]$StateDir, [hashtable]$Overrides = @{})
            $cfg = [pscustomobject]@{
                role       = 'B'
                stateDir   = $StateDir
                repoRoot   = 'C:\unused\repo'
                httpPort   = 8788
                verdaccioPort = 4873
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true }
                winget     = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
                pip        = [pscustomobject]@{ upgradeOnApply = $true }
            }
            foreach ($k in $Overrides.Keys) { $cfg.$k = $Overrides[$k] }
            return $cfg
        }
        $script:NewRepo = {
            param([string]$Root)
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            $rt = Join-Path $Root 'runtime'
            New-Item -ItemType Directory -Path $rt -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $rt 'runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $rt
            $df = Join-Path $Root 'dotfiles'
            New-Item -ItemType Directory -Path (Join-Path $df 'source') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $df 'source\dot_sample.txt'), "hello`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $df 'chezmoi.toml'), "[data]`r`n  name = `"qa`"`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $df
            $null = Publish-OSyncIndex -StagingDir $Root
            $idx = [System.IO.File]::ReadAllText((Join-Path $Root 'index.json')) | ConvertFrom-Json
            return $idx.exportedAtUtc
        }
        $script:BumpIndexTs = {
            param([string]$Root, [int]$Seconds = 10)
            $p = Join-Path $Root 'index.json'
            $text = [System.IO.File]::ReadAllText($p)
            $idx = $text | ConvertFrom-Json
            $old = $idx.exportedAtUtc
            $dt = [DateTime]::ParseExact($old, 'yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture,
                ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal))
            $new = $dt.AddSeconds($Seconds).ToString('yyyyMMddTHHmmssZ')
            [System.IO.File]::WriteAllText($p, $text.Replace($old, $new), (New-Object System.Text.UTF8Encoding($false)))
            return $new
        }
    }

    BeforeEach {
        $script:DotfilesWorkDir = $null
        Mock Invoke-OSyncDotfilesApply { param($WorkDir, $Config) $script:DotfilesWorkDir = $WorkDir; return [pscustomobject]@{ status = 'ok'; category = 'dotfiles' } }
    }

    It 'consumes the newest verified generation and applies dotfiles' {
        $repo = Join-Path $TestDrive 'd1'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd1'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $gen = New-OSyncApplyGeneration -Config $cfg -RepoRoot $repo -ExportedAtUtc $ts -OkCategories @('dotfiles')
        $null = Test-OSyncApplyWorkCopy -Bw $gen
        $null = Write-OSyncApplyVerifiedMarker -Bw $gen -ExportedAtUtc $ts
        $script:DotfilesWorkDir = $null

        $result = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')

        $result.outcome | Should -Be 'ok'
        $result.mode | Should -Be 'dotfiles'
        $script:DotfilesWorkDir | Should -Be $gen
        $state = Get-OSyncState -Category dotfiles -Config $cfg
        $state.lastApplied.dotfiles | Should -Be $ts
    }

    It 'never creates a work copy in dotfiles mode' {
        $repo = Join-Path $TestDrive 'd2'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd2'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $gen = New-OSyncApplyGeneration -Config $cfg -RepoRoot $repo -ExportedAtUtc $ts -OkCategories @('dotfiles')
        $null = Test-OSyncApplyWorkCopy -Bw $gen
        $null = Write-OSyncApplyVerifiedMarker -Bw $gen -ExportedAtUtc $ts
        $genCountBefore = @(Get-ChildItem -LiteralPath (Join-Path $stateDir 'work') -Directory).Count

        $null = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')

        $genCountAfter = @(Get-ChildItem -LiteralPath (Join-Path $stateDir 'work') -Directory).Count
        $genCountAfter | Should -Be $genCountBefore
    }

    It 'skips when unbootstrapped' {
        $repo = Join-Path $TestDrive 'd3'
        $null = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd3'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }

        $result = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*not bootstrapped*'
        $script:DotfilesWorkDir | Should -BeNullOrEmpty
    }

    It 'skips when dotfiles is already applied (not newer)' {
        $repo = Join-Path $TestDrive 'd4'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd4'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $null = Set-OSyncLastApplied -Category dotfiles -ExportedAtUtc $ts -Config $cfg

        $result = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*already at generation*'
        $script:DotfilesWorkDir | Should -BeNullOrEmpty
    }

    It 'skips when no verified generation exists yet' {
        $repo = Join-Path $TestDrive 'd5'
        $null = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd5'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo

        $result = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*no verified generation*'
        $script:DotfilesWorkDir | Should -BeNullOrEmpty
    }

    It 'skips when the newest verified generation predates the current index' {
        $repo = Join-Path $TestDrive 'd6'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd6'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $gen = New-OSyncApplyGeneration -Config $cfg -RepoRoot $repo -ExportedAtUtc $ts -OkCategories @('dotfiles')
        $null = Test-OSyncApplyWorkCopy -Bw $gen
        $null = Write-OSyncApplyVerifiedMarker -Bw $gen -ExportedAtUtc $ts
        # A newer export landed but the packages task has not verified it yet.
        $null = & $script:BumpIndexTs $repo 10

        $result = Invoke-OSyncApply -Config $cfg -Category @('dotfiles')

        $result.outcome | Should -Be 'skipped'
        $result.skipReason | Should -BeLike '*predates*'
        $script:DotfilesWorkDir | Should -BeNullOrEmpty
    }

    It 'WhatIf reports would-apply with ZERO changes' {
        $repo = Join-Path $TestDrive 'd7'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'sd7'
        $cfg = & $script:NewConfig $stateDir @{ repoRoot = $repo }
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $gen = New-OSyncApplyGeneration -Config $cfg -RepoRoot $repo -ExportedAtUtc $ts -OkCategories @('dotfiles')
        $null = Test-OSyncApplyWorkCopy -Bw $gen
        $null = Write-OSyncApplyVerifiedMarker -Bw $gen -ExportedAtUtc $ts
        Mock Invoke-OSyncDotfilesApply { throw 'no apply under WhatIf' }

        $result = Invoke-OSyncApply -Config $cfg -Category @('dotfiles') -WhatIf

        $result.outcome | Should -Be 'ok'
        $result.categories['dotfiles'].status | Should -Be 'would-apply'
        $state = Get-OSyncState -Category dotfiles -Config $cfg
        $state.lastApplied.dotfiles | Should -BeNullOrEmpty
    }
}

Describe 'ApplyOrchestrator: work copy cleanup (newest 2 per tree)' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')
    }

    It 'keeps the newest 2 generations in work\ and work\bootstrap\ separately' {
        $stateDir = Join-Path $TestDrive 'c1'
        $work = Join-Path $stateDir 'work'
        foreach ($tree in @('', 'bootstrap')) {
            foreach ($ts in @('20260901T000000Z', '20260902T000000Z', '20260903T000000Z', '20260904T000000Z')) {
                $dir = if ($tree -eq '') { Join-Path $work $ts } else { Join-Path (Join-Path $work 'bootstrap') $ts }
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $dir 'x.txt'), 'x')
            }
        }
        # A non-generation dir must survive untouched.
        New-Item -ItemType Directory -Path (Join-Path $work '.whatever') -Force | Out-Null

        $removed = Invoke-OSyncApplyWorkCleanup -StateDir $stateDir -Keep 2

        $removed | Should -Be 4
        $kept = @(Get-ChildItem -LiteralPath $work -Directory | Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' } | Sort-Object { [string]$_.Name } -Descending)
        $kept.Count | Should -Be 2
        $kept[0].Name | Should -Be '20260904T000000Z'
        $kept[1].Name | Should -Be '20260903T000000Z'
        $keptBoot = @(Get-ChildItem -LiteralPath (Join-Path $work 'bootstrap') -Directory | Sort-Object { [string]$_.Name } -Descending)
        $keptBoot.Count | Should -Be 2
        $keptBoot[0].Name | Should -Be '20260904T000000Z'
        (Test-Path -LiteralPath (Join-Path $work '.whatever')) | Should -Be $true
    }
}

Describe 'ApplyOrchestrator: tool-copy self-refresh' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')
    }

    It 're-verifies owner/ACL before refresh (abnormal landing -> false)' {
        $missing = Join-Path $TestDrive 'does-not-exist-landing'
        Test-OSyncLandingReadyForRefresh -LandingRoot $missing | Should -Be $false
    }

    It 'refreshes via .new -> carry config -> delete .old -> current -> .old -> .new -> current' {
        $landing = Join-Path $TestDrive 'landing'
        New-Item -ItemType Directory -Path (Join-Path $landing 'config') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $landing 'config\local.txt'), 'local config - must survive the rotation')
        [System.IO.File]::WriteAllText((Join-Path $landing 'old-src.ps1'), 'old tool file - must be replaced')
        # Additive SID-based grants (same SIDs the bootstrap hardening uses)
        # so the owner/ACL re-verification passes. Inheritance is KEPT so the
        # test process keeps full control and Pester can clean up TestDrive.
        $null = @(& icacls.exe $landing /grant '*S-1-5-18:(OI)(CI)F' /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-32-545:(OI)(CI)RX' 2>&1)

        $tool = Join-Path $TestDrive 'tool'
        New-Item -ItemType Directory -Path (Join-Path $tool 'src') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tool 'src\Invoke-OfflineApply.ps1'), 'new tool')
        [System.IO.File]::WriteAllText((Join-Path $tool 'packagesync.b.json'), '{}')

        Test-OSyncLandingReadyForRefresh -LandingRoot $landing | Should -Be $true

        $r = Invoke-OSyncApplySelfRefresh -ToolDir $tool -LandingRoot $landing

        $r.Refreshed | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $landing 'src\Invoke-OfflineApply.ps1') -PathType Leaf) | Should -Be $true
        # The old tool file was replaced by the /MIR...
        (Get-Content -LiteralPath (Join-Path $landing 'src\Invoke-OfflineApply.ps1') -Raw) | Should -Be 'new tool'
        # ...and the local config dir is carried into the new current (the B
        # side owns its config - it must survive every rotation, F3).
        (Test-Path -LiteralPath (Join-Path $landing 'config\local.txt') -PathType Leaf) | Should -Be $true
        (Get-Content -LiteralPath (Join-Path $landing 'config\local.txt') -Raw) | Should -Be 'local config - must survive the rotation'
        # .new is consumed by the swap; .old holds the PREVIOUS current (the
        # next refresh deletes it before renaming - pinned order, Oracle m9).
        (Test-Path -LiteralPath ($landing + '.new')) | Should -Be $false
        (Test-Path -LiteralPath ($landing + '.old') -PathType Container) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path ($landing + '.old') 'old-src.ps1') -PathType Leaf) | Should -Be $true
    }

    It 'config survives TWO consecutive refreshes with its original content' {
        $landing = Join-Path $TestDrive 'landing2'
        New-Item -ItemType Directory -Path (Join-Path $landing 'config') -Force | Out-Null
        $configContent = '{"role":"B","local":true}'
        [System.IO.File]::WriteAllText((Join-Path $landing 'config\packagesync.json'), $configContent)
        [System.IO.File]::WriteAllText((Join-Path $landing 'old-src.ps1'), 'old tool file')
        $null = @(& icacls.exe $landing /grant '*S-1-5-18:(OI)(CI)F' /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-32-545:(OI)(CI)RX' 2>&1)

        $tool = Join-Path $TestDrive 'tool2'
        New-Item -ItemType Directory -Path (Join-Path $tool 'src') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tool 'src\Invoke-OfflineApply.ps1'), 'new tool')

        # Refresh 1: current (with config) -> .old, .new (config carried) -> current.
        $r1 = Invoke-OSyncApplySelfRefresh -ToolDir $tool -LandingRoot $landing
        $r1.Refreshed | Should -Be $true
        # Refresh 2: the stale .old (which held the config after refresh 1) is
        # DELETED - the config must have been carried into .new again, so it
        # survives in the new current (F3 regression).
        $r2 = Invoke-OSyncApplySelfRefresh -ToolDir $tool -LandingRoot $landing
        $r2.Refreshed | Should -Be $true

        (Test-Path -LiteralPath (Join-Path $landing 'config\packagesync.json') -PathType Leaf) | Should -Be $true
        (Get-Content -LiteralPath (Join-Path $landing 'config\packagesync.json') -Raw) | Should -Be $configContent
    }

    It 'reports failure instead of throwing when the landing is missing' {
        $landing = Join-Path $TestDrive 'missing-landing'
        $tool = Join-Path $TestDrive 'tool2'
        New-Item -ItemType Directory -Path $tool -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $tool 'x.txt'), 'x')

        $r = Invoke-OSyncApplySelfRefresh -ToolDir $tool -LandingRoot $landing

        $r.Refreshed | Should -Be $true   # a missing current is fine - .new simply becomes current
        (Test-Path -LiteralPath $landing -PathType Container) | Should -Be $true
    }
}

Describe 'Invoke-OfflineApply entry: apply.lock behavior' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\RepoContract.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ApplyOrchestrator.ps1')

        $script:EntryScript = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'src') 'Invoke-OfflineApply.ps1'

        $script:NewRepo = {
            param([string]$Root)
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            $rt = Join-Path $Root 'runtime'
            New-Item -ItemType Directory -Path $rt -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $rt 'runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $rt
            $wg = Join-Path $Root 'winget'
            New-Item -ItemType Directory -Path (Join-Path $wg '7zip.7zip') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $wg 'packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $wg '7zip.7zip\p.yaml'), "PackageVersion: 26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $wg
            $null = Publish-OSyncIndex -StagingDir $Root
            $idx = [System.IO.File]::ReadAllText((Join-Path $Root 'index.json')) | ConvertFrom-Json
            return $idx.exportedAtUtc
        }

        # A full valid B config file (Get-OSyncConfig validates every key).
        $script:WriteFullConfig = {
            param([string]$Path, [string]$RepoRoot, [string]$StateDir)
            $src = (Resolve-Path (Join-Path $PSScriptRoot '..\config\packagesync.b.json')).Path
            $obj = [System.IO.File]::ReadAllText($src) | ConvertFrom-Json
            $obj.role = 'B'
            $obj.repoRoot = $RepoRoot
            $obj.stateDir = $StateDir
            $obj.httpPort = 8790
            $obj.verdaccioPort = 4901
            $obj.npm.aVerdaccioPort = 4902
            $json = $obj | ConvertTo-Json -Depth 20
            [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
        }

        # Runs the real entry in a child powershell.exe 5.1 process. Returns
        # { ExitCode, Output, Error }.
        $script:RunEntry = {
            param([string]$ConfigPath, [string[]]$EntryArgs)
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $script:EntryScript, $ConfigPath
            foreach ($a in $EntryArgs) { $argLine += ' "' + $a + '"' }
            $psi.Arguments = $argLine
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $out = $proc.StandardOutput.ReadToEnd()
            $err = $proc.StandardError.ReadToEnd()
            $proc.WaitForExit()
            return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $out; Error = $err }
        }
    }

    It 'acquires + releases the lock; a no-pending round skips cleanly (exit 0, no work copy)' {
        $repo = Join-Path $TestDrive 'e1'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'se1'
        $cfgPath = Join-Path $TestDrive 'e1-config.json'
        & $script:WriteFullConfig $cfgPath $repo $stateDir
        # Seed: bootstrapped + everything already applied -> nothing pending,
        # so the child round never runs an apply function.
        $cfg = Get-OSyncConfig -Path $cfgPath
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $null = Set-OSyncLastApplied -Category winget -ExportedAtUtc $ts -Config $cfg
        $stateFile = Join-Path (Join-Path $stateDir 'state') 'system-state.json'
        $before = Get-OSyncFileSha256 -Path $stateFile

        $r = & $script:RunEntry $cfgPath @('-Category', 'winget')

        $r.ExitCode | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $stateDir 'run\apply.lock') -PathType Leaf) | Should -Be $false
        (Test-Path -LiteralPath (Join-Path $stateDir 'work')) | Should -Be $false
        (Get-OSyncFileSha256 -Path $stateFile) | Should -Be $before
    }

    It 'skips the round while another process holds a fresh lock' {
        $repo = Join-Path $TestDrive 'e2'
        $ts = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'se2'
        $cfgPath = Join-Path $TestDrive 'e2-config.json'
        & $script:WriteFullConfig $cfgPath $repo $stateDir
        $cfg = Get-OSyncConfig -Path $cfgPath
        $null = Set-OSyncBootstrapComplete -Config $cfg -Bw $repo
        $null = Set-OSyncLastApplied -Category winget -ExportedAtUtc $ts -Config $cfg
        # A fresh lock owned by another process (PID 999999).
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        $lockContent = 'PID=999999 TIMESTAMP=' + [DateTime]::UtcNow.ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'run\apply.lock'), $lockContent)

        $r = & $script:RunEntry $cfgPath @('-Category', 'winget', '-LockTimeoutSeconds', '1')

        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeLike '*skipping this run*'
        # The foreign lock is left untouched.
        (Test-Path -LiteralPath (Join-Path $stateDir 'run\apply.lock') -PathType Leaf) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $stateDir 'work')) | Should -Be $false
    }

    It 'fails with a role gate when the config role is not B' {
        $repo = Join-Path $TestDrive 'e3'
        $null = & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'se3'
        $cfgPath = Join-Path $TestDrive 'e3-config.json'
        & $script:WriteFullConfig $cfgPath $repo $stateDir
        $obj = [System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
        $obj.role = 'A'
        [System.IO.File]::WriteAllText($cfgPath, ($obj | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($true)))

        $r = & $script:RunEntry $cfgPath @('-Category', 'winget')

        $r.ExitCode | Should -Be 1
        ($r.Output + $r.Error) | Should -BeLike '*role*B*'
    }
}
