#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\ExportOrchestrator.ps1 - the A-side
    export orchestration (Invoke-OSyncExport, the core of
    src\Export-OfflineRepo.ps1).

.DESCRIPTION
    Every category export (Export-OSyncWinget/Pip/Npm/Dotfiles/Runtime) is
    MOCKED - no network, no winget, no python. The contract functions
    (New-OSyncFilesManifest / Publish-OSyncIndex / Test-OSyncRepoIntegrity /
    Invoke-OSyncRobocopy) run for real on $TestDrive directories, so the
    tests verify the REAL orchestration semantics: call order, failure
    isolation, the integrity gate, and the publish order (index.json is the
    last file written/copied).

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\ExportOrchestrator.Tests.ps1 -PassThru"
      pwsh      -NoProfile -Command "Invoke-Pester tests\ExportOrchestrator.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files are
    dot-sourced and helper functions are defined INSIDE BeforeAll; data
    shared with the It blocks uses $script: scope (same pattern as the other
    test files in this plan). The export mocks receive the real call
    arguments (param(...) in the mock body) and create one small file in
    their category dir, so the real manifest/index/integrity pipeline has
    real content to work on.
#>

Describe 'ExportOrchestrator' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\PipExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\NpmExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RepoContract.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ExportOrchestrator.ps1')

        # --- config helper: writes a full valid packagesync config JSON ---
        function New-OTestConfigFile {
            param(
                [string]$RepoRoot,
                [string]$StagingRoot,
                [string]$Role = 'A',
                [hashtable]$Categories = @{ winget = $true; pip = $true; npm = $true; dotfiles = $true }
            )
            $config = [ordered]@{
                schemaVersion = 1
                role          = $Role
                repoRoot      = $RepoRoot
                stagingRoot   = $StagingRoot
                httpBind      = '127.0.0.1'
                httpPort      = 8788
                verdaccioPort = 4873
                npm           = [ordered]@{ aVerdaccioPort = 4874 }
                categories    = [ordered]@{
                    winget   = [bool]$Categories.winget
                    pip      = [bool]$Categories.pip
                    npm      = [bool]$Categories.npm
                    dotfiles = [bool]$Categories.dotfiles
                }
                paths = [ordered]@{
                    wingetWhitelist  = 'manifests\winget-packages.txt'
                    runtimeWhitelist = 'manifests\runtime-winget.txt'
                    requirements     = 'manifests\requirements.txt'
                    npmList          = 'manifests\npm-packages.txt'
                    dotfilesSource   = 'manifests\dotfiles'
                }
                winget = [ordered]@{ scope = 'machine'; architecture = 'x64' }
                pip    = [ordered]@{
                    downloadArgs    = @('--only-binary=:all:', '--platform', 'win_amd64', '--python-version', '3.12', '--implementation', 'cp', '--abi', 'cp312')
                    upgradeOnApply  = $true
                    allowSdist      = $false
                }
                stateDir = Join-Path $RepoRoot 'state'
                pins = [ordered]@{
                    chezmoi = [ordered]@{
                        version = '2.72.0'
                        url     = 'https://example.invalid/chezmoi.zip'
                        sha256  = ('a' * 64)
                    }
                    appInstaller = [ordered]@{
                        msixbundleUrl    = 'https://example.invalid/msixbundle'
                        msixbundleSha256 = ('b' * 64)
                        vcLibsUrl        = 'https://example.invalid/vclibs'
                        vcLibsSha256     = ('c' * 64)
                        uiXamlUrl        = 'https://example.invalid/uixaml'
                        uiXamlSha256     = ('d' * 64)
                        vcRedistUrl      = 'https://example.invalid/vcredist'
                        vcRedistSha256   = ('e' * 64)
                    }
                    npm = [ordered]@{ verdaccioVersion = '6.10.2' }
                }
            }
            $path = Join-Path $TestDrive ("config-{0}.json" -f [guid]::NewGuid().ToString('N'))
            [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $config -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
            return $path
        }

        # --- repo helper: manifests under <RepoRoot>\manifests (paths.* are repo-root-relative) ---
        function New-OTestRepo {
            param([string]$RepoRoot)
            New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'manifests\dotfiles') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $RepoRoot 'manifests\winget-packages.txt') -Value @('# test', '7zip.7zip@26.02') -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $RepoRoot 'manifests\runtime-winget.txt') -Value @('Python.Python.3.12@3.12.10', 'OpenJS.NodeJS.LTS@24.19.0') -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $RepoRoot 'manifests\requirements.txt') -Value 'six==1.17.0' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $RepoRoot 'manifests\npm-packages.txt') -Value 'is-odd@3.0.1' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $RepoRoot 'manifests\dotfiles\dot_bashrc') -Value 'export FOO=bar' -Encoding UTF8
        }

        $script:OkReport = [pscustomobject]@{ category = 'x'; ok = @(); failed = @() }
    }

    BeforeEach {
        $script:CallLog = @()
        $script:FailCategory = $null

        # Each export mock records the call order, optionally throws (failure
        # isolation tests), and creates one small file in its category dir so
        # the real manifest/index/integrity pipeline has real content.
        Mock Export-OSyncWinget {
            param($ParsedList, $StagingDir, $Config)
            $script:CallLog += 'winget'
            if ($script:FailCategory -eq 'winget') { throw 'mock winget failure' }
            $dir = Join-Path $StagingDir 'winget'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'packages.txt') -Value '7zip.7zip' -Encoding UTF8
            return $script:OkReport
        }
        Mock Export-OSyncPip {
            param($Config, $StagingDir)
            $script:CallLog += 'pip'
            if ($script:FailCategory -eq 'pip') { throw 'mock pip failure' }
            $dir = Join-Path $StagingDir 'pip'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'requirements.txt') -Value 'six==1.17.0' -Encoding UTF8
            return $script:OkReport
        }
        Mock Export-OSyncNpm {
            param($Config, $StagingDir, $ConfigPath)
            $script:CallLog += 'npm'
            if ($script:FailCategory -eq 'npm') { throw 'mock npm failure' }
            $dir = Join-Path $StagingDir 'npm'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'packages.txt') -Value 'is-odd@3.0.1' -Encoding UTF8
            return $script:OkReport
        }
        Mock Export-OSyncDotfiles {
            param($Config, $StagingDir)
            $script:CallLog += 'dotfiles'
            if ($script:FailCategory -eq 'dotfiles') { throw 'mock dotfiles failure' }
            $dir = Join-Path $StagingDir 'dotfiles'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'chezmoi.toml') -Value '[data]' -Encoding UTF8
            return $script:OkReport
        }
        Mock Export-OSyncRuntime {
            param($Config, $StagingDir)
            $script:CallLog += 'runtime'
            if ($script:FailCategory -eq 'runtime') { throw 'mock runtime failure' }
            $dir = Join-Path $StagingDir 'runtime'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'runtime-winget.txt') -Value 'Python.Python.3.12@3.12.10' -Encoding UTF8
            return $script:OkReport
        }

        # Pre-flight resolvers: fake success by default (per-test overrides below).
        Mock Resolve-OSyncPython { return 'C:\fake\python.exe' }
        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }
    }

    Context 'happy path - full export -> integrity -> publish' {
        It 'exports all categories in order, publishes, and index.json is the newest file in repoRoot' {
            $repoRoot = Join-Path $TestDrive 'repo'
            $stagingRoot = Join-Path $TestDrive 'staging'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles'

            # single report object - no leaked Write-OSyncLog paths
            $report -is [System.Array] | Should -Be $false
            @($report).Count | Should -Be 1
            $report.GetType().Name | Should -Be 'PSCustomObject'

            # call order: winget -> pip -> npm -> dotfiles -> runtime
            $script:CallLog | Should -Be @('winget', 'pip', 'npm', 'dotfiles', 'runtime')

            # staging: generation dir named like the index exportedAtUtc
            $report.success | Should -Be $true
            $report.published | Should -Be $true
            $report.failedCategories.Count | Should -Be 0
            $report.stagingDir | Should -Match '\\\d{8}T\d{6}Z$'
            (Split-Path -Leaf $report.stagingDir) | Should -Match '^\d{8}T\d{6}Z$'

            # every category dir manifested; index.json exists in staging root
            foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
                Test-Path -LiteralPath (Join-Path $report.stagingDir "$cat\files.json") | Should -Be $true
            }
            Test-Path -LiteralPath (Join-Path $report.stagingDir 'index.json') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $report.stagingDir 'export-report.json') | Should -Be $true

            # index.json written AFTER every files.json (last index artifact)
            $indexMtime = (Get-Item -LiteralPath (Join-Path $report.stagingDir 'index.json')).LastWriteTimeUtc
            foreach ($f in @(Get-ChildItem -LiteralPath $report.stagingDir -Recurse -Filter 'files.json' -File)) {
                $f.LastWriteTimeUtc | Should -BeLessOrEqual $indexMtime
            }

            # publish: all category dirs + index.json in repoRoot
            foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
                Test-Path -LiteralPath (Join-Path $repoRoot "$cat\files.json") | Should -Be $true
            }
            Test-Path -LiteralPath (Join-Path $repoRoot 'index.json') | Should -Be $true

            # index.json is the NEWEST file in repoRoot (copied last). The
            # repo payload = category dirs + index.json; the operational
            # logs dir (role A -> <repoRoot>\logs, written by Write-OSyncLog
            # after the publish) is out of the repo contract scope.
            $newest = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
                Where-Object { $_.FullName -notmatch '\\logs\\' } |
                Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $newest.Name | Should -Be 'index.json'

            # integrity reported OK
            $report.integrity.overall | Should -Be 'OK'
        }

        It 'keeps only the newest 3 staging generations and never touches .verdaccio-a' {
            $repoRoot = Join-Path $TestDrive 'repo2'
            $stagingRoot = Join-Path $TestDrive 'staging2'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            # 5 pre-existing generations + the A-side-only tool dir
            foreach ($i in 1..5) {
                New-Item -ItemType Directory -Path (Join-Path $stagingRoot ("20260903T0{0}0000Z" -f $i)) -Force | Out-Null
            }
            New-Item -ItemType Directory -Path (Join-Path $stagingRoot '.verdaccio-a') -Force | Out-Null

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles'

            $report.success | Should -Be $true
            # the 3 oldest generations were removed (descending iteration)
            $report.cleanup.removed.Count | Should -Be 3
            foreach ($old in @('20260903T010000Z', '20260903T020000Z', '20260903T030000Z')) {
                $report.cleanup.removed | Should -Contain $old
            }
            $report.cleanup.kept.Count | Should -Be 3
            $report.cleanup.kept | Should -Contain (Split-Path -Leaf $report.stagingDir)

            $remaining = @(Get-ChildItem -LiteralPath $stagingRoot -Directory | Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' })
            $remaining.Count | Should -Be 3
            Test-Path -LiteralPath (Join-Path $stagingRoot '.verdaccio-a') | Should -Be $true
        }
    }

    Context 'failure isolation and gates' {
        It 'a failing category does not block the others, and publish is aborted' {
            $repoRoot = Join-Path $TestDrive 'repo3'
            $stagingRoot = Join-Path $TestDrive 'staging3'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot
            $script:FailCategory = 'pip'

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles'

            # all other categories still ran
            $script:CallLog | Should -Contain 'winget'
            $script:CallLog | Should -Contain 'npm'
            $script:CallLog | Should -Contain 'dotfiles'
            $script:CallLog | Should -Contain 'runtime'

            # pip recorded as failed
            $report.categories.pip.status | Should -Be 'failed'
            $report.categories.pip.error | Should -BeLike '*mock pip failure*'
            $report.failedCategories | Should -Be @('pip')

            # publish aborted: nothing landed in repoRoot
            $report.published | Should -Be $false
            $report.success | Should -Be $false
            Test-Path -LiteralPath (Join-Path $repoRoot 'index.json') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $repoRoot 'winget') | Should -Be $false
        }

        It 'integrity gate: an Incomplete staging repo aborts the publish' {
            $repoRoot = Join-Path $TestDrive 'repo4'
            $stagingRoot = Join-Path $TestDrive 'staging4'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            Mock Test-OSyncRepoIntegrity {
                return [pscustomobject]@{ Overall = 'Incomplete'; Categories = @{} }
            }

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles'

            $report.integrity.overall | Should -Be 'Incomplete'
            $report.published | Should -Be $false
            $report.success | Should -Be $false
            Test-Path -LiteralPath (Join-Path $repoRoot 'index.json') | Should -Be $false
            Test-Path -LiteralPath (Join-Path $repoRoot 'winget') | Should -Be $false
        }
    }

    Context 'category selection' {
        It 'disabled categories are not exported and get no index key' {
            $repoRoot = Join-Path $TestDrive 'repo5'
            $stagingRoot = Join-Path $TestDrive 'staging5'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot -Categories @{ winget = $true; pip = $true; npm = $false; dotfiles = $true }

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles'

            $report.success | Should -Be $true
            $script:CallLog | Should -Be @('winget', 'pip', 'dotfiles', 'runtime')
            $script:CallLog | Should -Not -Contain 'npm'

            # index.json in repoRoot has no npm key
            $index = Get-Content -LiteralPath (Join-Path $repoRoot 'index.json') -Raw | ConvertFrom-Json
            $index.categories.PSObject.Properties.Name | Should -Not -Contain 'npm'
            $index.categories.PSObject.Properties.Name | Should -Contain 'winget'
            $index.categories.PSObject.Properties.Name | Should -Contain 'pip'
            $index.categories.PSObject.Properties.Name | Should -Contain 'dotfiles'
            $index.categories.PSObject.Properties.Name | Should -Contain 'runtime'
            Test-Path -LiteralPath (Join-Path $repoRoot 'npm') | Should -Be $false
        }

        It '-Category filters which categories run (runtime still runs)' {
            $repoRoot = Join-Path $TestDrive 'repo6'
            $stagingRoot = Join-Path $TestDrive 'staging6'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'pip'

            $report.success | Should -Be $true
            $script:CallLog | Should -Be @('pip', 'runtime')
            Test-Path -LiteralPath (Join-Path $repoRoot 'pip') | Should -Be $true
            Test-Path -LiteralPath (Join-Path $repoRoot 'winget') | Should -Be $false
        }

        It 'no categories enabled: reports success without any staging work' {
            $repoRoot = Join-Path $TestDrive 'repo7'
            $stagingRoot = Join-Path $TestDrive 'staging7'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot -Categories @{ winget = $false; pip = $false; npm = $false; dotfiles = $false }

            $report = Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles'

            $report.success | Should -Be $true
            $report.published | Should -Be $false
            $report.note | Should -BeLike '*nothing to export*'
            $script:CallLog.Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'unknown -Category value throws' {
            $repoRoot = Join-Path $TestDrive 'repo8'
            $stagingRoot = Join-Path $TestDrive 'staging8'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            $err = $null
            try { Invoke-OSyncExport -ConfigPath $cfg -Category 'foo' } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*unknown -Category*'
        }
    }

    Context 'config and pre-flight gates' {
        It 'role B config is rejected with an explicit error' {
            $repoRoot = Join-Path $TestDrive 'repo9'
            $stagingRoot = Join-Path $TestDrive 'staging9'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot -Role 'B'

            $err = $null
            try { Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles' } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike "*role must be 'A'*"
        }

        It 'pre-flight: missing node is an explicit error before any staging work' {
            $repoRoot = Join-Path $TestDrive 'repo10'
            $stagingRoot = Join-Path $TestDrive 'staging10'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            Mock Get-Command { return $null } -ParameterFilter { $Name -eq 'node' }

            $err = $null
            try { Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles' } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*node*'
            # no staging generation was created
            @(Get-ChildItem -LiteralPath $stagingRoot -Directory -ErrorAction SilentlyContinue).Count | Should -Be 0
        }

        It 'pre-flight: missing python is an explicit error' {
            $repoRoot = Join-Path $TestDrive 'repo11'
            $stagingRoot = Join-Path $TestDrive 'staging11'
            New-OTestRepo -RepoRoot $repoRoot
            $cfg = New-OTestConfigFile -RepoRoot $repoRoot -StagingRoot $stagingRoot

            Mock Resolve-OSyncPython { throw 'Resolve-OSyncPython: no usable python interpreter' }

            $err = $null
            try { Invoke-OSyncExport -ConfigPath $cfg -Category 'winget,pip,npm,dotfiles' } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -BeLike '*python*'
        }
    }
}