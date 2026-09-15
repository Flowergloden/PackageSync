#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\WingetApply.ps1.

.DESCRIPTION
    Exit-code mapping table (mocked winget invocation), packages.txt /
    runtime-winget.txt exclusion logic, the port-coupling guard, and the
    exact winget command line (fake winget .cmd). NO network is touched and
    no real winget install is performed by any test.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\WingetApply.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes, so helper
    functions/scriptblocks are defined INSIDE BeforeAll and data is shared
    via $script: scope. Mock scriptblocks read $script:mockExitCode to
    control the simulated winget exit code per test.
#>

Describe 'WingetApply: exit-code mapping table (mocked winget invocation)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')

        $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures\winget\7zip.7zip'

        # Builds a work copy whose 7zip manifest is REWRITTEN to
        # http://127.0.0.1:8788/... (the realistic post-export state).
        $script:NewWorkCopy = {
            param([string]$Root)
            $pkgDir = Join-Path $Root 'winget\7zip.7zip'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') -Destination $pkgDir
            [System.IO.File]::WriteAllBytes((Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.msi'), [byte[]]@(1, 2, 3))
            ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
                -IdDir $pkgDir -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root 'winget\packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
        }

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{
                role     = 'B'
                stateDir = $StateDir
                httpPort = 8788
                winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
            }
        }

        $script:work = Join-Path $TestDrive 'work'
        & $script:NewWorkCopy $script:work

        # Simulated winget exit code, controlled per test.
        $script:mockExitCode = 0

        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall {
            if ($Arguments -match 'second\.Pkg') {
                return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Output = 'boom' }
            }
            return [pscustomobject]@{ ExitCode = $script:mockExitCode; TimedOut = $false; Output = 'mocked install output' }
        }
    }

    It 'exit 0 -> ok, state record written with version and sha256' {
        $stateDir = Join-Path $TestDrive 'state-ok'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg

        $report.ok.Count | Should -Be 1
        $report.ok[0].Id | Should -Be '7zip.7zip'
        $report.ok[0].Version | Should -Be '26.02'
        $report.ok[0].Sha256 | Should -Be 'db407a4f6d4999e5c7bc00ce8a882be94717b56e7fa68140fe3f12605d91643e'
        $report.satisfied.Count | Should -Be 0
        $report.failed.Count | Should -Be 0

        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.winget['7zip.7zip'].version | Should -Be '26.02'
        $state.winget['7zip.7zip'].sha256 | Should -Be 'db407a4f6d4999e5c7bc00ce8a882be94717b56e7fa68140fe3f12605d91643e'
    }

    It 'treats winget 0x8A150109 (installer exit 3010) as success requiring reboot' {
        $stateDir = Join-Path $TestDrive 'state-reboot-required'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = -1978334967

        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg

        $report.ok.Count | Should -Be 1
        $report.ok[0].Id | Should -Be '7zip.7zip'
        $report.ok[0].ExitCode | Should -Be -1978334967
        $report.failed.Count | Should -Be 0
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.winget['7zip.7zip'].version | Should -Be '26.02'
    }
    It 'each satisfied exit code maps to satisfied and writes the state record' {
        # The constant currently holds @(0); 0 is handled by the ok branch, so
        # extend it with a representative NON-ZERO satisfied code to exercise
        # the satisfied branch (the real observed codes are pinned after QA).
        # -1978273215 == 0x8A150011, winget's "already installed" code.
        $script:WingetSatisfiedExitCodes = @(0, -1978273215)

        foreach ($code in $script:WingetSatisfiedExitCodes) {
            $stateDir = Join-Path $TestDrive ('state-sat-{0}' -f $code)
            $cfg = & $script:NewConfig $stateDir
            $script:mockExitCode = $code

            $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg

            if ($code -eq 0) {
                $report.ok.Count | Should -Be 1
                $report.satisfied.Count | Should -Be 0
            }
            else {
                $report.satisfied.Count | Should -Be 1
                $report.satisfied[0].Id | Should -Be '7zip.7zip'
                $report.satisfied[0].ExitCode | Should -Be $code
                $report.ok.Count | Should -Be 0
            }
            $report.failed.Count | Should -Be 0

            $state = Get-OSyncState -Category winget -StateDir $stateDir
            $state.winget['7zip.7zip'].version | Should -Be '26.02'
        }
    }

    It 'non-zero non-satisfied exit -> failed, no state record, aggregate throws' {
        $stateDir = Join-Path $TestDrive 'state-fail'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 1

        { Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg } |
            Should -Throw -ExpectedMessage '*failed to install*7zip.7zip*'

        # No state record for a failed package.
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.winget.Keys | Should -Not -Contain '7zip.7zip'
    }

    It 'a failed package does not stop later packages (aggregate still throws)' {
        $work = Join-Path $TestDrive 'work-continue'
        & $script:NewWorkCopy $work
        $pkgDir2 = Join-Path $work 'winget\second.Pkg'
        New-Item -ItemType Directory -Path $pkgDir2 -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
            -Destination (Join-Path $pkgDir2 'Second_1.0.0_Machine_X64_wix_zh-CN.yaml')
        [System.IO.File]::WriteAllBytes((Join-Path $pkgDir2 'Second_1.0.0_Machine_X64_wix_zh-CN.msi'), [byte[]]@(9))
        ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir2 'Second_1.0.0_Machine_X64_wix_zh-CN.yaml') `
            -IdDir $pkgDir2 -Id 'second.Pkg' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
        Add-Content -LiteralPath (Join-Path $work 'winget\packages.txt') -Value 'second.Pkg@1.0.0'

        $stateDir = Join-Path $TestDrive 'state-continue'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        { Invoke-OSyncWingetApply -WorkDir $work -Config $cfg } |
            Should -Throw -ExpectedMessage '*second.Pkg*'

        # 7zip was still processed AFTER the failure (state record written).
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.winget['7zip.7zip'].version | Should -Be '26.02'
    }

    It 'a package directory without any YAML is recorded as failed (exit -1)' {
        $work = Join-Path $TestDrive 'work-nomanifest'
        & $script:NewWorkCopy $work
        New-Item -ItemType Directory -Path (Join-Path $work 'winget\empty.Pkg') -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $work 'winget\packages.txt') -Value 'empty.Pkg'

        $stateDir = Join-Path $TestDrive 'state-nomanifest'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        { Invoke-OSyncWingetApply -WorkDir $work -Config $cfg } |
            Should -Throw -ExpectedMessage '*empty.Pkg*'

        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.winget['7zip.7zip'].version | Should -Be '26.02'
    }

    It 'returns a SINGLE report object - no leaked log paths in the pipeline' {
        $stateDir = Join-Path $TestDrive 'state-shape'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg

        $report -is [System.Array] | Should -BeFalse
        $report.GetType().Name | Should -Be 'PSCustomObject'
        @($report).Count | Should -Be 1
        $report.category | Should -Be 'winget'
        $report.wingetExe | Should -Be 'C:\fake\winget.exe'
    }
}

Describe 'WingetApply: packages.txt / runtime exclusion (work copy runtime-winget.txt)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')

        $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures\winget\7zip.7zip'
        $script:NewWorkCopy = {
            param([string]$Root)
            $pkgDir = Join-Path $Root 'winget\7zip.7zip'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') -Destination $pkgDir
            [System.IO.File]::WriteAllBytes((Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.msi'), [byte[]]@(1, 2, 3))
            ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
                -IdDir $pkgDir -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root 'winget\packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
        }
        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{
                role     = 'B'
                stateDir = $StateDir
                httpPort = 8788
                winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
            }
        }

        $script:mockExitCode = 0
        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall {
            return [pscustomobject]@{ ExitCode = $script:mockExitCode; TimedOut = $false; Output = 'mocked' }
        }
    }

    It 'excludes runtime IDs read from the WORK COPY runtime-winget.txt' {
        $work = Join-Path $TestDrive 'work-excl'
        & $script:NewWorkCopy $work
        Add-Content -LiteralPath (Join-Path $work 'winget\packages.txt') -Value "Python.Python.3.12@3.12.10`nOpenJS.NodeJS.LTS@24.19.0"
        $runtimeDir = Join-Path $work 'runtime'
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $runtimeDir 'runtime-winget.txt'),
            "Python.Python.3.12@3.12.10`nOpenJS.NodeJS.LTS@24.19.0",
            (New-Object System.Text.UTF8Encoding($true)))

        $stateDir = Join-Path $TestDrive 'state-excl'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config $cfg

        $report.ok.Count | Should -Be 1
        $report.ok[0].Id | Should -Be '7zip.7zip'
        $report.failed.Count | Should -Be 0

        # Runtime entries were never installed (no state records).
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.winget.Keys | Should -Not -Contain 'Python.Python.3.12'
        $state.winget.Keys | Should -Not -Contain 'OpenJS.NodeJS.LTS'
    }

    It 'treats a missing runtime-winget.txt as no exclusions' {
        $work = Join-Path $TestDrive 'work-noexcl'
        & $script:NewWorkCopy $work
        Add-Content -LiteralPath (Join-Path $work 'winget\packages.txt') -Value 'Python.Python.3.12@3.12.10'
        # No runtime directory at all in this work copy.

        $stateDir = Join-Path $TestDrive 'state-noexcl'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        # Python is NOT excluded -> attempted -> no manifest dir -> failed.
        { Invoke-OSyncWingetApply -WorkDir $work -Config $cfg } |
            Should -Throw -ExpectedMessage '*Python.Python.3.12*'
    }

    It 'empty packages.txt -> empty report, no install attempted, no server start' {
        $work = Join-Path $TestDrive 'work-empty'
        New-Item -ItemType Directory -Path (Join-Path $work 'winget') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $work 'winget\packages.txt'), '', (New-Object System.Text.UTF8Encoding($true)))

        $stateDir = Join-Path $TestDrive 'state-empty'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config $cfg

        $report.ok.Count | Should -Be 0
        $report.satisfied.Count | Should -Be 0
        $report.failed.Count | Should -Be 0
        Should -Invoke Start-OSyncHttpServer -Times 0 -Scope It
    }
}

Describe 'WingetApply: port-coupling guard (Oracle r7-4)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')

        $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures\winget\7zip.7zip'
        $script:NewWorkCopy = {
            param([string]$Root)
            $pkgDir = Join-Path $Root 'winget\7zip.7zip'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') -Destination $pkgDir
            [System.IO.File]::WriteAllBytes((Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.msi'), [byte[]]@(1, 2, 3))
            ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
                -IdDir $pkgDir -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root 'winget\packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
        }
        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{
                role     = 'B'
                stateDir = $StateDir
                httpPort = 8788
                winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
            }
        }

        $script:mockExitCode = 0
        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall {
            return [pscustomobject]@{ ExitCode = $script:mockExitCode; TimedOut = $false; Output = 'mocked' }
        }
    }

    It 'fails fast when a rewritten YAML port differs from config.httpPort' {
        $work = Join-Path $TestDrive 'work-portbad'
        & $script:NewWorkCopy $work
        $yaml = Join-Path $work 'winget\7zip.7zip\7-Zip_26.02_Machine_X64_wix_zh-CN.yaml'
        ConvertTo-OSyncWingetYamlContent -YamlPath $yaml -IdDir (Split-Path -Parent $yaml) `
            -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 9999 | Out-Null

        $stateDir = Join-Path $TestDrive 'state-portbad'
        $cfg = & $script:NewConfig $stateDir

        { Invoke-OSyncWingetApply -WorkDir $work -Config $cfg } |
            Should -Throw -ExpectedMessage '*port-coupling*'

        # Fail-fast: the HTTP server must never have been started.
        Should -Invoke Start-OSyncHttpServer -Times 0 -Scope It
    }

    It 'fails fast on an unparseable InstallerUrl (cannot prove coupling)' {
        $work = Join-Path $TestDrive 'work-portbad2'
        & $script:NewWorkCopy $work
        $yaml = Join-Path $work 'winget\7zip.7zip\7-Zip_26.02_Machine_X64_wix_zh-CN.yaml'
        $text = [System.IO.File]::ReadAllText($yaml, [System.Text.Encoding]::UTF8)
        $text = $text -replace 'http://127\.0\.0\.1:8788/[^\r\n]+', 'not a url at all'
        [System.IO.File]::WriteAllText($yaml, $text, (New-Object System.Text.UTF8Encoding($true)))

        $stateDir = Join-Path $TestDrive 'state-portbad2'
        $cfg = & $script:NewConfig $stateDir

        { Invoke-OSyncWingetApply -WorkDir $work -Config $cfg } |
            Should -Throw -ExpectedMessage '*port-coupling*'
    }

    It 'passes when all YAML ports match config.httpPort' {
        $work = Join-Path $TestDrive 'work-portok'
        & $script:NewWorkCopy $work

        $stateDir = Join-Path $TestDrive 'state-portok'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExitCode = 0

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config $cfg
        $report.ok.Count | Should -Be 1
    }
}

Describe 'WingetApply: winget command line (fake winget .cmd)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')

        $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures\winget\7zip.7zip'

        # Fake winget: a .cmd stub that records every command line and exits 0.
        $script:recordFile = Join-Path $TestDrive 'winget-args.txt'
        $script:fakeWinget = Join-Path $TestDrive 'fakewinget.cmd'
        $fakeContent = "@echo off`r`necho %* >> `"$($script:recordFile)`"`r`nexit /b 0"
        [System.IO.File]::WriteAllText($script:fakeWinget, $fakeContent, [System.Text.Encoding]::ASCII)

        $script:work = Join-Path $TestDrive 'work-cmd'
        $pkgDir = Join-Path $script:work 'winget\7zip.7zip'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') -Destination $pkgDir
        [System.IO.File]::WriteAllBytes((Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.msi'), [byte[]]@(1, 2, 3))
        ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
            -IdDir $pkgDir -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $script:work 'winget\packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))

        $script:cfg = [pscustomobject]@{
            role     = 'B'
            stateDir = (Join-Path $TestDrive 'state-cmd')
            httpPort = 8788
            winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
        }

        # P2 state-match skip makes a SHARED stateDir leaky across tests (a
        # successful install in one test records winget/7zip.7zip, and later
        # tests would then skip the winget call they exist to observe). Each
        # command-line test below therefore gets its OWN fresh stateDir.
        $script:NewCmdConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{
                role     = 'B'
                stateDir = $StateDir
                httpPort = 8788
                winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
            }
        }

        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
    }

    It 'passes install --manifest (manifest-only staging dir) --scope machine --architecture x64 --accept-package-agreements --accept-source-agreements --disable-interactivity' {
        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $script:cfg -WingetExePath $script:fakeWinget

        $report.ok.Count | Should -Be 1
        $report.ok[0].Id | Should -Be '7zip.7zip'

        $recorded = Get-Content -LiteralPath $script:recordFile -Raw
        $recorded -match 'install --manifest ".*winget-manifests\\7zip\.7zip" --scope machine --architecture x64 --accept-package-agreements --accept-source-agreements --disable-interactivity' |
            Should -BeTrue
    }

    It 'stages a manifest-ONLY flat directory (no installers, no subdirectories) for the --manifest argument' {
        $cfg = & $script:NewCmdConfig (Join-Path $TestDrive 'state-cmd-flat')
        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg -WingetExePath $script:fakeWinget

        $staging = Join-Path (Join-Path $cfg.stateDir 'run') 'winget-manifests\7zip.7zip'
        Test-Path -LiteralPath $staging -PathType Container | Should -BeTrue

        $files = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
        $files.Count | Should -Be 1
        $files[0].Extension | Should -Be '.yaml'
        $files[0].Name | Should -Be '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml'
    }

    It 'excludes Dependencies\ subdirectory YAMLs from staging (different PackageIdentifier would confuse winget)' {
        $depDir = Join-Path $script:work 'winget\7zip.7zip\Dependencies'
        New-Item -ItemType Directory -Path $depDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $depDir 'Dep_1.0.0_Machine_X64_msi_en-US.yaml'),
            "PackageIdentifier: dep.Test`nPackageVersion: 1.0.0`nInstallers:`n- Architecture: x64`n  InstallerType: msi`n  InstallerUrl: http://127.0.0.1:8788/winget/7zip.7zip/Dependencies/Dep_1.0.0_Machine_X64_msi_en-US.msi`n  InstallerSha256: 1111111111111111111111111111111111111111111111111111111111111111`n  Scope: machine`nManifestType: merged`nManifestVersion: 1.12.0",
            (New-Object System.Text.UTF8Encoding($true)))

        $cfg = & $script:NewCmdConfig (Join-Path $TestDrive 'state-cmd-deps')
        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg -WingetExePath $script:fakeWinget
        $report.ok.Count | Should -Be 1

        $staging = Join-Path (Join-Path $cfg.stateDir 'run') 'winget-manifests\7zip.7zip'
        # Only the main YAML, NOT the Dependencies\ YAML (different PackageIdentifier).
        $files = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
        $files.Count | Should -Be 1
        $files[0].Extension | Should -Be '.yaml'
        $files[0].Name | Should -Be '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml'
    }

    It 'detects msix/appx InstallerType and overrides scope to user' {
        # Clear the accumulated record from earlier tests (the fake winget
        # .cmd appends with >>).
        Clear-Content -LiteralPath $script:recordFile -Force -ErrorAction SilentlyContinue

        # Build a work copy with a MSIX manifest.
        $work = Join-Path $TestDrive 'work-msix'
        $pkgDir = Join-Path $work 'winget\Microsoft.PowerToys'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $pkgDir 'PowerToys_1.0.0_Machine_X64_msix_en-US.yaml'),
            "PackageIdentifier: Microsoft.PowerToys`nPackageVersion: 1.0.0`nInstallers:`n- Architecture: x64`n  InstallerType: msix`n  InstallerUrl: http://127.0.0.1:8788/winget/Microsoft.PowerToys/installer.msix`n  InstallerSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`nScope: user`nManifestType: merged`nManifestVersion: 1.12.0",
            (New-Object System.Text.UTF8Encoding($true)))
        [System.IO.File]::WriteAllBytes((Join-Path $pkgDir 'installer.msix'), [byte[]]@(1, 2, 3))
        [System.IO.File]::WriteAllText((Join-Path $work 'winget\packages.txt'), "Microsoft.PowerToys@1.0.0`r`n", (New-Object System.Text.UTF8Encoding($true)))

        # Config scope = 'machine', but MSIX should override to 'user'.
        $cfg = [pscustomobject]@{
            role     = 'B'
            stateDir = (Join-Path $TestDrive 'state-msix')
            httpPort = 8788
            winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
        }

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config $cfg -WingetExePath $script:fakeWinget

        # Verify the fake winget .cmd recorded --scope user instead of machine.
        $recorded = Get-Content -LiteralPath $script:recordFile -Raw
        $recorded -match '--scope user' | Should -BeTrue
        $recorded -notmatch '--scope machine' | Should -BeTrue
        $report.ok.Count | Should -Be 1
    }

    It 'does NOT override scope for non-MSIX packages (wix/msi/exe keep config scope)' {
        Clear-Content -LiteralPath $script:recordFile -Force -ErrorAction SilentlyContinue

        $cfg = & $script:NewCmdConfig (Join-Path $TestDrive 'state-cmd-nomsix')
        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg -WingetExePath $script:fakeWinget

        $recorded = Get-Content -LiteralPath $script:recordFile -Raw
        $recorded -match '--scope machine' | Should -BeTrue
        $report.ok.Count | Should -Be 1
    }

    It 'overrides scope for an explicitly user-scoped non-MSIX installer' {
        Clear-Content -LiteralPath $script:recordFile -Force -ErrorAction SilentlyContinue

        $work = Join-Path $TestDrive 'work-user-scope'
        $pkgDir = Join-Path $work 'winget\synthetic.UserScope'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $pkgDir 'User Scope_1.0.0_User_X64_nsis_en-US.yaml'),
            "PackageIdentifier: synthetic.UserScope`nPackageVersion: 1.0.0`nInstallers:`n- Architecture: x64`n  InstallerType: nsis`n  InstallerUrl: http://127.0.0.1:8788/winget/synthetic.UserScope/User%20Scope_1.0.0_User_X64_nsis_en-US.exe`n  InstallerSha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`n  Scope: user`nManifestType: merged`nManifestVersion: 1.12.0",
            (New-Object System.Text.UTF8Encoding($true)))
        [System.IO.File]::WriteAllBytes((Join-Path $pkgDir 'User Scope_1.0.0_User_X64_nsis_en-US.exe'), [byte[]]@(1, 2, 3))
        [System.IO.File]::WriteAllText((Join-Path $work 'winget\packages.txt'), "synthetic.UserScope@1.0.0`r`n", (New-Object System.Text.UTF8Encoding($true)))

        $cfg = & $script:NewCmdConfig (Join-Path $TestDrive 'state-cmd-user-scope')
        $report = Invoke-OSyncWingetApply -WorkDir $work -Config $cfg -WingetExePath $script:fakeWinget

        $recorded = Get-Content -LiteralPath $script:recordFile -Raw
        $recorded -match '--scope user' | Should -BeTrue
        $recorded -notmatch '--scope machine' | Should -BeTrue
        $report.ok.Count | Should -Be 1
    }
    It 're-derives winget.exe via Resolve-OSyncWingetExePath when no -WingetExePath is given' {
        Mock Resolve-OSyncWingetExePath { return $script:fakeWinget }

        $cfg = & $script:NewCmdConfig (Join-Path $TestDrive 'state-cmd-rederive')
        $report = Invoke-OSyncWingetApply -WorkDir $script:work -Config $cfg

        $report.wingetExe | Should -Be $script:fakeWinget
        $report.ok.Count | Should -Be 1
    }
}

Describe 'WingetApply: state-match skip (P2 incremental)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')

        $script:fixtureDir = Join-Path $PSScriptRoot 'fixtures\winget\7zip.7zip'
        $script:goldenSha = 'db407a4f6d4999e5c7bc00ce8a882be94717b56e7fa68140fe3f12605d91643e'

        $script:NewWorkCopy = {
            param([string]$Root)
            $pkgDir = Join-Path $Root 'winget\7zip.7zip'
            New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') -Destination $pkgDir
            [System.IO.File]::WriteAllBytes((Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.msi'), [byte[]]@(1, 2, 3))
            ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
                -IdDir $pkgDir -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $Root 'winget\packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
        }
        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{
                role     = 'B'
                stateDir = $StateDir
                httpPort = 8788
                winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
            }
        }

        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall {
            return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = 'mocked' }
        }
    }

    It 'skips install when the state record matches version+sha256 exactly (no winget call, no HTTP server)' {
        $work = Join-Path $TestDrive 'work-skip'
        & $script:NewWorkCopy $work
        $stateDir = Join-Path $TestDrive 'state-skip'
        Add-OSyncStateRecord -Category winget -Name '7zip.7zip' -Version '26.02' -Sha256 $script:goldenSha -StateDir $stateDir | Out-Null

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config (& $script:NewConfig $stateDir)

        $report.skipped.Count | Should -Be 1
        $report.skipped[0].Id | Should -Be '7zip.7zip'
        $report.skipped[0].Version | Should -Be '26.02'
        $report.skipped[0].Reason | Should -Be 'state-match'
        $report.ok.Count | Should -Be 0
        $report.satisfied.Count | Should -Be 0
        $report.failed.Count | Should -Be 0
        Should -Invoke Invoke-OSyncWingetInstall -Times 0 -Scope It
        Should -Invoke Start-OSyncHttpServer -Times 0 -Scope It
    }

    It 'installs normally when the recorded sha256 differs' {
        $work = Join-Path $TestDrive 'work-shadiff'
        & $script:NewWorkCopy $work
        $stateDir = Join-Path $TestDrive 'state-shadiff'
        Add-OSyncStateRecord -Category winget -Name '7zip.7zip' -Version '26.02' `
            -Sha256 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -StateDir $stateDir | Out-Null

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config (& $script:NewConfig $stateDir)

        $report.skipped.Count | Should -Be 0
        $report.ok.Count | Should -Be 1
        Should -Invoke Invoke-OSyncWingetInstall -Times 1 -Scope It
    }

    It 'installs normally when the recorded version differs' {
        $work = Join-Path $TestDrive 'work-verdiff'
        & $script:NewWorkCopy $work
        $stateDir = Join-Path $TestDrive 'state-verdiff'
        Add-OSyncStateRecord -Category winget -Name '7zip.7zip' -Version '25.0' -Sha256 $script:goldenSha -StateDir $stateDir | Out-Null

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config (& $script:NewConfig $stateDir)

        $report.skipped.Count | Should -Be 0
        $report.ok.Count | Should -Be 1
        Should -Invoke Invoke-OSyncWingetInstall -Times 1 -Scope It
    }

    It 'installs normally when no state record exists' {
        $work = Join-Path $TestDrive 'work-norec'
        & $script:NewWorkCopy $work
        $stateDir = Join-Path $TestDrive 'state-norec'

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config (& $script:NewConfig $stateDir)

        $report.skipped.Count | Should -Be 0
        $report.ok.Count | Should -Be 1
        Should -Invoke Invoke-OSyncWingetInstall -Times 1 -Scope It
    }

    It 'skips only the matched package in a mixed set' {
        $work = Join-Path $TestDrive 'work-mixed'
        & $script:NewWorkCopy $work
        $pkgDir2 = Join-Path $work 'winget\second.Pkg'
        New-Item -ItemType Directory -Path $pkgDir2 -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:fixtureDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml') `
            -Destination (Join-Path $pkgDir2 'Second_1.0.0_Machine_X64_wix_zh-CN.yaml')
        [System.IO.File]::WriteAllBytes((Join-Path $pkgDir2 'Second_1.0.0_Machine_X64_wix_zh-CN.msi'), [byte[]]@(9))
        ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $pkgDir2 'Second_1.0.0_Machine_X64_wix_zh-CN.yaml') `
            -IdDir $pkgDir2 -Id 'second.Pkg' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
        Add-Content -LiteralPath (Join-Path $work 'winget\packages.txt') -Value 'second.Pkg@1.0.0'

        $stateDir = Join-Path $TestDrive 'state-mixed'
        Add-OSyncStateRecord -Category winget -Name '7zip.7zip' -Version '26.02' -Sha256 $script:goldenSha -StateDir $stateDir | Out-Null

        $report = Invoke-OSyncWingetApply -WorkDir $work -Config (& $script:NewConfig $stateDir)

        $report.skipped.Count | Should -Be 1
        $report.skipped[0].Id | Should -Be '7zip.7zip'
        $report.ok.Count | Should -Be 1
        $report.ok[0].Id | Should -Be 'second.Pkg'
        $report.failed.Count | Should -Be 0
        Should -Invoke Invoke-OSyncWingetInstall -Times 1 -Scope It
    }
}

Describe 'WingetApply: inline Dependencies stripping' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Winget.Common.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
    }

    It 'Remove-OSyncWingetDependencies extracts deps and strips the block (indented Dependencies)' {
        $yaml = @'
PackageIdentifier: RequiresDep
PackageVersion: 1.0.0
Installers:
  - Architecture: x64
    InstallerType: wix
    InstallerUrl: http://127.0.0.1:8788/installer.msi
    InstallerSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    Dependencies:
      PackageDependencies:
        - PackageIdentifier: Microsoft.DotNet.Runtime.8
          MinimumVersion: 8.0.0
        - PackageIdentifier: Microsoft.VCRedist.2015+
ManifestType: merged
ManifestVersion: 1.12.0
'@
        $result = Remove-OSyncWingetDependencies -YamlText $yaml
        $result.Dependencies.Count | Should -Be 2
        $result.Dependencies[0] | Should -Be 'Microsoft.DotNet.Runtime.8'
        $result.Dependencies[1] | Should -Be 'Microsoft.VCRedist.2015+'
        # The Dependencies block must be gone at ANY indentation level.
        $result.CleanYaml -notmatch '(?m)^\s*Dependencies:' | Should -BeTrue
        $result.CleanYaml -match '(?m)^PackageIdentifier: RequiresDep' | Should -BeTrue
        $result.CleanYaml -match '(?m)^ManifestType: merged' | Should -BeTrue
    }

    It 'returns unchanged YAML when there is no Dependencies section' {
        $yaml = @'
PackageIdentifier: NoDeps
PackageVersion: 1.0.0
Installers:
  - Architecture: x64
    InstallerType: wix
    InstallerUrl: http://127.0.0.1:8788/installer.msi
    InstallerSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ManifestType: merged
ManifestVersion: 1.12.0
'@
        $result = Remove-OSyncWingetDependencies -YamlText $yaml
        $result.Dependencies.Count | Should -Be 0
        $result.CleanYaml | Should -Be $yaml
    }

    It 'stages a YAML that had Dependencies stripped from it (staging integration)' {
        $work = Join-Path $TestDrive 'work-dep-strip'
        $pkgDir = Join-Path $work 'winget\RequiresDep.Demo'
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null
        # Dependencies is indented at 4 spaces, as it appears under an Installers list item.
        [System.IO.File]::WriteAllText((Join-Path $pkgDir 'RequiresDep_1.0.0.yaml'),
            "PackageIdentifier: RequiresDep.Demo`nPackageVersion: 1.0.0`nInstallers:`n  - Architecture: x64`n    InstallerType: wix`n    InstallerUrl: http://127.0.0.1:8788/installer.msi`n    InstallerSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n    Dependencies:`n      PackageDependencies:`n        - PackageIdentifier: Some.Dep`nManifestType: merged`nManifestVersion: 1.12.0",
            (New-Object System.Text.UTF8Encoding($true)))

        $stagingRoot = Join-Path $TestDrive 'staging-dep'
        $dir = New-OSyncWingetManifestStaging -PackageDir $pkgDir -StagingRoot $stagingRoot

        $staged = Get-ChildItem -LiteralPath $dir -Filter '*.yaml' -File
        $staged.Count | Should -Be 1
        $text = [System.IO.File]::ReadAllText($staged[0].FullName, [System.Text.Encoding]::UTF8)
        # Dependencies: must be gone at any indentation level.
        $text -notmatch '(?m)^\s*Dependencies:' | Should -BeTrue
        $text -match '(?m)^PackageIdentifier: RequiresDep.Demo' | Should -BeTrue
        # Also verify the clean YAML is still valid (ManifestType: merged at EoF).
        $text -match '(?m)^ManifestType: merged' | Should -BeTrue
        # Verify no stray "Dependencies:" key survives anywhere in the output.
        $text -match '(?m)^\s*Dependencies:' | Should -BeExactly $false
    }
}