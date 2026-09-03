#Requires -Version 5.1
# Config.Tests.ps1 - Pester 5 tests for src\lib\Config.ps1 (Get-OSyncConfig).

Describe 'OfflineSync config loading (Get-OSyncConfig)' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $modulePath = Join-Path $repoRoot 'src\OfflineSync.psd1'
        Import-Module $modulePath -Force

        $configPath = Join-Path $repoRoot 'config\packagesync.json'
        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-config-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

        # Writes a mutated copy of the default config into $testRoot.
        function New-TestConfig {
            param([string]$OutFile, [scriptblock]$Mutate)
            $obj = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if ($null -ne $Mutate) { & $Mutate $obj }
            $obj | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutFile -Encoding UTF8
            return $OutFile
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'happy path' {
        It 'loads the default A-role config and returns the full schema' {
            $config = Get-OSyncConfig -Path $configPath
            $config | Should -Not -BeNullOrEmpty
            $config.schemaVersion | Should -Be 1
            $config.role | Should -Be 'A'
            $config.repoRoot | Should -Be 'D:\OfflineRepo'
            $config.stagingRoot | Should -Be 'D:\PakageSync-staging'
            $config.httpBind | Should -Be '127.0.0.1'
            $config.httpPort | Should -Be 8788
            $config.verdaccioPort | Should -Be 4873
            $config.npm.aVerdaccioPort | Should -Be 4874
            $config.categories.winget | Should -BeTrue
            $config.categories.pip | Should -BeTrue
            $config.categories.npm | Should -BeTrue
            $config.categories.dotfiles | Should -BeTrue
            $config.winget.scope | Should -Be 'machine'
            $config.winget.architecture | Should -Be 'x64'
            $config.pip.downloadArgs.Count | Should -BeGreaterThan 0
            $config.pip.upgradeOnApply | Should -BeTrue
            $config.pip.allowSdist | Should -BeFalse
            $config.pins.chezmoi.version | Should -Be '2.72.0'
        }

        It 'loads the B-role template config' {
            $config = Get-OSyncConfig -Path (Join-Path $repoRoot 'config\packagesync.b.json')
            $config.role | Should -Be 'B'
            $config.repoRoot | Should -Be 'C:\OfflineRepo'
            $config.stateDir | Should -Be 'C:\ProgramData\PakageSync'
        }
    }

    Context 'failure paths' {
        It 'throws when the httpPort key is missing and the message names the key' {
            $bad = Join-Path $testRoot 'no-httpport.json'
            New-TestConfig -OutFile $bad -Mutate { param($o) $o.PSObject.Properties.Remove('httpPort') }
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*httpPort*'
        }

        It 'throws when a nested key is missing and the message names the key' {
            $bad = Join-Path $testRoot 'no-msixbundle.json'
            New-TestConfig -OutFile $bad -Mutate { param($o) $o.pins.appInstaller.PSObject.Properties.Remove('msixbundleUrl') }
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*msixbundleUrl*'
        }

        It 'throws when the role is invalid and the message names the key' {
            $bad = Join-Path $testRoot 'bad-role.json'
            New-TestConfig -OutFile $bad -Mutate { param($o) $o.role = 'C' }
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*role*'
        }

        It 'throws when a port is out of range and the message names the key' {
            $bad = Join-Path $testRoot 'bad-port.json'
            New-TestConfig -OutFile $bad -Mutate { param($o) $o.httpPort = 99999 }
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*httpPort*'
        }

        It 'throws when pip is enabled but winget is not, naming categories.winget' {
            $bad = Join-Path $testRoot 'cross-field.json'
            New-TestConfig -OutFile $bad -Mutate { param($o) $o.categories.winget = $false }
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*categories.winget*'
        }

        It 'throws when a category value is not a boolean and the message names the key' {
            $bad = Join-Path $testRoot 'bad-category.json'
            New-TestConfig -OutFile $bad -Mutate { param($o) $o.categories.npm = 'yes' }
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*categories.npm*'
        }

        It 'throws when the file does not exist' {
            $bad = Join-Path $testRoot 'does-not-exist.json'
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*does-not-exist*'
        }

        It 'throws when the file is not valid JSON' {
            $bad = Join-Path $testRoot 'broken.json'
            Set-Content -LiteralPath $bad -Value '{ this is not json' -Encoding ASCII
            $err = $null
            try { Get-OSyncConfig -Path $bad } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*valid JSON*'
        }
    }
}
