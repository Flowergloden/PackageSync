#Requires -Version 5.1
Describe 'ManifestRefresh' {
    BeforeAll {
        foreach ($file in @('Util', 'Config', 'Logging', 'ManifestParse', 'ManifestGenerate', 'ManifestRefresh')) {
            . (Join-Path $PSScriptRoot "..\src\lib\$file.ps1")
        }
    }
    BeforeEach {
        $script:path = Join-Path $TestDrive 'packages.txt'
        Mock Write-OSyncLog { }
        Mock Get-OSyncInstalledWinget { @([pscustomobject]@{ Id = 'Vendor.App'; Version = '2.0' }) }
        Mock Get-OSyncInstalledPip { @([pscustomobject]@{ Name = 'demo'; Version = '2.0' }) }
        Mock Get-OSyncInstalledNpm { @([pscustomobject]@{ Name = '@scope/demo'; Version = '2.0' }) }
        Mock Get-OSyncInstalledBun { @([pscustomobject]@{ Name = 'bun-only'; Version = '3.0' }) }
        Mock Read-Host { throw 'Refresh must never prompt' }
    }

    It 'updates only existing winget entries, preserving layout and making a byte-identical backup' {
        $original = "# header`n  Vendor.App@1.0  # keep`n`nVendor.Missing@7`nVendor.Unknown@8"
        [IO.File]::WriteAllText($path, $original, (New-Object Text.UTF8Encoding($false)))
        $installed = @(
            [pscustomobject]@{ Id = 'vendor.app'; Version = '2.0' },
            [pscustomobject]@{ Id = 'Vendor.New'; Version = '9' },
            [pscustomobject]@{ Id = 'Vendor.Unknown'; Version = 'Unknown' }
        )
        $result = Update-OSyncManifestVersions -Path $path -Category winget -Installed $installed
        $result.Updated | Should -Be 1
        [IO.File]::ReadAllText($path) | Should -Be ($original.Replace('Vendor.App@1.0', 'Vendor.App@2.0'))
        [IO.File]::ReadAllText($result.BackupPath) | Should -Be $original
        [IO.File]::ReadAllBytes($path)[0] | Should -Be 35
        $again = Update-OSyncManifestVersions -Path $path -Category winget -Installed $installed
        $again.Changed | Should -BeFalse
        $again.BackupPath | Should -BeNullOrEmpty
        @(Get-ChildItem $TestDrive -Filter '*.bak-*').Count | Should -Be 1
    }

    It 'pins unpinned and scoped npm/bun entries without adding new packages' -ForEach @('npm', 'bun') {
        [IO.File]::WriteAllText($path, "@scope/demo@1.0`r`nplain`r`nmissing@4`r`n", (New-Object Text.UTF8Encoding($true)))
        $installed = @([pscustomobject]@{ Name = '@scope/demo'; Version = '2.0' }, [pscustomobject]@{ Name = 'plain'; Version = '3' })
        $result = Update-OSyncManifestVersions -Path $path -Category $_ -Installed $installed
        $result.Updated | Should -Be 2
        [IO.File]::ReadAllText($path) | Should -Be "@scope/demo@2.0`r`nplain@3`r`nmissing@4`r`n"
        [IO.File]::ReadAllBytes($path)[0] | Should -Be 239
    }

    It 'normalizes pip names and retains extras, markers, ranges and direct references' {
        $original = "My_Pkg[extra]==1.0 ; python_version >= '3.10' # note`ndemo`nrange>=1`nrange==1.*`nlocal @ file:///C:/local`n"
        [IO.File]::WriteAllText($path, $original)
        $installed = @([pscustomobject]@{ Name = 'my-pkg'; Version = '2.0' }, [pscustomobject]@{ Name = 'demo'; Version = '4.0' }, [pscustomobject]@{ Name = 'range'; Version = '3' })
        $result = Update-OSyncManifestVersions -Path $path -Category pip -Installed $installed
        $result.Updated | Should -Be 2
        [IO.File]::ReadAllText($path) | Should -Be ($original.Replace('==1.0', '==2.0').Replace("`ndemo`n", "`ndemo==4.0`n"))
    }

    It 'does not change hash-locked requirements' {
        $original = 'demo==1.0 --hash=sha256:abc'
        [IO.File]::WriteAllText($path, $original)
        $result = Update-OSyncManifestVersions -Path $path -Category pip -Installed @([pscustomobject]@{ Name = 'demo'; Version = '2.0' })
        $result.Changed | Should -BeFalse
        [IO.File]::ReadAllText($path) | Should -Be $original
    }

    It 'preserves old pins for missing, empty, or conflicting installed versions' {
        [IO.File]::WriteAllText($path, "Vendor.App@1`nVendor.Empty@5")
        $installed = @([pscustomobject]@{ Id = 'Vendor.App'; Version = '2' }, [pscustomobject]@{ Id = 'Vendor.App'; Version = '3' }, [pscustomobject]@{ Id = 'Vendor.Empty'; Version = $null })
        (Update-OSyncManifestVersions -Path $path -Category winget -Installed $installed).Changed | Should -BeFalse
        (Update-OSyncManifestVersions -Path $path -Category winget -Installed @()).Changed | Should -BeFalse
    }

    It 'rejects invalid lists before rewriting' {
        [IO.File]::WriteAllText($path, 'invalid id')
        { Update-OSyncManifestVersions -Path $path -Category winget -Installed @() } | Should -Throw
        [IO.File]::ReadAllText($path) | Should -Be 'invalid id'
    }

    It 'refreshes npm and enabled bun using their own installed inventories without prompts' {
        $bunPath = Join-Path $TestDrive 'bun.txt'
        [IO.File]::WriteAllText($path, '@scope/demo@1.0')
        [IO.File]::WriteAllText($bunPath, 'bun-only@1.0')
        $config = [pscustomobject]@{ toolRoot = "$TestDrive"; paths = @{ npmList = $path; bunList = $bunPath }; pins = @{ bun = @{ version = '1' } } }
        $config = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Invoke-OSyncManifestRefresh -Config $config -Category npm
        [IO.File]::ReadAllText($path) | Should -Be '@scope/demo@2.0'
        [IO.File]::ReadAllText($bunPath) | Should -Be 'bun-only@3.0'
        Should -Invoke Get-OSyncInstalledNpm -Times 1 -Exactly
        Should -Invoke Get-OSyncInstalledBun -Times 1 -Exactly
        Should -Invoke Read-Host -Times 0 -Exactly
    }

    It 'does not collect bun when its list is absent, empty or disabled' -ForEach @('absent', 'empty', 'disabled') {
        $bunPath = Join-Path $TestDrive 'optional-bun.txt'
        [IO.File]::WriteAllText($path, '@scope/demo@1.0')
        $config = [pscustomobject]@{ toolRoot = "$TestDrive"; paths = @{ npmList = $path; bunList = $bunPath }; pins = @{ bun = @{ version = '1' } } }
        if ($_ -eq 'empty') { [IO.File]::WriteAllText($bunPath, '# empty') }
        if ($_ -eq 'disabled') { $config.pins = @{} }
        $config = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Invoke-OSyncManifestRefresh -Config $config -Category npm
        Should -Invoke Get-OSyncInstalledBun -Times 0 -Exactly
    }

    It 'refreshes runtime whitelist from installed winget versions' {
        [IO.File]::WriteAllText($path, 'Vendor.App@1.0')
        $config = [pscustomobject]@{ toolRoot = "$TestDrive"; paths = @{ runtimeWhitelist = $path } }
        $config = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Invoke-OSyncManifestRefresh -Config $config -Category runtime
        [IO.File]::ReadAllText($path) | Should -Be 'Vendor.App@2.0'
    }

    It 'propagates collection failures without rewriting the existing manifest' {
        [IO.File]::WriteAllText($path, 'demo==1.0')
        $config = [pscustomobject]@{ toolRoot = "$TestDrive"; paths = @{ requirements = $path } }
        $config = $config | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        Mock Get-OSyncInstalledPip { throw 'collector unavailable' }
        { Invoke-OSyncManifestRefresh -Config $config -Category pip } | Should -Throw '*collector unavailable*'
        [IO.File]::ReadAllText($path) | Should -Be 'demo==1.0'
    }
}
