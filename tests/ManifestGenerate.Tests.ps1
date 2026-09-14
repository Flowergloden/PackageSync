#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\ManifestGenerate.ps1 - the A-side
    interactive manifest generator (Invoke-OSyncManifestGenerate, the core
    of src\Export-Manifests.ps1).

.DESCRIPTION
    All external tools (winget / python / npm / bun) are FAKE .cmd stubs - no
    real package manager is ever invoked. Read-Host is mocked for the
    picker. All manifest files live under $TestDrive - the real
    manifests\ directory is never touched.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\ManifestGenerate.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files
    are dot-sourced and helper functions are defined INSIDE BeforeAll;
    data shared with the It blocks uses $script: scope (same pattern as
    the other test files in this plan).
#>

Describe 'ManifestGenerate' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestGenerate.ps1')

        # --- config helper: writes a full valid packagesync config JSON ---
        # The config lives at <ToolRoot>\config\packagesync.json so
        # Get-OSyncConfig derives toolRoot = <ToolRoot> (the parent of the
        # config file's parent) - the same layout as the real repo. repoRoot
        # is the separate OUTPUT landing dir (never the manifest location).
        function New-OTestConfigFile {
            param(
                [string]$ToolRoot,
                [string]$RepoRoot,
                # Opt-in: adds paths.bunList so the bun category is enabled
                # (bun is presence-gated on this key - the default test
                # config deliberately omits it so the skip path is testable).
                [switch]$IncludeBun
            )
            $paths = [ordered]@{
                wingetWhitelist  = 'manifests\winget-packages.txt'
                runtimeWhitelist = 'manifests\runtime-winget.txt'
                requirements     = 'manifests\requirements.txt'
                npmList          = 'manifests\npm-packages.txt'
                dotfilesSource   = 'manifests\dotfiles'
            }
            if ($IncludeBun) { $paths['bunList'] = 'manifests\bun-packages.txt' }
            $config = [ordered]@{
                schemaVersion = 1
                role          = 'A'
                repoRoot      = $RepoRoot
                stagingRoot   = (Join-Path $RepoRoot 'staging')
                httpBind      = '127.0.0.1'
                httpPort      = 8788
                verdaccioPort = 4873
                npm           = [ordered]@{ aVerdaccioPort = 4874 }
                categories    = [ordered]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true }
                paths         = $paths
                winget = [ordered]@{ scope = 'machine'; architecture = 'x64' }
                pip    = [ordered]@{
                    downloadArgs   = @('--only-binary=:all:')
                    upgradeOnApply = $true
                    allowSdist     = $false
                }
                stateDir = (Join-Path $RepoRoot 'state')
                pins = [ordered]@{
                    chezmoi = [ordered]@{
                        version = '2.72.0'
                        url     = 'https://example.invalid/chezmoi.zip'
                        sha256  = ('a' * 64)
                    }
                    appInstaller = [ordered]@{
                        vcRedistUrl    = 'https://example.invalid/vcredist'
                        vcRedistSha256 = ('e' * 64)
                    }
                    npm = [ordered]@{ verdaccioVersion = '6.10.2' }
                }
            }
            $configDir = Join-Path $ToolRoot 'config'
            New-Item -ItemType Directory -Path $configDir -Force | Out-Null
            $path = Join-Path $configDir 'packagesync.json'
            [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $config -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }

        # --- fake tool stubs (all under $TestDrive, never the real tools) ---
        # Fake winget: contract with Get-OSyncInstalledWinget - the argument
        # after '-o' is the export JSON path. The stub records that path into
        # <MarkerPath> (so tests can assert the temp file is cleaned up) and
        # writes <FixturePath> into it.
        function New-OFakeWinget {
            param(
                [string]$FixturePath,
                [string]$MarkerPath,
                [int]$ExitCode = 0
            )
            $content = @(
                '@echo off',
                'setlocal',
                'set OUT=',
                ':loop',
                'if "%~1"=="" goto run',
                'if /i "%~1"=="-o" (',
                '  set OUT=%~2',
                '  goto run',
                ')',
                'shift',
                'goto loop',
                ':run',
                'if "%OUT%"=="" exit /b 1',
                "echo(%OUT%>> `"$MarkerPath`"",
                "type `"$FixturePath`" > `"%OUT%`"",
                "exit /b $ExitCode"
            ) -join "`r`n"
            $path = Join-Path $TestDrive ("fakewinget-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)
            return $path
        }

        # Fake python / npm: prints <FixturePath> to stdout and exits with
        # <ExitCode> (npm ls may exit non-zero while still printing JSON).
        function New-OFakeTool {
            param(
                [string]$FixturePath,
                [int]$ExitCode = 0
            )
            $content = @(
                '@echo off',
                "type `"$FixturePath`"",
                "exit /b $ExitCode"
            ) -join "`r`n"
            $path = Join-Path $TestDrive ("faketool-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)
            return $path
        }
    }

    Describe 'ConvertFrom-OSyncSelectionText' {
        It 'parses all / none / single / list / range / mixed inputs' {
            @(ConvertFrom-OSyncSelectionText -Text 'all' -Count 5) | Should -Be @(1, 2, 3, 4, 5)
            $none = ConvertFrom-OSyncSelectionText -Text 'none' -Count 5
            $null -ne $none | Should -BeTrue
            @($none).Count | Should -Be 0
            @(ConvertFrom-OSyncSelectionText -Text '3' -Count 5) | Should -Be @(3)
            @(ConvertFrom-OSyncSelectionText -Text '1,3,5' -Count 5) | Should -Be @(1, 3, 5)
            @(ConvertFrom-OSyncSelectionText -Text '2-4' -Count 5) | Should -Be @(2, 3, 4)
            @(ConvertFrom-OSyncSelectionText -Text '1,3,5-8' -Count 8) | Should -Be @(1, 3, 5, 6, 7, 8)
        }

        It 'is case-insensitive for all/none' {
            @(ConvertFrom-OSyncSelectionText -Text 'ALL' -Count 3) | Should -Be @(1, 2, 3)
            $none = ConvertFrom-OSyncSelectionText -Text 'None' -Count 3
            $null -ne $none | Should -BeTrue
            @($none).Count | Should -Be 0
        }

        It 'returns $null for empty or whitespace input (keep current selection)' {
            ConvertFrom-OSyncSelectionText -Text '' -Count 5 | Should -BeNullOrEmpty
            ConvertFrom-OSyncSelectionText -Text '   ' -Count 5 | Should -BeNullOrEmpty
        }

        It 'returns a REAL empty array (not $null) for none' {
            $r = ConvertFrom-OSyncSelectionText -Text 'none' -Count 5
            $null -ne $r | Should -BeTrue
            @($r).Count | Should -Be 0
        }

        It 'sorts and de-duplicates the result' {
            @(ConvertFrom-OSyncSelectionText -Text '3,1,3,2' -Count 5) | Should -Be @(1, 2, 3)
        }

        It 'throws on invalid tokens' {
            { ConvertFrom-OSyncSelectionText -Text 'abc' -Count 5 } | Should -Throw -ExpectedMessage '*invalid selection token*'
            { ConvertFrom-OSyncSelectionText -Text '1,,2' -Count 5 } | Should -Throw -ExpectedMessage '*empty selection token*'
        }

        It 'throws on out-of-range indexes and ranges' {
            { ConvertFrom-OSyncSelectionText -Text '0' -Count 5 } | Should -Throw -ExpectedMessage '*out of range*'
            { ConvertFrom-OSyncSelectionText -Text '6' -Count 5 } | Should -Throw -ExpectedMessage '*out of range*'
            { ConvertFrom-OSyncSelectionText -Text '1-6' -Count 5 } | Should -Throw -ExpectedMessage '*out of range*'
        }

        It 'throws on inverted ranges' {
            { ConvertFrom-OSyncSelectionText -Text '7-3' -Count 10 } | Should -Throw -ExpectedMessage '*inverted range*'
        }

        It 'handles the Count = 0 boundary' {
            $r = ConvertFrom-OSyncSelectionText -Text 'all' -Count 0
            $null -ne $r | Should -BeTrue
            @($r).Count | Should -Be 0
            $none = ConvertFrom-OSyncSelectionText -Text 'none' -Count 0
            $null -ne $none | Should -BeTrue
            @($none).Count | Should -Be 0
            { ConvertFrom-OSyncSelectionText -Text '1' -Count 0 } | Should -Throw -ExpectedMessage '*out of range*'
        }
    }

    Describe 'Get-OSyncInstalledWinget' {
        BeforeAll {
            $script:WingetFixture = Join-Path $TestDrive 'winget-export.json'
            [System.IO.File]::WriteAllText($script:WingetFixture, '{"Sources":[{"Name":"winget","Packages":[{"PackageIdentifier":"7zip.7zip","Version":"26.02"},{"PackageIdentifier":"Microsoft.PowerToys"}]}]}', (New-Object System.Text.UTF8Encoding($false)))
            $script:WingetMarker = Join-Path $TestDrive 'winget-out.txt'
            $script:FakeWinget = New-OFakeWinget -FixturePath $script:WingetFixture -MarkerPath $script:WingetMarker
        }

        It 'parses Sources[].Packages into Id/Version objects (fixture JSON written to the -o path)' {
            $result = @(Get-OSyncInstalledWinget -WingetExePath $script:FakeWinget)
            $result.Count | Should -Be 2
            $result[0].Id | Should -Be '7zip.7zip'
            $result[0].Version | Should -Be '26.02'
            $result[1].Id | Should -Be 'Microsoft.PowerToys'
            $result[1].Version | Should -BeNullOrEmpty
        }

        It 'throws when winget.exe cannot be resolved' {
            Mock Resolve-OSyncWingetExePath { return $null }
            { Get-OSyncInstalledWinget } | Should -Throw -ExpectedMessage '*winget*'
        }

        It 'throws when winget export exits non-zero' {
            $bad = New-OFakeWinget -FixturePath $script:WingetFixture -MarkerPath (Join-Path $TestDrive 'm2.txt') -ExitCode 2
            { Get-OSyncInstalledWinget -WingetExePath $bad } | Should -Throw -ExpectedMessage '*exit code 2*'
        }

        It 'throws when the export JSON cannot be parsed' {
            $garbage = Join-Path $TestDrive 'garbage.json'
            [System.IO.File]::WriteAllText($garbage, 'not json at all', [System.Text.Encoding]::ASCII)
            $bad = New-OFakeWinget -FixturePath $garbage -MarkerPath (Join-Path $TestDrive 'm3.txt')
            { Get-OSyncInstalledWinget -WingetExePath $bad } | Should -Throw -ExpectedMessage '*parse*'
        }

        It 'removes the temporary export file in finally' {
            $null = Get-OSyncInstalledWinget -WingetExePath $script:FakeWinget
            $recorded = (Get-Content -LiteralPath $script:WingetMarker).Trim()
            Test-Path -LiteralPath $recorded | Should -BeFalse
        }
    }

    Describe 'Get-OSyncInstalledPip' {
        BeforeAll {
            $script:PipFixture = Join-Path $TestDrive 'freeze.txt'
            [System.IO.File]::WriteAllText($script:PipFixture, "six==1.17.0`r`nrequests==2.32.3`r`n-e git+https://example.invalid/x`r`npkg @ file:///C:/x`r`nbare-name`r`n", [System.Text.Encoding]::ASCII)
            $script:FakePython = New-OFakeTool -FixturePath $script:PipFixture
        }

        It 'parses name==version lines into Name/Version objects' {
            $result = @(Get-OSyncInstalledPip -PythonPath $script:FakePython)
            $result.Count | Should -Be 2
            $result[0].Name | Should -Be 'six'
            $result[0].Version | Should -Be '1.17.0'
            $result[1].Name | Should -Be 'requests'
            $result[1].Version | Should -Be '2.32.3'
        }

        It 'skips non-pinned lines with a warning (never throws)' {
            $script:Warnings = @()
            Mock Write-Warning { $script:Warnings += $Message }
            $result = @(Get-OSyncInstalledPip -PythonPath $script:FakePython)
            $script:Warnings.Count | Should -Be 3
            $result.Count | Should -Be 2
        }

        It 'throws when pip freeze exits non-zero' {
            $bad = New-OFakeTool -FixturePath $script:PipFixture -ExitCode 1
            { Get-OSyncInstalledPip -PythonPath $bad } | Should -Throw -ExpectedMessage '*exit code 1*'
        }
    }

    Describe 'Get-OSyncInstalledNpm' {
        BeforeAll {
            $script:NpmFixture = Join-Path $TestDrive 'npm-ls.json'
            [System.IO.File]::WriteAllText($script:NpmFixture, '{"dependencies":{"is-odd":{"version":"3.0.1"},"@babel/core":{"version":"7.26.0"}}}', [System.Text.Encoding]::ASCII)
            $script:FakeNpm = New-OFakeTool -FixturePath $script:NpmFixture -ExitCode 1
        }

        It 'parses the dependencies JSON even when npm exits non-zero (stdout parseable wins)' {
            $result = @(Get-OSyncInstalledNpm -NpmExe $script:FakeNpm)
            $result.Count | Should -Be 2
            $result[0].Name | Should -Be 'is-odd'
            $result[0].Version | Should -Be '3.0.1'
            $result[1].Name | Should -Be '@babel/core'
            $result[1].Version | Should -Be '7.26.0'
        }

        It 'throws when the stdout is not valid JSON' {
            $garbage = Join-Path $TestDrive 'npm-garbage.json'
            [System.IO.File]::WriteAllText($garbage, 'npm ERR! something', [System.Text.Encoding]::ASCII)
            $bad = New-OFakeTool -FixturePath $garbage
            { Get-OSyncInstalledNpm -NpmExe $bad } | Should -Throw -ExpectedMessage '*JSON*'
        }
    }

    Describe 'Get-OSyncInstalledBun' {
        BeforeAll {
            # Real bun 1.4.0 output shape: a header line with the global
            # node_modules path + count, then tree-prefixed entries.
            $script:BunFixture = Join-Path $TestDrive 'bun-pm-ls.txt'
            [System.IO.File]::WriteAllText($script:BunFixture, "C:\Users\X\.bun\install\global node_modules (3)`r`n├── is-odd@3.0.1`r`n├── @babel/core@7.26.0`r`n└── unpinned-pkg`r`n", (New-Object System.Text.UTF8Encoding($false)))
            $script:FakeBun = New-OFakeTool -FixturePath $script:BunFixture
        }

        It 'parses the tree output: header line skipped, name/version split at the last @' {
            $result = @(Get-OSyncInstalledBun -BunExe $script:FakeBun)
            $result.Count | Should -Be 3
            $result[0].Name | Should -Be 'is-odd'
            $result[0].Version | Should -Be '3.0.1'
            $result[1].Name | Should -Be '@babel/core'
            $result[1].Version | Should -Be '7.26.0'
            $result[2].Name | Should -Be 'unpinned-pkg'
            $result[2].Version | Should -BeNullOrEmpty
        }

        It 'parses entries even when the tree prefix is OEM-misdecoded (cp936 CJK garbage)' {
            # bun always writes the tree prefix as UTF-8; under Windows
            # PowerShell 5.1 with the console OEM codepage (cp936 on zh-CN)
            # it decodes to CJK garbage, so the parser must not depend on
            # the literal box-drawing characters. The char codes below are
            # the ACTUAL misdecoding observed for '└── ' under cp936.
            $prefix = [string]([char]0x9239) + [char]0x65BA + [char]0x6522 + [char]0x9239 + [char]0x20AC + ' '
            $mojibake = Join-Path $TestDrive 'bun-pm-ls-mojibake.txt'
            [System.IO.File]::WriteAllText($mojibake, ($prefix + 'oh-my-openagent@4.19.4' + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
            $fake = New-OFakeTool -FixturePath $mojibake
            $result = @(Get-OSyncInstalledBun -BunExe $fake)
            $result.Count | Should -Be 1
            $result[0].Name | Should -Be 'oh-my-openagent'
            $result[0].Version | Should -Be '4.19.4'
        }

        It 'throws when bun pm ls -g exits non-zero' {
            $bad = New-OFakeTool -FixturePath $script:BunFixture -ExitCode 1
            { Get-OSyncInstalledBun -BunExe $bad } | Should -Throw -ExpectedMessage '*exit code 1*'
        }

        It 'throws (never fails silently) when bun pm ls -g produces no output' {
            $empty = Join-Path $TestDrive 'bun-empty.txt'
            [System.IO.File]::WriteAllText($empty, '', [System.Text.Encoding]::ASCII)
            $bad = New-OFakeTool -FixturePath $empty
            { Get-OSyncInstalledBun -BunExe $bad } | Should -Throw -ExpectedMessage '*no output*'
        }

        It 'parses entries emitted on stderr (2>&1 merge)' {
            $errCmd = Join-Path $TestDrive ("fakebun-err-{0}.cmd" -f [guid]::NewGuid().ToString('N'))
            $content = @(
                '@echo off',
                "type `"$script:BunFixture`" 1>&2",
                'exit /b 0'
            ) -join "`r`n"
            [System.IO.File]::WriteAllText($errCmd, $content, [System.Text.Encoding]::ASCII)
            $result = @(Get-OSyncInstalledBun -BunExe $errCmd)
            $result.Count | Should -Be 3
            $result[0].Name | Should -Be 'is-odd'
            $result[2].Name | Should -Be 'unpinned-pkg'
        }
    }

    Describe 'Show-OSyncEntryPicker' {
        BeforeAll {
            $script:PickerEntries = @(
                [pscustomobject]@{ Key = 'a'; Display = 'A@1.0'; Preselected = $true; PinnedText = 'A@1.0' },
                [pscustomobject]@{ Key = 'b'; Display = 'B@2.0'; Preselected = $false; PinnedText = 'B@2.0' }
            )
        }

        It 'Enter keeps the preselection' {
            Mock Read-Host { return '' }
            $result = @(Show-OSyncEntryPicker -Category 'winget' -Entries $script:PickerEntries)
            $result.Count | Should -Be 2
            $result[0].Selected | Should -BeTrue
            $result[1].Selected | Should -BeFalse
            $result[0].Key | Should -Be 'a'
            $result[0].PinnedText | Should -Be 'A@1.0'
        }

        It 'explicit numbers override the preselection' {
            Mock Read-Host { return '2' }
            $result = @(Show-OSyncEntryPicker -Category 'winget' -Entries $script:PickerEntries)
            $result[0].Selected | Should -BeFalse
            $result[1].Selected | Should -BeTrue
        }

        It 'invalid input is warned about and re-asked until it parses' {
            $script:ReadCount = 0
            Mock Read-Host {
                $script:ReadCount++
                if ($script:ReadCount -eq 1) { return 'bogus' }
                return '2'
            }
            $result = @(Show-OSyncEntryPicker -Category 'winget' -Entries $script:PickerEntries)
            $script:ReadCount | Should -Be 2
            $result[1].Selected | Should -BeTrue
        }
    }

    Describe 'Invoke-OSyncManifestGenerate: candidate merge' {
        BeforeAll {
            $script:ToolRoot = Join-Path $TestDrive 'tool-merge'
            $script:RepoRoot = Join-Path $TestDrive 'repo-merge'
            New-Item -ItemType Directory -Path (Join-Path $script:ToolRoot 'manifests') -Force | Out-Null
            $script:ManifestsDir = Join-Path $script:ToolRoot 'manifests'

            # Runs the generator with mocked collectors and a mocked picker
            # that captures the candidate list (so the merge logic is
            # directly observable) and selects everything.
            function Invoke-OTestMerge {
                param(
                    [string[]]$Category,
                    [hashtable]$InstalledByCategory,
                    [switch]$IncludeBun
                )
                $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot -IncludeBun:$IncludeBun
                $config = Get-OSyncConfig -Path $configPath
                $script:PickerEntries = $null
                Mock Show-OSyncEntryPicker {
                    param($Category, $Entries)
                    $script:PickerEntries = @($Entries)
                    return @($Entries | ForEach-Object {
                        [pscustomobject]@{
                            Key         = $_.Key
                            Display     = $_.Display
                            Preselected = $_.Preselected
                            PinnedText  = $_.PinnedText
                            Selected    = $true
                        }
                    })
                }
                Mock Get-OSyncInstalledWinget { $l = $InstalledByCategory['winget']; if ($null -eq $l) { return @() }; return @($l) }
                Mock Get-OSyncInstalledPip { $l = $InstalledByCategory['pip']; if ($null -eq $l) { return @() }; return @($l) }
                Mock Get-OSyncInstalledNpm { $l = $InstalledByCategory['npm']; if ($null -eq $l) { return @() }; return @($l) }
                Mock Get-OSyncInstalledBun { $l = $InstalledByCategory['bun']; if ($null -eq $l) { return @() }; return @($l) }
                $null = Invoke-OSyncManifestGenerate -Config $config -Category $Category
                return $script:PickerEntries
            }
        }

        It 'preselects installed entries already in the manifest; installed-only entries are not preselected' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('7zip.7zip@24.08') -Encoding UTF8
            $entries = @(Invoke-OTestMerge -Category @('winget') -InstalledByCategory @{
                winget = @(
                    [pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' },
                    [pscustomobject]@{ Id = 'Microsoft.PowerToys'; Version = '1.0.0' }
                )
            })
            $entries.Count | Should -Be 2
            $entries[0].Key | Should -Be '7zip.7zip'
            $entries[0].Preselected | Should -BeTrue
            $entries[0].PinnedText | Should -Be '7zip.7zip@26.02'
            $entries[1].Key | Should -Be 'microsoft.powertoys'
            $entries[1].Preselected | Should -BeFalse
            $entries[1].PinnedText | Should -Be 'Microsoft.PowerToys@1.0.0'
        }

        It 'marks existing-only entries with (not installed) and keeps their original text as PinnedText' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('Foo.Bar@1.0.0') -Encoding UTF8
            $entries = @(Invoke-OTestMerge -Category @('winget') -InstalledByCategory @{
                winget = @([pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' })
            })
            $entries.Count | Should -Be 2
            $entries[1].Key | Should -Be 'foo.bar'
            $entries[1].Preselected | Should -BeTrue
            $entries[1].Display | Should -Be 'Foo.Bar@1.0.0 (not installed)'
            $entries[1].PinnedText | Should -Be 'Foo.Bar@1.0.0'
        }

        It 'matches keys case-insensitively (winget)' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('7ZIP.7ZIP@24.08') -Encoding UTF8
            $entries = @(Invoke-OTestMerge -Category @('winget') -InstalledByCategory @{
                winget = @([pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' })
            })
            $entries.Count | Should -Be 1
            $entries[0].Preselected | Should -BeTrue
            $entries[0].PinnedText | Should -Be '7zip.7zip@26.02'
        }

        It 'normalizes pip names per PEP 503 (case + runs of [-_.])' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'requirements.txt') -Value @('My_Pkg.Name==1.0') -Encoding UTF8
            $entries = @(Invoke-OTestMerge -Category @('pip') -InstalledByCategory @{
                pip = @([pscustomobject]@{ Name = 'my-pkg-name'; Version = '2.0' })
            })
            $entries.Count | Should -Be 1
            $entries[0].Key | Should -Be 'my-pkg-name'
            $entries[0].Preselected | Should -BeTrue
            $entries[0].PinnedText | Should -Be 'my-pkg-name==2.0'
        }

        It 'pins npm entries as name@Version' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'npm-packages.txt') -Value @('is-odd@3.0.1') -Encoding UTF8
            $entries = @(Invoke-OTestMerge -Category @('npm') -InstalledByCategory @{
                npm = @([pscustomobject]@{ Name = 'is-odd'; Version = '3.0.2' })
            })
            $entries.Count | Should -Be 1
            $entries[0].Key | Should -Be 'is-odd'
            $entries[0].Preselected | Should -BeTrue
            $entries[0].PinnedText | Should -Be 'is-odd@3.0.2'
        }

        It 'pins bun entries as name@Version (bun list shares the npm list format)' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'bun-packages.txt') -Value @('is-odd@3.0.1') -Encoding UTF8
            $entries = @(Invoke-OTestMerge -Category @('bun') -IncludeBun -InstalledByCategory @{
                bun = @([pscustomobject]@{ Name = 'is-odd'; Version = '3.0.2' })
            })
            $entries.Count | Should -Be 1
            $entries[0].Key | Should -Be 'is-odd'
            $entries[0].Preselected | Should -BeTrue
            $entries[0].PinnedText | Should -Be 'is-odd@3.0.2'
        }
    }

    Describe 'Invoke-OSyncManifestGenerate: writeback' {
        BeforeAll {
            $script:ToolRoot = Join-Path $TestDrive 'tool-write'
            $script:RepoRoot = Join-Path $TestDrive 'repo-write'
            New-Item -ItemType Directory -Path (Join-Path $script:ToolRoot 'manifests') -Force | Out-Null
            $script:ManifestsDir = Join-Path $script:ToolRoot 'manifests'

            # Runs the generator with mocked collectors and the REAL picker
            # driven by a mocked Read-Host (so the write-back flow is
            # exercised end to end). Write-OSyncLog is mocked to capture
            # the messages.
            function Invoke-OTestWrite {
                param(
                    [string[]]$Category,
                    [hashtable]$InstalledByCategory,
                    [string]$InputText,
                    [switch]$IncludeBun
                )
                $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot -IncludeBun:$IncludeBun
                $config = Get-OSyncConfig -Path $configPath
                $script:LogMessages = @()
                # Remove stale backups from earlier tests so .bak assertions
                # only see the current run's artifacts.
                Get-ChildItem -LiteralPath $script:ManifestsDir -Filter '*.bak-*' -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                Mock Write-OSyncLog {
                    param($Category, $Level, $Message, $Data, $Config, $LogDir)
                    $script:LogMessages += $Message
                }
                Mock Read-Host { return $InputText }
                Mock Get-OSyncInstalledWinget { $l = $InstalledByCategory['winget']; if ($null -eq $l) { return @() }; return @($l) }
                Mock Get-OSyncInstalledPip { $l = $InstalledByCategory['pip']; if ($null -eq $l) { return @() }; return @($l) }
                Mock Get-OSyncInstalledNpm { $l = $InstalledByCategory['npm']; if ($null -eq $l) { return @() }; return @($l) }
                Mock Get-OSyncInstalledBun { $l = $InstalledByCategory['bun']; if ($null -eq $l) { return @() }; return @($l) }
                return Invoke-OSyncManifestGenerate -Config $config -Category $Category
            }
        }

        It 'writes pinned entries and preserves human comments at the top' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('# top comment', '7zip.7zip@24.08', '# middle comment', 'Microsoft.PowerToys') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('winget') -InputText 'all' -InstalledByCategory @{
                winget = @(
                    [pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' },
                    [pscustomobject]@{ Id = 'Microsoft.PowerToys'; Version = '1.0.0' }
                )
            }
            $result['winget'].Selected | Should -Be 2
            $result['winget'].Changed | Should -BeTrue
            $lines = @(Get-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Encoding UTF8)
            $lines[0] | Should -Be '# top comment'
            $lines[1] | Should -Be '# middle comment'
            $lines[2] | Should -Be ''
            $lines[3] | Should -Be '7zip.7zip@26.02'
            $lines[4] | Should -Be 'Microsoft.PowerToys@1.0.0'
        }

        It 'preserves the original text of surviving not-installed entries verbatim' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('# c', 'Foo.Bar@1.0.0 # inline note') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('winget') -InputText 'all' -InstalledByCategory @{
                winget = @([pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' })
            }
            $result['winget'].Selected | Should -Be 2
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'winget-packages.txt'), [System.Text.Encoding]::UTF8)
            $text -match 'Foo\.Bar@1\.0\.0 # inline note' | Should -BeTrue
            $text -match '7zip\.7zip@26\.02' | Should -BeTrue
        }

        It 'does not write or back up when the selection is line-for-line identical' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('# comment', '', '7zip.7zip@26.02') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('winget') -InputText '' -InstalledByCategory @{
                winget = @([pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' })
            }
            $result['winget'].Changed | Should -BeFalse
            $result['winget'].BackupPath | Should -BeNullOrEmpty
            @(Get-ChildItem -LiteralPath $script:ManifestsDir -Filter '*.bak-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'winget-packages.txt'), [System.Text.Encoding]::UTF8)
            $text -match '7zip\.7zip@26\.02' | Should -BeTrue
        }

        It 'backs up and rewrites with UTF-8 BOM + CRLF when the content changes' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('7zip.7zip@24.08') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('winget') -InputText '' -InstalledByCategory @{
                winget = @([pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' })
            }
            $result['winget'].Changed | Should -BeTrue
            $result['winget'].BackupPath | Should -Match '\.bak-\d{8}T\d{6}Z$'
            Test-Path -LiteralPath $result['winget'].BackupPath | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:ManifestsDir -Filter '*.bak-*').Count | Should -Be 1
            $path = Join-Path $script:ManifestsDir 'winget-packages.txt'
            $bytes = [System.IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF) | Should -BeTrue
            $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
            $text -match "`r`n" | Should -BeTrue
            $text -match "(?<!`r)`n" | Should -BeFalse
            $text.Trim() | Should -Be '7zip.7zip@26.02'
        }

        It 'skips writeback entirely when nothing is selected (manifest untouched, no backup)' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Value @('7zip.7zip@24.08') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('winget') -InputText 'none' -InstalledByCategory @{
                winget = @([pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' })
            }
            $result['winget'].Selected | Should -Be 0
            $result['winget'].Changed | Should -BeFalse
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'winget-packages.txt'), [System.Text.Encoding]::UTF8)
            $text -match '7zip\.7zip@24\.08' | Should -BeTrue
            @(Get-ChildItem -LiteralPath $script:ManifestsDir -Filter '*.bak-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
            @($script:LogMessages | Where-Object { $_ -match '未选中任何条目' }).Count | Should -Be 1
        }

        It 'creates the manifest on first generation (missing file = empty existing manifest)' {
            Remove-Item -LiteralPath (Join-Path $script:ManifestsDir 'winget-packages.txt') -Force -ErrorAction SilentlyContinue
            $result = Invoke-OTestWrite -Category @('winget') -InputText 'all' -InstalledByCategory @{
                winget = @(
                    [pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02' },
                    [pscustomobject]@{ Id = 'Microsoft.PowerToys'; Version = $null }
                )
            }
            $result['winget'].Changed | Should -BeTrue
            $result['winget'].BackupPath | Should -BeNullOrEmpty
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'winget-packages.txt'), [System.Text.Encoding]::UTF8)
            $text.Trim() | Should -Be "7zip.7zip@26.02`r`nMicrosoft.PowerToys"
            @(Get-ChildItem -LiteralPath $script:ManifestsDir -Filter '*.bak-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'pins pip entries as name==version' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'requirements.txt') -Value @('six==1.16.0') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('pip') -InputText '' -InstalledByCategory @{
                pip = @([pscustomobject]@{ Name = 'six'; Version = '1.17.0' })
            }
            $result['pip'].Changed | Should -BeTrue
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'requirements.txt'), [System.Text.Encoding]::UTF8)
            $text.Trim() | Should -Be 'six==1.17.0'
        }

        It 'pins npm entries as name@Version' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'npm-packages.txt') -Value @('lodash') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('npm') -InputText '' -InstalledByCategory @{
                npm = @([pscustomobject]@{ Name = 'lodash'; Version = '4.17.21' })
            }
            $result['npm'].Changed | Should -BeTrue
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'npm-packages.txt'), [System.Text.Encoding]::UTF8)
            $text.Trim() | Should -Be 'lodash@4.17.21'
        }

        It 'pins bun entries as name@Version into bun-packages.txt' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'bun-packages.txt') -Value @('is-odd') -Encoding UTF8
            $result = Invoke-OTestWrite -Category @('bun') -InputText '' -IncludeBun -InstalledByCategory @{
                bun = @([pscustomobject]@{ Name = 'is-odd'; Version = '3.0.1' })
            }
            $result['bun'].Changed | Should -BeTrue
            $text = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'bun-packages.txt'), [System.Text.Encoding]::UTF8)
            $text.Trim() | Should -Be 'is-odd@3.0.1'
        }

        It 'skips the bun category (Info log, no error, no file) when the config has no paths.bunList' {
            Remove-Item -LiteralPath (Join-Path $script:ManifestsDir 'bun-packages.txt') -Force -ErrorAction SilentlyContinue
            $result = Invoke-OTestWrite -Category @('bun') -InputText 'all' -InstalledByCategory @{
                bun = @([pscustomobject]@{ Name = 'is-odd'; Version = '3.0.1' })
            }
            $result['bun'].Selected | Should -Be 0
            $result['bun'].Changed | Should -BeFalse
            @($script:LogMessages | Where-Object { $_ -match "no 'paths\.bunList'" }).Count | Should -Be 1
            Test-Path -LiteralPath (Join-Path $script:ManifestsDir 'bun-packages.txt') | Should -BeFalse
        }

        It 'expands selected directories and adds only selected files' {
            $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot
            $config = Get-OSyncConfig -Path $configPath
            $script:ChezmoiCalls = @()
            $script:PickerCalls = @()
            $script:LogMessages = @()

            Mock Write-OSyncLog {
                param($Category, $Level, $Message, $Data, $Config, $LogDir)
                $script:LogMessages += $Message
            }
            Mock Resolve-OSyncChezmoiExe { return 'fake-chezmoi.exe' }
            Mock Get-OSyncUnmanagedDotfiles {
                return @(
                    [pscustomobject]@{ Key = '.config'; Display = '.config'; Preselected = $false; PinnedText = '.config'; IsDirectory = $true }
                    [pscustomobject]@{ Key = '.gitconfig'; Display = '.gitconfig'; Preselected = $false; PinnedText = '.gitconfig'; IsDirectory = $false }
                )
            }
            Mock Get-OSyncManagedDotfilePaths { return @{} }
            Mock Expand-OSyncUnmanagedDotfileDirectories {
                return @(
                    [pscustomobject]@{ Key = '.config\one.txt'; Display = '.config\one.txt'; Preselected = $false; PinnedText = '.config\one.txt'; IsDirectory = $false }
                    [pscustomobject]@{ Key = '.config\two.txt'; Display = '.config\two.txt'; Preselected = $false; PinnedText = '.config\two.txt'; IsDirectory = $false }
                )
            }
            Mock Invoke-OSyncChezmoiTextCommand {
                param($ChezmoiExe, $Arguments, $TimeoutMs)
                $script:ChezmoiCalls += ,@($Arguments)
                return [pscustomobject]@{
                    ExitCode = 0
                    TimedOut = $false
                    Stdout   = 'added selected files'
                    Stderr   = ''
                }
            }
            Mock Show-OSyncEntryPicker {
                param($Category, $Entries, $Expanded)
                $isExpanded = [bool]$Expanded
                $script:PickerCalls += [pscustomobject]@{ Expanded = $isExpanded; Entries = @($Entries) }
                return @($Entries | ForEach-Object {
                    [pscustomobject]@{
                        Key         = $_.Key
                        Display     = $_.Display
                        Preselected = $_.Preselected
                        PinnedText  = $_.PinnedText
                        IsDirectory = $_.IsDirectory
                        Selected    = if ($isExpanded) { $_.Display -eq '.config\one.txt' } else { $_.Display -in @('.config', '.gitconfig') }
                    }
                })
            }

            $result = Invoke-OSyncManifestGenerate -Config $config -Category @('dotfiles')

            $result['dotfiles'].Selected | Should -Be 2
            $result['dotfiles'].Changed | Should -BeTrue
            $script:PickerCalls.Count | Should -Be 2
            $script:PickerCalls[0].Expanded | Should -BeFalse
            $script:PickerCalls[0].Entries[0].IsDirectory | Should -BeTrue
            $script:PickerCalls[1].Expanded | Should -BeTrue
            $script:PickerCalls[1].Entries.Count | Should -Be 2
            $addCall = @($script:ChezmoiCalls | Where-Object { $_ -contains 'add' })[0]
            $addCall | Should -Not -BeNullOrEmpty
            $addCall | Should -Contain (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config\one.txt')
            $addCall | Should -Contain (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gitconfig')
            $addCall | Should -Not -Contain (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config')
            @($script:LogMessages | Where-Object { $_ -match 'dotfiles added 2 file' }).Count | Should -Be 1
        }

        It 'batches long chezmoi add command lines' {
            $script:ChezmoiCalls = @()
            Mock Invoke-OSyncChezmoiTextCommand {
                param($ChezmoiExe, $Arguments, $TimeoutMs)
                $script:ChezmoiCalls += ,@($Arguments)
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = ''; Stderr = '' }
            }

            $targetPaths = @(1..500 | ForEach-Object {
                ".config\long-folder\file-$($_)-$([string]('x' * 40)).json"
            })
            $result = Add-OSyncDotfilesWithChezmoi -ChezmoiExe 'fake-chezmoi.exe' -SourceDir (Join-Path $TestDrive 'source') -DestinationDir (Join-Path $TestDrive 'destination') -TargetPaths $targetPaths

            $result.BatchCount | Should -BeGreaterThan 1
            $script:ChezmoiCalls.Count | Should -Be $result.BatchCount
            @($script:ChezmoiCalls | ForEach-Object { (ConvertTo-OSyncQuotedArgs -ArgList $_).Length } | Where-Object { $_ -gt 24000 }).Count | Should -Be 0
        }
        It 'recursively expands files and skips managed paths' {
            $destination = Join-Path $TestDrive 'dotfiles-destination'
            New-Item -ItemType Directory -Path (Join-Path $destination '.config\nested') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $destination '.config\one.txt') -Value 'one' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $destination '.config\nested\two.txt') -Value 'two' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $destination '.config\nested\managed.txt') -Value 'managed' -Encoding UTF8
            $entries = @([pscustomobject]@{ Display = '.config'; IsDirectory = $true })
            $managed = @{ '.config\nested\managed.txt' = $true }

            $expanded = @(Expand-OSyncUnmanagedDotfileDirectories -Entries $entries -DestinationDir $destination -ManagedPaths $managed)

            @($expanded | ForEach-Object Display) | Should -Contain '.config\one.txt'
            @($expanded | ForEach-Object Display) | Should -Contain '.config\nested\two.txt'
            @($expanded | Where-Object { $_.IsDirectory }).Count | Should -Be 0
            @($expanded | Where-Object { $_.Display -eq '.config\nested\managed.txt' }).Count | Should -Be 0
        }

        It 'requests files, directories and symlinks from chezmoi for top-level candidates' {
            $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot
            $config = Get-OSyncConfig -Path $configPath
            $destination = Join-Path $TestDrive 'unmanaged-destination'
            New-Item -ItemType Directory -Path (Join-Path $destination '.config') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $destination '.config\one.txt') -Value 'one' -Encoding UTF8
            $script:ChezmoiCalls = @()

            Mock Invoke-OSyncChezmoiTextCommand {
                param($ChezmoiExe, $Arguments, $TimeoutMs)
                $script:ChezmoiCalls += ,@($Arguments)
                if ($Arguments -contains 'unmanaged') {
                    return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = '.config'; Stderr = '' }
                }
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = ''; Stderr = '' }
            }

            $result = Get-OSyncUnmanagedDotfiles -ChezmoiExe 'fake-chezmoi.exe' -SourceDir $script:ManifestsDir -DestinationDir $destination

            $result.Count | Should -Be 1
            $result[0].IsDirectory | Should -BeTrue
            $unmanagedCall = @($script:ChezmoiCalls | Where-Object { $_ -contains 'unmanaged' })[0]
            $unmanagedCall | Should -Contain '--include'
            $unmanagedCall | Should -Contain 'files,dirs,symlinks'
        }
        It 'rejects a dotfiles source state that equals the chezmoi destination' {
            $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot
            $config = Get-OSyncConfig -Path $configPath
            $config.paths.dotfilesSource = $env:USERPROFILE

            { Invoke-OSyncManifestGenerateDotfiles -Config $config } | Should -Throw '*equals the chezmoi destination*'
        }
        It 'includes dotfiles in the default category filter' {
            $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot
            $config = Get-OSyncConfig -Path $configPath
            Mock Write-OSyncLog { }
            Mock Invoke-OSyncManifestGenerateCategory {
                return @{ Selected = 0; Changed = $false; BackupPath = $null }
            }
            Mock Invoke-OSyncManifestGenerateDotfiles {
                return @{ Selected = 0; Changed = $false; BackupPath = $null }
            }

            $result = Invoke-OSyncManifestGenerate -Config $config

            $result.ContainsKey('winget') | Should -BeTrue
            $result.ContainsKey('pip') | Should -BeTrue
            $result.ContainsKey('npm') | Should -BeTrue
            $result.ContainsKey('dotfiles') | Should -BeTrue
        }
        It 'isolates a failing category and continues with the others' {
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'requirements.txt') -Value @('six==1.16.0') -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $script:ManifestsDir 'npm-packages.txt') -Value @('is-odd@3.0.1') -Encoding UTF8
            $configPath = New-OTestConfigFile -ToolRoot $script:ToolRoot -RepoRoot $script:RepoRoot
            $config = Get-OSyncConfig -Path $configPath
            $script:LogMessages = @()
            Mock Write-OSyncLog {
                param($Category, $Level, $Message, $Data, $Config, $LogDir)
                $script:LogMessages += $Message
            }
            Mock Read-Host { return 'all' }
            Mock Get-OSyncInstalledWinget { throw 'winget boom' }
            Mock Get-OSyncInstalledPip { return @([pscustomobject]@{ Name = 'six'; Version = '1.17.0' }) }
            Mock Get-OSyncInstalledNpm { return @([pscustomobject]@{ Name = 'is-odd'; Version = '3.0.2' }) }
            $result = Invoke-OSyncManifestGenerate -Config $config -Category @('winget', 'pip', 'npm')
            $result['winget'].Selected | Should -Be 0
            $result['pip'].Selected | Should -Be 1
            $result['npm'].Selected | Should -Be 1
            @($script:LogMessages | Where-Object { $_ -match 'winget boom' }).Count | Should -Be 1
            $pipText = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'requirements.txt'), [System.Text.Encoding]::UTF8)
            $pipText.Trim() | Should -Be 'six==1.17.0'
            $npmText = [System.IO.File]::ReadAllText((Join-Path $script:ManifestsDir 'npm-packages.txt'), [System.Text.Encoding]::UTF8)
            $npmText.Trim() | Should -Be 'is-odd@3.0.2'
        }
    }
}
