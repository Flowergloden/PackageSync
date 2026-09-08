#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\WingetExport.ps1.

.DESCRIPTION
    Golden YAML rewrite tests (real captured winget download manifest +
    synthetic multi-installer fixture), leak assertion tests, packages.txt
    filtering, and export-loop behavior driven through a FAKE winget (a .cmd
    stub that seeds fixture files into the per-package download directory).
    NO network is touched by any test.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\WingetExport.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes, so helper functions
    are defined INSIDE BeforeAll and data is shared via $script: scope.
#>

Describe 'WingetExport: URL building and percent-encoding' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
    }

    It 'percent-encodes space, # and + in a path segment' {
        ConvertTo-OSyncUrlPathSegment -Segment 'Sample App#1+v2.exe' |
            Should -Be 'Sample%20App%231%2Bv2.exe'
    }

    It 'keeps unreserved characters (dots, dashes, underscores) untouched' {
        ConvertTo-OSyncUrlPathSegment -Segment 'plain-name_1.0.0.msi' |
            Should -Be 'plain-name_1.0.0.msi'
    }

    It 'builds the localhost URL for a nested Dependencies file with forward slashes' {
        Get-OSyncWingetLocalUrl -RelativePath 'Dependencies\Sample Dep_2.0.0_Machine_X64_msi_en-US.msi' `
            -Id 'synthetic.SampleApp' -HttpBind '127.0.0.1' -HttpPort 8788 |
            Should -Be 'http://127.0.0.1:8788/winget/synthetic.SampleApp/Dependencies/Sample%20Dep_2.0.0_Machine_X64_msi_en-US.msi'
    }
}

Describe 'WingetExport: golden rewrite of the real captured 7zip manifest' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')

        $script:goldSrc = Join-Path $PSScriptRoot 'fixtures\winget\7zip.7zip'
        $script:goldDir = Join-Path $TestDrive '7zip.7zip'
        Copy-Item -Recurse -Force -LiteralPath $script:goldSrc -Destination $script:goldDir

        # The real installer binary is not committed; create an empty sibling
        # with the observed stem so the stem-mapping rule finds it.
        $script:goldInstaller = Join-Path $script:goldDir '7-Zip_26.02_Machine_X64_wix_zh-CN.msi'
        [System.IO.File]::WriteAllBytes($script:goldInstaller, [byte[]]@(1, 2, 3))

        $script:goldYaml = Join-Path $script:goldDir '7-Zip_26.02_Machine_X64_wix_zh-CN.yaml'
        $script:goldOriginal = [System.IO.File]::ReadAllText($script:goldYaml, [System.Text.Encoding]::UTF8)
    }

    It 'rewrites the InstallerUrl to the localhost URL whose path matches the on-disk filename' {
        $rewritten = ConvertTo-OSyncWingetYamlContent -YamlPath $script:goldYaml -IdDir $script:goldDir `
            -Id '7zip.7zip' -HttpBind '127.0.0.1' -HttpPort 8788

        $rewritten -match '(?m)^  InstallerUrl: http://127\.0\.0\.1:8788/winget/7zip\.7zip/7-Zip_26\.02_Machine_X64_wix_zh-CN\.msi\s*$' |
            Should -BeTrue
    }

    It 'never touches InstallerSha256' {
        $rewritten = [System.IO.File]::ReadAllText($script:goldYaml, [System.Text.Encoding]::UTF8)
        $rewritten -match '(?m)^  InstallerSha256: db407a4f6d4999e5c7bc00ce8a882be94717b56e7fa68140fe3f12605d91643e\s*$' |
            Should -BeTrue
    }

    It 'leaves non-installer URLs (DocumentUrl, PackageUrl) untouched' {
        $rewritten = [System.IO.File]::ReadAllText($script:goldYaml, [System.Text.Encoding]::UTF8)
        $rewritten -match 'DocumentUrl: https://7-zip\.org/faq\.html' | Should -BeTrue
        $rewritten -match 'PackageUrl: https://7-zip\.org/download\.html' | Should -BeTrue
    }

    It 'has exactly one installer URL after rewrite (the merged manifest single Installer node)' {
        $rewritten = [System.IO.File]::ReadAllText($script:goldYaml, [System.Text.Encoding]::UTF8)
        @(Get-OSyncWingetYamlUrls -Text $rewritten).Count | Should -Be 1
    }

    It 'leak assertion: original (external github URL) fails, rewritten passes' {
        Test-OSyncWingetYamlNoLeak -Text $script:goldOriginal | Should -BeFalse

        $rewritten = [System.IO.File]::ReadAllText($script:goldYaml, [System.Text.Encoding]::UTF8)
        Test-OSyncWingetYamlNoLeak -Text $rewritten | Should -BeTrue
    }
}

Describe 'WingetExport: synthetic multi-installer fixture (incl. Dependencies and FallbackUrls)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')

        $script:synSrc = Join-Path $PSScriptRoot 'fixtures\winget\synthetic.SampleApp'
        $script:synDir = Join-Path $TestDrive 'synthetic.SampleApp'
        Copy-Item -Recurse -Force -LiteralPath $script:synSrc -Destination $script:synDir

        $script:synYaml = Join-Path $script:synDir 'Sample App_1.0.0_Machine_X64_exe_en-US.yaml'
        $script:synDepYaml = Join-Path $script:synDir 'Dependencies\Sample Dep_2.0.0_Machine_X64_msi_en-US.yaml'
        $script:synOriginal = [System.IO.File]::ReadAllText($script:synYaml, [System.Text.Encoding]::UTF8)
        $script:synLocal = 'http://127.0.0.1:8788/winget/synthetic.SampleApp/Sample%20App_1.0.0_Machine_X64_exe_en-US.exe'
    }

    It 'extracts 5 installer URLs from the original (3 InstallerUrl + 2 InstallerFallbackUrls items)' {
        @(Get-OSyncWingetYamlUrls -Text $script:synOriginal).Count | Should -Be 5
    }

    It 'replaces ALL InstallerUrl scalars and ALL InstallerFallbackUrls list items' {
        $rewritten = ConvertTo-OSyncWingetYamlContent -YamlPath $script:synYaml -IdDir $script:synDir `
            -Id 'synthetic.SampleApp' -HttpBind '127.0.0.1' -HttpPort 8788

        $urls = @(Get-OSyncWingetYamlUrls -Text $rewritten)
        $urls.Count | Should -Be 5
        @($urls | Where-Object { $_ -ne $script:synLocal }).Count | Should -Be 0

        # No external installer URL may remain anywhere in the file.
        $rewritten -match 'cdn\.example\.com' | Should -BeFalse
        $rewritten -match 'fallback[12]\.example\.com' | Should -BeFalse
    }

    It 'preserves every InstallerSha256 byte-identical' {
        $rewritten = [System.IO.File]::ReadAllText($script:synYaml, [System.Text.Encoding]::UTF8)
        foreach ($hex in @(
                '1111111111111111111111111111111111111111111111111111111111111111',
                '2222222222222222222222222222222222222222222222222222222222222222',
                '3333333333333333333333333333333333333333333333333333333333333333')) {
            $rewritten -match $hex | Should -BeTrue
        }
    }

    It 'rewrites the Dependencies subdirectory manifest with a Dependencies path segment' {
        $dep = ConvertTo-OSyncWingetYamlContent -YamlPath $script:synDepYaml -IdDir $script:synDir `
            -Id 'synthetic.SampleApp' -HttpBind '127.0.0.1' -HttpPort 8788

        $dep -match '(?m)^  InstallerUrl: http://127\.0\.0\.1:8788/winget/synthetic\.SampleApp/Dependencies/Sample%20Dep_2\.0\.0_Machine_X64_msi_en-US\.msi\s*$' |
            Should -BeTrue
        Test-OSyncWingetYamlNoLeak -Text $dep | Should -BeTrue
    }

    It 'leak assertion: original synthetic fails, rewritten synthetic passes' {
        Test-OSyncWingetYamlNoLeak -Text $script:synOriginal | Should -BeFalse
        $rewritten = [System.IO.File]::ReadAllText($script:synYaml, [System.Text.Encoding]::UTF8)
        Test-OSyncWingetYamlNoLeak -Text $rewritten | Should -BeTrue
    }

    It 'rewrites flow-style InstallerFallbackUrls: [a, b] sequences too' {
        $flowDir = Join-Path $TestDrive 'flow.Test'
        New-Item -ItemType Directory -Path $flowDir -Force | Out-Null
        $flowYaml = Join-Path $flowDir 'Flow_1.0.0_Machine_X64_exe_en-US.yaml'
        $flowText = @(
            'PackageIdentifier: flow.Test',
            'PackageVersion: 1.0.0',
            'Installers:',
            '- Architecture: x64',
            '  InstallerType: exe',
            '  InstallerUrl: https://c.example/Flow_1.0.0_Machine_X64_exe_en-US.exe',
            "  InstallerFallbackUrls: ['https://a.example/flow.exe', ""https://b.example/flow2.exe""]",
            '  InstallerSha256: 6666666666666666666666666666666666666666666666666666666666666666'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($flowYaml, $flowText, (New-Object System.Text.UTF8Encoding($true)))
        [System.IO.File]::WriteAllBytes((Join-Path $flowDir 'Flow_1.0.0_Machine_X64_exe_en-US.exe'), [byte[]]@(9))

        $rewritten = ConvertTo-OSyncWingetYamlContent -YamlPath $flowYaml -IdDir $flowDir `
            -Id 'flow.Test' -HttpBind '127.0.0.1' -HttpPort 8788

        $urls = @(Get-OSyncWingetYamlUrls -Text $rewritten)
        $urls.Count | Should -Be 3
        @($urls | Where-Object { $_ -ne 'http://127.0.0.1:8788/winget/flow.Test/Flow_1.0.0_Machine_X64_exe_en-US.exe' }).Count |
            Should -Be 0
    }

    It 'throws when a manifest has no sibling installer file (cannot map -> no rewrite)' {
        $brokenSrc = Join-Path $PSScriptRoot 'fixtures\winget\synthetic.BrokenManifest'
        $brokenDir = Join-Path $TestDrive 'synthetic.BrokenManifest'
        Copy-Item -Recurse -Force -LiteralPath $brokenSrc -Destination $brokenDir

        { ConvertTo-OSyncWingetYamlContent -YamlPath (Join-Path $brokenDir 'Broken.yaml') `
                -IdDir $brokenDir -Id 'synthetic.BrokenManifest' -HttpBind '127.0.0.1' -HttpPort 8788 } |
            Should -Throw -ExpectedMessage '*no on-disk installer*'
    }
}

Describe 'WingetExport: packages.txt content (only successful IDs)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')

        $script:pkgList = @(
            [pscustomobject]@{ Id = '7zip.7zip'; Version = '26.02'; Line = 1 },
            [pscustomobject]@{ Id = 'Foo.Bar999'; Version = $null; Line = 2 },
            [pscustomobject]@{ Id = 'OpenJS.NodeJS.LTS'; Version = $null; Line = 3 }
        )
    }

    It 'writes pinned successful IDs as Id@version and drops failed IDs' {
        $lines = @(Get-OSyncWingetPackagesTxtContent -ParsedList $script:pkgList -OkIds @('7zip.7zip', 'OpenJS.NodeJS.LTS'))
        $lines.Count | Should -Be 2
        $lines[0] | Should -Be '7zip.7zip@26.02'
        $lines[1] | Should -Be 'OpenJS.NodeJS.LTS'
        ($lines -join "`n") -match 'Foo\.Bar999' | Should -BeFalse
    }

    It 'writes unpinned successful IDs as bare Id and writes nothing when all failed' {
        $lines = @(Get-OSyncWingetPackagesTxtContent -ParsedList $script:pkgList -OkIds @('OpenJS.NodeJS.LTS'))
        $lines.Count | Should -Be 1
        $lines[0] | Should -Be 'OpenJS.NodeJS.LTS'

        @(Get-OSyncWingetPackagesTxtContent -ParsedList $script:pkgList -OkIds @()).Count | Should -Be 0
    }
}

Describe 'WingetExport: export loop with a fake winget (no network)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')

        $script:synFix = Join-Path $PSScriptRoot 'fixtures\winget\synthetic.SampleApp'
        $script:brokenFix = Join-Path $PSScriptRoot 'fixtures\winget\synthetic.BrokenManifest'

        # Fake winget: a .cmd stub. Contract with Invoke-OSyncWingetDownload:
        # --download-directory <quoted path> is the LAST argument. The stub
        # seeds the fixture files into that directory, fails with exit 1 for
        # Foo.Bar999, and exits 0 for anything that is not a download call.
        $script:fakeWinget = Join-Path $TestDrive 'fakewinget.cmd'
        $fakeContent = @(
            '@echo off',
            'set DIR=',
            'echo %*| findstr /C:"download" >nul',
            'if errorlevel 1 exit /b 0',
            'for %%A in (%*) do set DIR=%%~A',
            'echo %*| findstr /C:"Foo.Bar999" >nul',
            'if not errorlevel 1 exit /b 1',
            'echo %*| findstr /C:"synthetic.BrokenManifest" >nul',
            'if not errorlevel 1 goto broken',
            'if not exist "%DIR%" mkdir "%DIR%"',
            "xcopy /E /I /Y `"$($script:synFix)\*`" `"%DIR%`" >nul",
            'exit /b 0',
            ':broken',
            'if not exist "%DIR%" mkdir "%DIR%"',
            "xcopy /E /I /Y `"$($script:brokenFix)\*`" `"%DIR%`" >nul",
            'exit /b 0'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($script:fakeWinget, $fakeContent, [System.Text.Encoding]::ASCII)

        $script:testConfig = [pscustomobject]@{
            role     = 'A'
            repoRoot = (Join-Path $TestDrive 'repo')
            stateDir = 'C:\ProgramData\PakageSync'
            httpBind = '127.0.0.1'
            httpPort = 8788
            winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
        }
    }

    It 'records Foo.Bar999 in failed, continues with the next package, and writes only successful IDs to packages.txt' {
        $staging = Join-Path $TestDrive 'staging'
        $list = @(
            [pscustomobject]@{ Id = 'Foo.Bar999'; Version = $null; Line = 1 },
            [pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = '1.0.0'; Line = 2 }
        )

        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $script:testConfig -WingetExePath $script:fakeWinget

        $report.failed.Count | Should -Be 1
        $report.failed[0].Id | Should -Be 'Foo.Bar999'
        $report.failed[0].ExitCode | Should -Be 1

        $report.ok.Count | Should -Be 1
        $report.ok[0].Id | Should -Be 'synthetic.SampleApp'

        # Later package was processed despite the earlier failure.
        $stagedYaml = Join-Path $staging 'winget\synthetic.SampleApp\Sample App_1.0.0_Machine_X64_exe_en-US.yaml'
        Test-Path -LiteralPath $stagedYaml | Should -BeTrue
        $stagedText = [System.IO.File]::ReadAllText($stagedYaml, [System.Text.Encoding]::UTF8)
        Test-OSyncWingetYamlNoLeak -Text $stagedText | Should -BeTrue

        # packages.txt contains ONLY the successful ID.
        $packagesTxt = [System.IO.File]::ReadAllText((Join-Path $staging 'winget\packages.txt'), [System.Text.Encoding]::UTF8)
        $packagesTxt.Trim() | Should -Be 'synthetic.SampleApp@1.0.0'

        # Export report JSON exists and parses.
        $reportJson = [System.IO.File]::ReadAllText((Join-Path $staging 'winget\export-report.json'), [System.Text.Encoding]::UTF8)
        $parsed = $reportJson | ConvertFrom-Json
        $parsed.category | Should -Be 'winget'
        $parsed.failed.Count | Should -Be 1
    }

    It 'fails the WHOLE export (throws) when a manifest cannot be rewritten/leak-asserted' {
        $staging = Join-Path $TestDrive 'staging-broken'
        $list = @(
            [pscustomobject]@{ Id = 'synthetic.BrokenManifest'; Version = $null; Line = 1 }
        )

        { Export-OSyncWinget -ParsedList $list -StagingDir $staging `
                -Config $script:testConfig -WingetExePath $script:fakeWinget } |
            Should -Throw -ExpectedMessage '*synthetic.BrokenManifest*'
    }
}

Describe 'WingetExport: incremental reuse of unchanged pinned packages (P1)' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\WingetExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\RepoContract.ps1')

        $script:synFix = Join-Path $PSScriptRoot 'fixtures\winget\synthetic.SampleApp'

        # Fake winget that FAILS every download: a successful export with this
        # stub proves the payload came from reuse, not from `winget download`.
        $script:fakeFailAll = Join-Path $TestDrive 'fakewinget-failall.cmd'
        [System.IO.File]::WriteAllText($script:fakeFailAll,
            "@echo off`r`necho %*| findstr /C:`"download`" >nul`r`nif errorlevel 1 exit /b 0`r`nexit /b 1",
            [System.Text.Encoding]::ASCII)

        # Fake winget that seeds the synthetic fixture into the download dir.
        $script:fakeOk = Join-Path $TestDrive 'fakewinget-ok.cmd'
        $okContent = @(
            '@echo off',
            'set DIR=',
            'echo %*| findstr /C:"download" >nul',
            'if errorlevel 1 exit /b 0',
            'for %%A in (%*) do set DIR=%%~A',
            'if not exist "%DIR%" mkdir "%DIR%"',
            "xcopy /E /I /Y `"$($script:synFix)\*`" `"%DIR%`" >nul",
            'exit /b 0'
        ) -join "`r`n"
        [System.IO.File]::WriteAllText($script:fakeOk, $okContent, [System.Text.Encoding]::ASCII)

        # Builds a "previous published repo" for synthetic.SampleApp@1.0.0:
        # fixture payload, URLs rewritten to 127.0.0.1:8788, winget\files.json.
        $script:NewPrevRepo = {
            param([string]$RepoRoot)
            $wingetDir = Join-Path $RepoRoot 'winget'
            New-Item -ItemType Directory -Path $wingetDir -Force | Out-Null
            $pkgDir = Join-Path $wingetDir 'synthetic.SampleApp'
            Copy-Item -Recurse -Force -LiteralPath $script:synFix -Destination $pkgDir
            Get-ChildItem -LiteralPath $pkgDir -Recurse -Filter '*.yaml' -File | ForEach-Object {
                ConvertTo-OSyncWingetYamlContent -YamlPath $_.FullName -IdDir $pkgDir `
                    -Id 'synthetic.SampleApp' -HttpBind '127.0.0.1' -HttpPort 8788 | Out-Null
            }
            New-OSyncFilesManifest -Dir $wingetDir | Out-Null
        }

        $script:NewReuseConfig = {
            param([string]$RepoRoot, [int]$Port = 8788)
            return [pscustomobject]@{
                role     = 'A'
                repoRoot = $RepoRoot
                stateDir = 'C:\ProgramData\PakageSync'
                httpBind = '127.0.0.1'
                httpPort = $Port
                winget   = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' }
            }
        }
    }

    It 'reuses the previous payload when the pinned version is unchanged (works even with a dead winget)' {
        $repo = Join-Path $TestDrive 'repo-reuse'
        & $script:NewPrevRepo $repo
        $cfg = & $script:NewReuseConfig $repo
        $staging = Join-Path $TestDrive 'staging-reuse'
        $list = @([pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = '1.0.0'; Line = 1 })

        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $cfg -WingetExePath $script:fakeFailAll

        $report.ok.Count | Should -Be 1
        $report.reused.Count | Should -Be 1
        $report.reused[0].Id | Should -Be 'synthetic.SampleApp'
        $report.failed.Count | Should -Be 0

        # Payload staged verbatim (top-level YAML + Dependencies installer).
        $stagedYaml = Join-Path $staging 'winget\synthetic.SampleApp\Sample App_1.0.0_Machine_X64_exe_en-US.yaml'
        Test-Path -LiteralPath $stagedYaml | Should -BeTrue
        Test-OSyncWingetYamlNoLeak -Text ([System.IO.File]::ReadAllText($stagedYaml, [System.Text.Encoding]::UTF8)) | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $staging 'winget\synthetic.SampleApp\Dependencies\Sample Dep_2.0.0_Machine_X64_msi_en-US.msi') | Should -BeTrue

        # Reused IDs still land in packages.txt.
        $packagesTxt = [System.IO.File]::ReadAllText((Join-Path $staging 'winget\packages.txt'), [System.Text.Encoding]::UTF8)
        $packagesTxt.Trim() | Should -Be 'synthetic.SampleApp@1.0.0'
    }

    It 'falls back to download when the pinned version changed' {
        $repo = Join-Path $TestDrive 'repo-ver'
        & $script:NewPrevRepo $repo
        $cfg = & $script:NewReuseConfig $repo
        $staging = Join-Path $TestDrive 'staging-ver'
        $list = @([pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = '2.0.0'; Line = 1 })

        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $cfg -WingetExePath $script:fakeOk

        $report.reused.Count | Should -Be 0
        $report.ok.Count | Should -Be 1
        $report.failed.Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $staging 'winget\synthetic.SampleApp\Sample App_1.0.0_Machine_X64_exe_en-US.yaml') | Should -BeTrue
    }

    It 'never reuses an UNPINNED entry even when a previous payload exists' {
        $repo = Join-Path $TestDrive 'repo-unpinned'
        & $script:NewPrevRepo $repo
        $cfg = & $script:NewReuseConfig $repo
        $staging = Join-Path $TestDrive 'staging-unpinned'
        $list = @([pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = $null; Line = 1 })

        # failall stub: the download MUST be attempted (and therefore fails).
        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $cfg -WingetExePath $script:fakeFailAll

        $report.ok.Count | Should -Be 0
        $report.reused.Count | Should -Be 0
        $report.failed.Count | Should -Be 1
    }

    It 'falls back to download when the previous payload is corrupted (files.json hash mismatch)' {
        $repo = Join-Path $TestDrive 'repo-corrupt'
        & $script:NewPrevRepo $repo
        # Flip a byte in the installer AFTER files.json was written.
        $exe = Join-Path $repo 'winget\synthetic.SampleApp\Sample App_1.0.0_Machine_X64_exe_en-US.exe'
        $bytes = [System.IO.File]::ReadAllBytes($exe)
        $bytes[0] = ($bytes[0] -bxor 0xFF)
        [System.IO.File]::WriteAllBytes($exe, $bytes)

        $cfg = & $script:NewReuseConfig $repo
        $staging = Join-Path $TestDrive 'staging-corrupt'
        $list = @([pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = '1.0.0'; Line = 1 })

        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $cfg -WingetExePath $script:fakeFailAll

        $report.ok.Count | Should -Be 0
        $report.reused.Count | Should -Be 0
        $report.failed.Count | Should -Be 1
    }

    It 'falls back to download when config.httpPort changed (baked URLs decoupled)' {
        $repo = Join-Path $TestDrive 'repo-port'
        & $script:NewPrevRepo $repo
        $cfg = & $script:NewReuseConfig $repo 9999
        $staging = Join-Path $TestDrive 'staging-port'
        $list = @([pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = '1.0.0'; Line = 1 })

        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $cfg -WingetExePath $script:fakeOk

        $report.reused.Count | Should -Be 0
        $report.ok.Count | Should -Be 1
        $stagedYaml = Join-Path $staging 'winget\synthetic.SampleApp\Sample App_1.0.0_Machine_X64_exe_en-US.yaml'
        ([System.IO.File]::ReadAllText($stagedYaml, [System.Text.Encoding]::UTF8)) -match ':9999/' | Should -BeTrue
    }

    It 'first run (no previous repo at all) downloads normally' {
        $repo = Join-Path $TestDrive 'repo-firstrun'   # never created
        $cfg = & $script:NewReuseConfig $repo
        $staging = Join-Path $TestDrive 'staging-firstrun'
        $list = @([pscustomobject]@{ Id = 'synthetic.SampleApp'; Version = '1.0.0'; Line = 1 })

        $report = Export-OSyncWinget -ParsedList $list -StagingDir $staging `
            -Config $cfg -WingetExePath $script:fakeOk

        $report.reused.Count | Should -Be 0
        $report.ok.Count | Should -Be 1
        $report.failed.Count | Should -Be 0
    }
}
