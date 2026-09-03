# State.Tests.ps1
#
# Pester 5 tests for src\lib\State.ps1 - the dual-store B-side state.
#
# The libraries are dot-sourced DIRECTLY (not via the OfflineSync module) so
# this suite runs standalone. Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\State.Tests.ps1 -PassThru"
#   pwsh      -NoProfile -Command "Invoke-Pester tests\State.Tests.ps1 -PassThru"
#
# Every test uses $TestDrive subdirectories only - the real state dir
# (C:\ProgramData\PakageSync) is NEVER touched.

BeforeAll {
    # State.ps1 depends on Util.ps1 (ConvertTo-OSyncJson); dot-source both.
    . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
    . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
}

Describe 'dual-store round-trip' {
    It 'Save-OSyncState places the SYSTEM store under state\ and the USER store under run\' {
        $sd = Join-Path $TestDrive 'rt1'
        $st = Get-OSyncState -Category winget -StateDir $sd
        $st.lastApplied.winget = '20260901T000000Z'
        $st.winget['7zip.7zip'] = [ordered]@{ version = '26.02'; sha256 = 'ABCDEF' }
        Save-OSyncState -Category winget -State $st -StateDir $sd | Out-Null

        $ud = Get-OSyncState -Category dotfiles -StateDir $sd
        $ud.lastApplied.dotfiles = '20260902T000000Z'
        Save-OSyncState -Category dotfiles -State $ud -StateDir $sd | Out-Null

        (Test-Path -LiteralPath (Join-Path $sd 'state\system-state.json')) | Should -BeTrue
        (Test-Path -LiteralPath (Join-Path $sd 'run\user-state.json')) | Should -BeTrue
    }

    It 'round-trips records and lastApplied identical to what was saved' {
        $sd = Join-Path $TestDrive 'rt2'
        $st = Get-OSyncState -Category winget -StateDir $sd
        $st.lastApplied.winget = '20260901T000000Z'
        $st.lastApplied.pip    = '20260801T000000Z'
        $st.winget['7zip.7zip'] = [ordered]@{ version = '26.02'; sha256 = 'AAAA' }
        $st.winget['Foo.Bar']   = [ordered]@{ version = '1.0'; sha256 = 'BBBB' }
        $st.bootstrapped = $true
        Save-OSyncState -Category winget -State $st -StateDir $sd | Out-Null

        $rt = Get-OSyncState -Category winget -StateDir $sd
        $rt.schemaVersion | Should -Be 1
        $rt.bootstrapped | Should -BeTrue
        $rt.lastApplied.winget | Should -Be '20260901T000000Z'
        $rt.lastApplied.pip | Should -Be '20260801T000000Z'
        $rt.lastApplied.npm | Should -BeNullOrEmpty
        $rt.winget['7zip.7zip'].version | Should -Be '26.02'
        $rt.winget['7zip.7zip'].sha256 | Should -Be 'AAAA'
        $rt.winget['Foo.Bar'].version | Should -Be '1.0'
        $rt.wingetExePath | Should -BeNullOrEmpty
    }

    It 'a missing store returns the documented empty schema without warnings or files' {
        $sd = Join-Path $TestDrive 'rt3-missing'
        $w = @()
        $st = Get-OSyncState -Category npm -StateDir $sd -WarningVariable w -WarningAction SilentlyContinue

        $st.schemaVersion | Should -Be 1
        $st.bootstrapped | Should -BeFalse
        $st.lastApplied.npm | Should -BeNullOrEmpty
        @($st.npm.Keys).Count | Should -Be 0
        @($w).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $sd 'state\system-state.json')) | Should -BeFalse
    }

    It 'writes UTF-8 with BOM and leaves no temp files behind' {
        $sd = Join-Path $TestDrive 'rt4'
        $st = Get-OSyncState -Category winget -StateDir $sd
        $st.winget['A.B'] = [ordered]@{ version = '1.0'; sha256 = 'CC' }
        Save-OSyncState -Category winget -State $st -StateDir $sd | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $sd 'state\system-state.json'))
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
        @(Get-ChildItem -LiteralPath $sd -Recurse -File -Filter '*.tmp').Count | Should -Be 0
    }
}

Describe 'Test-OSyncCategoryNewer' {
    It 'returns true when lastApplied is null (category never applied)' {
        $sd = Join-Path $TestDrive 'nc1'
        Test-OSyncCategoryNewer -Category pip -ExportedAtUtc '20260901T000000Z' -StateDir $sd | Should -BeTrue
    }

    It 'returns true when exportedAtUtc is later than lastApplied' {
        $sd = Join-Path $TestDrive 'nc2'
        $null = Set-OSyncLastApplied -Category winget -ExportedAtUtc '20260901T000000Z' -StateDir $sd
        Test-OSyncCategoryNewer -Category winget -ExportedAtUtc '20260902T000000Z' -StateDir $sd | Should -BeTrue
    }

    It 'returns false when exportedAtUtc equals lastApplied' {
        $sd = Join-Path $TestDrive 'nc3'
        $null = Set-OSyncLastApplied -Category winget -ExportedAtUtc '20260902T000000Z' -StateDir $sd
        Test-OSyncCategoryNewer -Category winget -ExportedAtUtc '20260902T000000Z' -StateDir $sd | Should -BeFalse
    }

    It 'returns false when exportedAtUtc is earlier than lastApplied' {
        $sd = Join-Path $TestDrive 'nc4'
        $null = Set-OSyncLastApplied -Category winget -ExportedAtUtc '20260902T000000Z' -StateDir $sd
        Test-OSyncCategoryNewer -Category winget -ExportedAtUtc '20260901T000000Z' -StateDir $sd | Should -BeFalse
    }

    It 'covers the USER store (dotfiles) the same way' {
        $sd = Join-Path $TestDrive 'nc5'
        Test-OSyncCategoryNewer -Category dotfiles -ExportedAtUtc '20260901T000000Z' -StateDir $sd | Should -BeTrue
        $null = Set-OSyncLastApplied -Category dotfiles -ExportedAtUtc '20260903T000000Z' -StateDir $sd
        Test-OSyncCategoryNewer -Category dotfiles -ExportedAtUtc '20260903T000000Z' -StateDir $sd | Should -BeFalse
        Test-OSyncCategoryNewer -Category dotfiles -ExportedAtUtc '20260904T000000Z' -StateDir $sd | Should -BeTrue
    }

    It 'throws on a malformed ExportedAtUtc format' {
        $sd = Join-Path $TestDrive 'nc6'
        { Test-OSyncCategoryNewer -Category winget -ExportedAtUtc '2026-09-01T00:00:00Z' -StateDir $sd } |
            Should -Throw -ExpectedMessage "*yyyyMMddTHHmmssZ*"
        { Test-OSyncCategoryNewer -Category winget -ExportedAtUtc 'garbage' -StateDir $sd } |
            Should -Throw -ExpectedMessage "*yyyyMMddTHHmmssZ*"
    }
}

Describe 'Add-OSyncStateRecord' {
    It 'records into the correct category tables of the SYSTEM store and persists' {
        $sd = Join-Path $TestDrive 'ar1'
        Add-OSyncStateRecord -Category winget -Name '7zip.7zip' -Version '26.02' -Sha256 'DEADBEEF' -StateDir $sd | Out-Null
        Add-OSyncStateRecord -Category npm -Name 'is-odd' -Version '3.0.1' -Sha256 'CAFE' -StateDir $sd | Out-Null

        $st = Get-OSyncState -Category winget -StateDir $sd
        $st.winget['7zip.7zip'].version | Should -Be '26.02'
        $st.winget['7zip.7zip'].sha256 | Should -Be 'DEADBEEF'
        $st.npm['is-odd'].version | Should -Be '3.0.1'
        # dotfiles records never land in the system store's tables (the system
        # store must not even have a dotfiles key).
        $st.Keys -notcontains 'dotfiles' | Should -BeTrue
        # adding records must not stamp lastApplied.
        $st.lastApplied.winget | Should -BeNullOrEmpty
    }

    It 'writes dotfiles records to the USER store only' {
        $sd = Join-Path $TestDrive 'ar2'
        Add-OSyncStateRecord -Category dotfiles -Name 'bashrc' -Version '' -Sha256 '1111' -StateDir $sd | Out-Null

        $usr = Get-OSyncState -Category dotfiles -StateDir $sd
        $usr.dotfiles['bashrc'].sha256 | Should -Be '1111'

        # The system store must be untouched by a dotfiles write.
        $sys = Get-OSyncState -Category winget -StateDir $sd
        @($sys.winget.Keys).Count | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $sd 'state\system-state.json')) | Should -BeFalse
    }
}

Describe 'corruption handling' {
    It 'quarantines a corrupt SYSTEM store, rebuilds an empty state and warns' {
        $sd = Join-Path $TestDrive 'cor1'
        $sysDir = Join-Path $sd 'state'
        New-Item -ItemType Directory -Path $sysDir -Force | Out-Null
        $sysFile = Join-Path $sysDir 'system-state.json'
        [System.IO.File]::WriteAllText($sysFile, '{ this is not json', (New-Object System.Text.UTF8Encoding($false)))

        $w = @()
        $st = Get-OSyncState -Category winget -StateDir $sd -WarningVariable w -WarningAction SilentlyContinue

        $st.schemaVersion | Should -Be 1
        $st.lastApplied.winget | Should -BeNullOrEmpty
        @($st.winget.Keys).Count | Should -Be 0
        (Test-Path -LiteralPath "$sysFile.bak") | Should -BeTrue
        (Test-Path -LiteralPath $sysFile) | Should -BeFalse
        @($w).Count | Should -Be 1
        ($w -join '') | Should -Match '\.bak'
    }

    It 'quarantines a corrupt USER store the same way' {
        $sd = Join-Path $TestDrive 'cor2'
        $runDir = Join-Path $sd 'run'
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $usrFile = Join-Path $runDir 'user-state.json'
        [System.IO.File]::WriteAllText($usrFile, 'garbage', (New-Object System.Text.UTF8Encoding($false)))

        $w = @()
        $st = Get-OSyncState -Category dotfiles -StateDir $sd -WarningVariable w -WarningAction SilentlyContinue

        $st.schemaVersion | Should -Be 1
        $st.lastApplied.dotfiles | Should -BeNullOrEmpty
        @($st.dotfiles.Keys).Count | Should -Be 0
        (Test-Path -LiteralPath "$usrFile.bak") | Should -BeTrue
        (Test-Path -LiteralPath $usrFile) | Should -BeFalse
        @($w).Count | Should -Be 1
    }

    It 'treats valid-JSON but wrong-schema stores as corrupt (both stores)' {
        $sd = Join-Path $TestDrive 'cor3'
        $sysDir = Join-Path $sd 'state'
        $runDir = Join-Path $sd 'run'
        New-Item -ItemType Directory -Path $sysDir -Force | Out-Null
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $sysDir 'system-state.json'), '{"schemaVersion":99}', (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $runDir 'user-state.json'), '{"schemaVersion":1,"lastApplied":"nope"}', (New-Object System.Text.UTF8Encoding($false)))

        $st = Get-OSyncState -Category winget -StateDir $sd -WarningAction SilentlyContinue
        $st.schemaVersion | Should -Be 1
        (Test-Path -LiteralPath (Join-Path $sysDir 'system-state.json.bak')) | Should -BeTrue

        $us = Get-OSyncState -Category dotfiles -StateDir $sd -WarningAction SilentlyContinue
        $us.schemaVersion | Should -Be 1
        (Test-Path -LiteralPath (Join-Path $runDir 'user-state.json.bak')) | Should -BeTrue
    }

    It 'recovers cleanly: after quarantine a Save writes a fresh valid store' {
        $sd = Join-Path $TestDrive 'cor4'
        $sysDir = Join-Path $sd 'state'
        New-Item -ItemType Directory -Path $sysDir -Force | Out-Null
        $sysFile = Join-Path $sysDir 'system-state.json'
        [System.IO.File]::WriteAllText($sysFile, '###', (New-Object System.Text.UTF8Encoding($false)))

        $st = Get-OSyncState -Category winget -StateDir $sd -WarningAction SilentlyContinue
        $st.winget['A.B'] = [ordered]@{ version = '1.0'; sha256 = 'X' }
        Save-OSyncState -Category winget -State $st -StateDir $sd | Out-Null

        $rt = Get-OSyncState -Category winget -StateDir $sd
        $rt.winget['A.B'].version | Should -Be '1.0'
    }
}

Describe 'config parameter set' {
    It 'uses config.stateDir when -Config is passed instead of -StateDir' {
        $sd = Join-Path $TestDrive 'cfg1'
        $cfg = [pscustomobject]@{ stateDir = $sd }

        $null = Set-OSyncLastApplied -Category winget -ExportedAtUtc '20260901T000000Z' -Config $cfg
        $rt = Get-OSyncState -Category winget -Config $cfg
        $rt.lastApplied.winget | Should -Be '20260901T000000Z'
        (Test-Path -LiteralPath (Join-Path $sd 'state\system-state.json')) | Should -BeTrue

        Test-OSyncCategoryNewer -Category winget -ExportedAtUtc '20260902T000000Z' -Config $cfg | Should -BeTrue
    }
}
