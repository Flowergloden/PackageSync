#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\Bootstrap.ps1 (plan todo 12).

.DESCRIPTION
    Covers the step-decision logic (idempotent skips, per-piece version
    gates), the repository-integrity subset precondition, the work-copy
    re-verification, the VC_redist acceptable-exit-code policy, the
    LocalManifestFiles enable detection, the runtime-winget exit-code policy,
    the Verdaccio task registration, the stateDir ACL layout, the WhatIf
    zero-change guarantee, the apply.lock helpers and the "failure keeps
    state.bootstrapped=false" invariant. NO network, NO elevation, NO real
    winget/Add-AppxPackage and NO writes outside $TestDrive.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\Bootstrap.Tests.ps1 -PassThru"
      pwsh -NoProfile -Command "Invoke-Pester tests\Bootstrap.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes, so helpers are
    defined INSIDE BeforeAll and data shared via $script: scope.
#>

Describe 'Bootstrap: repository-integrity subset precondition' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

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
            }
            foreach ($k in $Overrides.Keys) { $cfg.$k = $Overrides[$k] }
            return $cfg
        }

        # Builds a real mini repository (files.json + index.json via the real
        # trust-root functions) under <Root>. -Categories selects which
        # category dirs are created.
        $script:NewRepo = {
            param([string]$Root, [string[]]$Categories = @('runtime', 'winget', 'npm'))
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            foreach ($cat in $Categories) {
                $catDir = Join-Path $Root $cat
                New-Item -ItemType Directory -Path $catDir -Force | Out-Null
                if ($cat -eq 'runtime') {
                    New-Item -ItemType Directory -Path (Join-Path $catDir 'appinstaller') -Force | Out-Null
                    [System.IO.File]::WriteAllText((Join-Path $catDir 'runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
                    [System.IO.File]::WriteAllBytes((Join-Path $catDir 'appinstaller\VC_redist.x64.exe'), [byte[]]@(1, 2, 3))
                }
                elseif ($cat -eq 'winget') {
                    New-Item -ItemType Directory -Path (Join-Path $catDir 'Python.Python.3.12') -Force | Out-Null
                    [System.IO.File]::WriteAllText((Join-Path $catDir 'packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
                    [System.IO.File]::WriteAllText((Join-Path $catDir 'Python.Python.3.12\p.yaml'), "PackageVersion: 3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
                }
                elseif ($cat -eq 'npm') {
                    [System.IO.File]::WriteAllText((Join-Path $catDir 'packages.txt'), "is-odd@3.0.1`r`n", (New-Object System.Text.UTF8Encoding($true)))
                    [System.IO.File]::WriteAllText((Join-Path $catDir 'verdaccio-b.yml'), "storage: ./storage`r`npackages:`r`n  '**':`r`n    access: `$all`r`n", (New-Object System.Text.UTF8Encoding($true)))
                }
                $null = New-OSyncFilesManifest -Dir $catDir
            }
            $null = Publish-OSyncIndex -StagingDir $Root
        }
    }

    It 'passes when every required category is OK and disables skip npm' {
        $repo = Join-Path $TestDrive 'repo-ok'
        & $script:NewRepo $repo @('runtime', 'winget')      # no npm dir at all
        $cfg = & $script:NewConfig (Join-Path $TestDrive 's1') @{ categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $false; dotfiles = $true } }

        $result = Test-OSyncBootstrapRepoCategories -Config $cfg -RepoRoot $repo

        $result.Overall | Should -Be 'OK'
        $result.Categories['runtime'].Status | Should -Be 'OK'
        $result.Categories['winget'].Status | Should -Be 'OK'
    }

    It 'throws when a required category is Incomplete' {
        $repo = Join-Path $TestDrive 'repo-bad'
        & $script:NewRepo $repo @('runtime', 'winget')
        # Corrupt a manifest-listed file AFTER publishing -> winget Incomplete.
        [System.IO.File]::WriteAllText((Join-Path $repo 'winget\packages.txt'), "tampered`r`n")
        $cfg = & $script:NewConfig (Join-Path $TestDrive 's2')

        $err = $null
        try { Test-OSyncBootstrapRepoCategories -Config $cfg -RepoRoot $repo } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*winget*'
    }

    It 'throws when the trust root is invalid' {
        $repo = Join-Path $TestDrive 'repo-invalid'
        New-Item -ItemType Directory -Path $repo -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $repo 'index.json'), 'not json{')
        $cfg = & $script:NewConfig (Join-Path $TestDrive 's3')

        $err = $null
        try { Test-OSyncBootstrapRepoCategories -Config $cfg -RepoRoot $repo } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*INVALID*'
    }

    It 'work copy: copies only required categories and re-verifies hashes' {
        $repo = Join-Path $TestDrive 'repo-wc'
        & $script:NewRepo $repo @('runtime', 'winget', 'npm')
        $cfg = & $script:NewConfig (Join-Path $TestDrive 's4') @{ categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $false; dotfiles = $true } }

        $bw = New-OSyncBootstrapWorkCopy -Config $cfg -RepoRoot $repo -ExportedAtUtc '20260907T000000Z'

        (Test-Path -LiteralPath (Join-Path $bw 'runtime') -PathType Container) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $bw 'winget') -PathType Container) | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $bw 'npm') -PathType Container) | Should -Be $false
        Test-OSyncBootstrapWorkCopy -Bw $bw | Should -Be $true
    }

    It 'work copy re-verification fails after a file is tampered' {
        $repo = Join-Path $TestDrive 'repo-wc2'
        & $script:NewRepo $repo @('runtime', 'winget')
        $cfg = & $script:NewConfig (Join-Path $TestDrive 's5')
        $bw = New-OSyncBootstrapWorkCopy -Config $cfg -RepoRoot $repo -ExportedAtUtc '20260907T010000Z'

        [System.IO.File]::WriteAllBytes((Join-Path $bw 'runtime\appinstaller\VC_redist.x64.exe'), [byte[]]@(9, 9, 9))

        $err = $null
        try { Test-OSyncBootstrapWorkCopy -Bw $bw | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*sha256 mismatch*'
    }
}

Describe 'Bootstrap: step 0 - VC++ runtime detection and exit-code policy' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
        # A fake VC_redist as a .cmd so & executes it and $LASTEXITCODE is set.
        $script:NewRedistCmd = {
            param([string]$Path, [int]$ExitCode)
            Set-Content -LiteralPath $Path -Value ("@echo off`r`nexit /b {0}" -f $ExitCode) -Encoding ASCII
        }
    }

    It 'skips when the VC runtime registry key is present' {
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'v0')
        $s = Invoke-OSyncBootstrapStepVcRuntime -Config $cfg -Root $TestDrive -VcRuntimePresent $true
        $s.Status | Should -Be 'skipped'
    }

    It 'WhatIf reports the planned install and runs nothing' {
        $root = Join-Path $TestDrive 'w-root'
        New-Item -ItemType Directory -Path (Join-Path $root 'runtime\appinstaller') -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $root 'runtime\appinstaller\VC_redist.x64.exe'), [byte[]]@(1))
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'v1')
        $s = Invoke-OSyncBootstrapStepVcRuntime -Config $cfg -Root $root -VcRuntimePresent $false -WhatIf
        $s.Status | Should -Be 'done'
        $s.Message | Should -BeLike '*WhatIf*'
    }

    It 'accepts exit codes 0, 3010 and 1638 as success' {
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'v2')
        foreach ($code in @(0, 3010, 1638)) {
            $fake = Join-Path $TestDrive ("redist-{0}.cmd" -f $code)
            & $script:NewRedistCmd $fake $code
            $s = Invoke-OSyncBootstrapStepVcRuntime -Config $cfg -Root $TestDrive -VcRuntimePresent $false -VcRedistExe $fake
            $s.Status | Should -Be 'done'
            $s.Message | Should -BeLike "*exit $code*"
        }
    }

    It 'fails (throws) on a non-acceptable exit code' {
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'v3')
        $fake = Join-Path $TestDrive 'redist-bad.cmd'
        & $script:NewRedistCmd $fake 5
        $err = $null
        try { Invoke-OSyncBootstrapStepVcRuntime -Config $cfg -Root $TestDrive -VcRuntimePresent $false -VcRedistExe $fake | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*exit code 5*'
    }
}

Describe 'Bootstrap: step 1 - App Installer version gates and winget.exe' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }

        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $script:ZipDir = {
            param([string]$Dir, [string]$ZipPath)
            if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
            [System.IO.Compression.ZipFile]::CreateFromDirectory($Dir, $ZipPath)
        }

        # Appx/bundle with AppxManifest.xml at the zip root.
        $script:NewAppx = {
            param([string]$Path, [string]$Name, [string]$Version)
            $dir = Join-Path $TestDrive ('bld-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $manifest = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<Package xmlns=`"http://schemas.microsoft.com/appx/manifest/foundation/windows10`"><Identity Name=`"$Name`" Version=`"$Version`" Publisher=`"CN=Microsoft`"/></Package>"
            [System.IO.File]::WriteAllText((Join-Path $dir 'AppxManifest.xml'), $manifest)
            & $script:ZipDir $dir $Path
            Remove-Item -LiteralPath $dir -Recurse -Force
        }

        # A bundle whose manifest lives ONLY inside the inner AppInstaller_x64.msix.
        $script:NewBundleInner = {
            param([string]$Path, [string]$Name, [string]$Version)
            $innerDir = Join-Path $TestDrive ('inner-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $innerDir -Force | Out-Null
            $manifest = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<Package xmlns=`"http://schemas.microsoft.com/appx/manifest/foundation/windows10`"><Identity Name=`"$Name`" Version=`"$Version`" Publisher=`"CN=Microsoft`"/></Package>"
            [System.IO.File]::WriteAllText((Join-Path $innerDir 'AppxManifest.xml'), $manifest)
            $innerMsix = Join-Path $TestDrive ('inner-' + [guid]::NewGuid().ToString('N') + '.msix')
            & $script:ZipDir $innerDir $innerMsix
            Remove-Item -LiteralPath $innerDir -Recurse -Force
            $bundleDir = Join-Path $TestDrive ('bdl-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $bundleDir -Force | Out-Null
            Copy-Item -LiteralPath $innerMsix -Destination (Join-Path $bundleDir 'AppInstaller_x64.msix')
            & $script:ZipDir $bundleDir $Path
            Remove-Item -LiteralPath $bundleDir -Recurse -Force
            Remove-Item -LiteralPath $innerMsix -Force
        }

        # Builds a runtime payload dir with the three pieces + files.json.
        $script:NewPayload = {
            param([string]$Root, [switch]$InnerBundle)
            $dir = Join-Path $Root 'runtime\appinstaller'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $dir 'VC_redist.x64.exe'), [byte[]]@(1, 2, 3))
            & $script:NewAppx (Join-Path $dir 'Microsoft.VCLibs.x64.14.00.Desktop.appx') 'Microsoft.VCLibs.140.00.UWPDesktop' '14.0.33321.0'
            & $script:NewAppx (Join-Path $dir 'Microsoft.UI.Xaml.2.8.appx') 'Microsoft.UI.Xaml.2.8' '8.2310.30001.0'
            if ($InnerBundle) {
                & $script:NewBundleInner (Join-Path $dir 'Microsoft.DesktopAppInstaller.msixbundle') 'Microsoft.DesktopAppInstaller' '1.29.290.0'
            }
            else {
                & $script:NewAppx (Join-Path $dir 'Microsoft.DesktopAppInstaller.msixbundle') 'Microsoft.DesktopAppInstaller' '1.29.290.0'
            }
            $null = New-OSyncFilesManifest -Dir (Join-Path $Root 'runtime')
        }
    }

    It 'per-piece version gate skips installed-newer pieces and installs missing ones' {
        $root = Join-Path $TestDrive 'p1'
        & $script:NewPayload $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'p1state')

        Mock Get-OSyncInstalledAppxVersion {
            param($PackageName)
            if ($PackageName -like '*VCLibs*') { return [version]'14.0.33728.0' }   # OS-shipped newer -> skip
            if ($PackageName -like '*UI.Xaml*') { return $null }                    # absent -> install
            if ($PackageName -like '*DesktopAppInstaller*') { return [version]'1.29.290.0' }  # equal -> skip
            return $null
        }

        $decisions = @(Get-OSyncAppInstallerDecisions -Config $cfg -Root $root)
        $decisions.Count | Should -Be 3
        ($decisions | Where-Object { $_.Piece -eq 'vclibs' }).InstallNeeded | Should -Be $false
        ($decisions | Where-Object { $_.Piece -eq 'uixaml' }).InstallNeeded | Should -Be $true
        ($decisions | Where-Object { $_.Piece -eq 'msixbundle' }).InstallNeeded | Should -Be $false
    }

    It 'parses the bundle version from the inner x64 msix (root-less bundle)' {
        $root = Join-Path $TestDrive 'p2'
        & $script:NewPayload $root -InnerBundle
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'p2state')
        Mock Get-OSyncInstalledAppxVersion { return $null }

        $decisions = @(Get-OSyncAppInstallerDecisions -Config $cfg -Root $root)
        $bundle = $decisions | Where-Object { $_.Piece -eq 'msixbundle' }
        $bundle.PayloadVersion | Should -Be '1.29.290.0'
        $bundle.InstallNeeded | Should -Be $true
    }

    It 'throws when a piece sha256 no longer matches files.json' {
        $root = Join-Path $TestDrive 'p3'
        & $script:NewPayload $root
        # Tamper AFTER the manifest was written (garbage bytes -> hash mismatch
        # is detected before any manifest parse attempt).
        [System.IO.File]::WriteAllBytes((Join-Path $root 'runtime\appinstaller\Microsoft.UI.Xaml.2.8.appx'), [byte[]]@(9, 9, 9))
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'p3state')

        $err = $null
        try { Get-OSyncAppInstallerDecisions -Config $cfg -Root $root | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*sha256 mismatch*'
    }

    It 'throws when a piece is missing' {
        $root = Join-Path $TestDrive 'p4'
        & $script:NewPayload $root
        Remove-Item -LiteralPath (Join-Path $root 'runtime\appinstaller\Microsoft.VCLibs.x64.14.00.Desktop.appx') -Force
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'p4state')

        $err = $null
        try { Get-OSyncAppInstallerDecisions -Config $cfg -Root $root | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*not found*'
    }

    It 'step 1 installs needed pieces in VCLibs -> UI.Xaml -> msixbundle order and records winget.exe' {
        $root = Join-Path $TestDrive 'p5'
        & $script:NewPayload $root
        $stateDir = Join-Path $TestDrive 'p5state'
        $cfg = & $script:NewConfig $stateDir

        Mock Get-OSyncInstalledAppxVersion { return $null }   # all three need install
        $script:addOrder = @()
        Mock Add-AppxPackage { param($Path) $script:addOrder += $Path }
        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }

        $s = Invoke-OSyncBootstrapStepAppInstaller -Config $cfg -Root $root

        $s.Status | Should -Be 'done'
        $script:addOrder.Count | Should -Be 3
        (Split-Path -Leaf $script:addOrder[0]) | Should -Be 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
        (Split-Path -Leaf $script:addOrder[1]) | Should -Be 'Microsoft.UI.Xaml.2.8.appx'
        (Split-Path -Leaf $script:addOrder[2]) | Should -Be 'Microsoft.DesktopAppInstaller.msixbundle'
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.wingetExePath | Should -Be 'C:\fake\winget.exe'
    }

It 'step 1 WhatIf adds nothing and records nothing' {
        $root = Join-Path $TestDrive 'p6'
        & $script:NewPayload $root
        $stateDir = Join-Path $TestDrive 'p6state'
        $cfg = & $script:NewConfig $stateDir
        Mock Get-OSyncInstalledAppxVersion { return $null }
        $script:addCount = 0
        Mock Add-AppxPackage { $script:addCount++ }
        Mock Resolve-OSyncWingetExePath { return 'C:\fake\winget.exe' }

        $s = Invoke-OSyncBootstrapStepAppInstaller -Config $cfg -Root $root -WhatIf
        $s.Status | Should -Be 'done'
        $script:addCount | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $stateDir 'state\system-state.json')) | Should -Be $false
    }

    It 'step 1 WhatIf with ALL pieces skipped still records nothing (regression)' {
        $root = Join-Path $TestDrive 'p6b'
        & $script:NewPayload $root
        $stateDir = Join-Path $TestDrive 'p6bstate'
        $cfg = & $script:NewConfig $stateDir
        # Every piece installed-newer -> all skipped -> the old code fell
        # through to the winget resolution + state write even under WhatIf.
        Mock Get-OSyncInstalledAppxVersion { return [version]'99.0.0.0' }
        $script:resolveCount = 0
        Mock Resolve-OSyncWingetExePath { $script:resolveCount++; return 'C:\fake\winget.exe' }

        $s = Invoke-OSyncBootstrapStepAppInstaller -Config $cfg -Root $root -WhatIf
        $s.Status | Should -Be 'done'
        $s.Message | Should -BeLike '*all pieces skipped*'
        $script:resolveCount | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $stateDir 'state\system-state.json')) | Should -Be $false
    }

    It 'step 1 throws explicitly when winget.exe cannot be resolved' {
        $root = Join-Path $TestDrive 'p7'
        & $script:NewPayload $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'p7state')
        Mock Get-OSyncInstalledAppxVersion { return [version]'99.0.0.0' }   # all installed-newer -> all skip
        Mock Resolve-OSyncWingetExePath { return $null }

        $err = $null
        try { Invoke-OSyncBootstrapStepAppInstaller -Config $cfg -Root $root | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*winget.exe not found*'
    }
}

Describe 'Bootstrap: step 2 - LocalManifestFiles enable detection' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
        # Fake winget .cmd that ALWAYS echoes the settings export body (the
        # detection tests only exercise `settings export`; the exit code is
        # controlled per call). Args are ignored.
        $script:NewFakeWinget = {
            param([string]$Path, [string]$ExportBody, [int]$ExportCode = 0)
            $text = "@echo off`r`n" +
                    "echo $ExportBody`r`n" +
                    "exit /b $ExportCode`r`n"
            [System.IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding($false)))
        }
    }

It 'detects enabled via adminSettings.LocalManifestFiles (real export casing)' {
        $fake = Join-Path $TestDrive 'wg1.cmd'
        & $script:NewFakeWinget $fake '{"adminSettings":{"LocalManifestFiles":true}}'
        Test-OSyncWingetLocalManifestEnabled -WingetExe $fake | Should -Be $true
    }

    It 'detects enabled case-insensitively (lowercase key also works)' {
        $fake = Join-Path $TestDrive 'wg1b.cmd'
        & $script:NewFakeWinget $fake '{"adminSettings":{"localManifestFiles":true}}'
        Test-OSyncWingetLocalManifestEnabled -WingetExe $fake | Should -Be $true
    }

    It 'returns false when the setting is disabled or absent' {
        $fake = Join-Path $TestDrive 'wg2.cmd'
        & $script:NewFakeWinget $fake '{"adminSettings":{"LocalManifestFiles":false}}'
        Test-OSyncWingetLocalManifestEnabled -WingetExe $fake | Should -Be $false
        $fake2 = Join-Path $TestDrive 'wg2b.cmd'
        & $script:NewFakeWinget $fake2 '{"userSettings":{}}'
        Test-OSyncWingetLocalManifestEnabled -WingetExe $fake2 | Should -Be $false
    }

    It 'enable verifies via export and aborts when ineffective' {
        # The enable native call needs a runnable fake; the verify step is
        # mocked to simulate the export outcome.
        $fake = Join-Path $TestDrive 'wg-enable.cmd'
        [System.IO.File]::WriteAllText($fake, "@echo off`r`nexit /b 0`r`n", (New-Object System.Text.UTF8Encoding($false)))

        Mock Test-OSyncWingetLocalManifestEnabled { return $true }
        { Enable-OSyncWingetLocalManifest -WingetExe $fake } | Should -Not -Throw

        Mock Test-OSyncWingetLocalManifestEnabled { return $false }
        $err = $null
        try { Enable-OSyncWingetLocalManifest -WingetExe $fake } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*admin_settings*'
    }

    It 'step 2 skips the admin enable when already enabled (QA exemption) and skips the SYSTEM one-shot when its marker exists' {
        $stateDir = Join-Path $TestDrive 'lm2'
        $cfg = & $script:NewConfig $stateDir
        Mock Test-OSyncWingetLocalManifestEnabled { return $true }
        # Pre-create the SYSTEM marker -> one-shot skipped.
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $stateDir 'run\winget-localmanifest-system.ok') -Value 'x' -Encoding UTF8

        $s = Invoke-OSyncBootstrapStepLocalManifest -Config $cfg -WingetExe 'C:\fake\winget.exe' -WingetSettingsTaskName 'PakageSync-WingetSettings-QA'
        $s.Status | Should -Be 'skipped'
        $s.Message | Should -BeLike '*already enabled*'
    }

    It 'SYSTEM one-shot: WhatIf registers nothing' {
        $stateDir = Join-Path $TestDrive 'lm3'
        $cfg = & $script:NewConfig $stateDir
        $script:regCount = 0
        Mock Register-ScheduledTask { $script:regCount++ }
        Mock Start-ScheduledTask { }
        Mock Get-ScheduledTask { return $null }

        $s = Register-OSyncWingetSettingsSystemOneShot -Config $cfg -WingetExe 'C:\fake\winget.exe' -TaskName 'PakageSync-WingetSettings-QA' -WhatIf
        $s.Status | Should -Be 'done'
        $s.Message | Should -BeLike '*WhatIf*'
        $script:regCount | Should -Be 0
    }

    It 'SYSTEM one-shot registers, runs and reports a missing marker as a warning' {
        $stateDir = Join-Path $TestDrive 'lm4'
        $cfg = & $script:NewConfig $stateDir
        $script:regCount = 0
        Mock Register-ScheduledTask { $script:regCount++ }
        Mock Start-ScheduledTask { }
        # Task self-deletes immediately: Get-ScheduledTask always returns $null.
        Mock Get-ScheduledTask { return $null }

        $warning = $null
        $s = Register-OSyncWingetSettingsSystemOneShot -Config $cfg -WingetExe 'C:\fake\winget.exe' -TaskName 'PakageSync-WingetSettings-QA' -WarningVariable warning

        $script:regCount | Should -Be 1
        $s.Status | Should -Be 'done'
        $s.Data.Leftover | Should -Be $false
        (Test-Path -LiteralPath (Join-Path $stateDir 'bin\enable-winget-localmanifest.ps1')) | Should -Be $true
    }
}

Describe 'Bootstrap: step 3 - runtime winget exit-code policy and PATH recording' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
        $script:NewWork = {
            param([string]$Root, [string[]]$Ids = @('Python.Python.3.12'))
            New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $Root 'winget') -Force | Out-Null
            $lines = @()
            foreach ($id in $Ids) { $lines += "$id@1.0.0" }
            [System.IO.File]::WriteAllText((Join-Path $Root 'runtime\runtime-winget.txt'), ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
            foreach ($id in $Ids) {
                $pkg = Join-Path $Root ('winget\{0}' -f $id)
                New-Item -ItemType Directory -Path $pkg -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $pkg 'manifest.yaml'), "PackageVersion: 1.0.0`r`nInstallerSha256: 1111111111111111111111111111111111111111111111111111111111111111`r`n", (New-Object System.Text.UTF8Encoding($true)))
            }
        }
    }

    It 'installs each runtime entry; exit 0 = ok and python/node paths are recorded' {
        $root = Join-Path $TestDrive 'r1'
        & $script:NewWork $root
        $stateDir = Join-Path $TestDrive 'r1state'
        $cfg = & $script:NewConfig $stateDir
        $script:mockExit = 0
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall { return [pscustomobject]@{ ExitCode = $script:mockExit; TimedOut = $false; Output = 'mocked' } }
        Mock Resolve-OSyncApplyPython { return 'C:\Python312\python.exe' }
        Mock Resolve-OSyncNodeInstallDir { return 'C:\Program Files\nodejs' }

        $s = Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe'

        $s.Status | Should -Be 'done'
        $s.Data.Installed.Count | Should -Be 1
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.pythonExePath | Should -Be 'C:\Python312\python.exe'
        $state.nodeExePath | Should -Be 'C:\Program Files\nodejs\node.exe'
    }

    It 'a satisfied (non-zero) exit code in WingetSatisfiedExitCodes is ok' {
        $root = Join-Path $TestDrive 'r2'
        & $script:NewWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'r2state')
        $script:WingetSatisfiedExitCodes = @(0, -1978273215)
        $script:mockExit = -1978273215
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall { return [pscustomobject]@{ ExitCode = $script:mockExit; TimedOut = $false; Output = 'mocked' } }
        Mock Resolve-OSyncApplyPython { return 'C:\Python312\python.exe' }
        Mock Resolve-OSyncNodeInstallDir { return 'C:\Program Files\nodejs' }

        $s = Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe'
        $s.Status | Should -Be 'done'
    }

    It 'any other non-zero exit code fails the step (throws)' {
        $root = Join-Path $TestDrive 'r3'
        & $script:NewWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'r3state')
        $script:mockExit = 1
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall { return [pscustomobject]@{ ExitCode = $script:mockExit; TimedOut = $false; Output = 'boom' } }

        $err = $null
        try { Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe' | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*FAILED*'
    }

    It 'fails fast on a port-coupling mismatch before the server starts' {
        $root = Join-Path $TestDrive 'r4'
        & $script:NewWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'r4state')
        Mock Get-OSyncWingetPortMismatch { return 'http://127.0.0.1:9999/x.msi' }
        $serverCalled = $false
        Mock Start-OSyncHttpServer { $serverCalled = $true; return [pscustomobject]@{ IsStopped = $false } }

        $err = $null
        try { Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe' | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*port-coupling*'
        $serverCalled | Should -Be $false
    }

    It 'skips when runtime-winget.txt is empty' {
        $root = Join-Path $TestDrive 'r5'
        & $script:NewWork $root @()
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'r5state')
        $s = Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe'
        $s.Status | Should -Be 'skipped'
    }

    It 'throws when a tool that was supposed to be installed does not resolve' {
        $root = Join-Path $TestDrive 'r6'
        & $script:NewWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'r6state')
        $script:mockExit = 0
        Mock Start-OSyncHttpServer { return [pscustomobject]@{ IsStopped = $false } }
        Mock Stop-OSyncHttpServer { }
        Mock Invoke-OSyncWingetInstall { return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Output = 'ok' } }
        Mock Resolve-OSyncApplyPython { throw 'no python' }
        Mock Resolve-OSyncNodeInstallDir { return 'C:\Program Files\nodejs' }

        $err = $null
        try { Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe' | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*python.exe*'
    }

    It 'WhatIf starts no server and records nothing' {
        $root = Join-Path $TestDrive 'r7'
        & $script:NewWork $root
        $stateDir = Join-Path $TestDrive 'r7state'
        $cfg = & $script:NewConfig $stateDir
        $serverCalled = $false
        Mock Start-OSyncHttpServer { $serverCalled = $true; return [pscustomobject]@{ IsStopped = $false } }

        $s = Invoke-OSyncBootstrapStepRuntimeWinget -Config $cfg -Root $root -WingetExe 'C:\fake\winget.exe' -WhatIf
        $s.Status | Should -Be 'done'
        $serverCalled | Should -Be $false
        (Test-Path -LiteralPath (Join-Path $stateDir 'state\system-state.json')) | Should -Be $false
    }
}

Describe 'Bootstrap: step 4 - Verdaccio task registration and port wait' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir, [int]$VerdaccioPort = 4873)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; httpPort = 8788; verdaccioPort = $VerdaccioPort;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
        $script:NewNpmWork = {
            param([string]$Root)
            $npmDir = Join-Path $Root 'npm'
            New-Item -ItemType Directory -Path $npmDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $npmDir 'verdaccio-b.yml'), "storage: ./storage`r`npackages:`r`n  '**':`r`n    access: `$all`r`n", (New-Object System.Text.UTF8Encoding($true)))
            New-Item -ItemType Directory -Path (Join-Path $Root 'runtime') -Force | Out-Null
        }
        $script:DesiredAction = [pscustomobject]@{
            Execute        = 'C:\node\node.exe'
            Arguments      = '"C:\v-bin\node_modules\verdaccio\bin\verdaccio" --config "C:\v\verdaccio-b.yml"'
            WorkingDirectory = 'C:\work'
            NodeExe        = 'C:\node\node.exe'
        }
        # The robocopy mock must ALSO produce the expected local-copy file
        # (the real step checks <stateDir>\verdaccio\verdaccio-b.yml after the
        # copy) - the /MIR destination gets a dummy verdaccio-b.yml.
        $script:SeedRobocopyMock = {
            Mock Invoke-OSyncRobocopy {
                param($Source, $Destination)
                New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                if ($Source -match '\\npm$') {
                    [System.IO.File]::WriteAllText((Join-Path $Destination 'verdaccio-b.yml'), "storage: ./storage`r`n", (New-Object System.Text.UTF8Encoding($false)))
                }
                return 1
            }
        }
    }

    It 'seeds local copies, registers the task, starts it and waits for the port' {
        $root = Join-Path $TestDrive 'n1'
        & $script:NewNpmWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'n1state') 4876
        $script:robocopyCalls = @()
        Mock Invoke-OSyncRobocopy {
            param($Source, $Destination)
            $script:robocopyCalls += "$Source -> $Destination"
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
            if ($Source -match '\\npm$') {
                [System.IO.File]::WriteAllText((Join-Path $Destination 'verdaccio-b.yml'), "storage: ./storage`r`n", (New-Object System.Text.UTF8Encoding($false)))
            }
            return 1
        }
        Mock Get-OSyncVerdaccioTaskAction { return $script:DesiredAction }
        Mock Get-ScheduledTask { return $null }                    # not registered yet
        $script:regCount = 0
        Mock Register-ScheduledTask { $script:regCount++ }
        Mock Start-ScheduledTask { }
        Mock Test-OSyncPortListening { return $false }
        Mock Wait-OSyncPortListening { param($Port) $script:waitedPort = $Port; return $true }

        $s = Invoke-OSyncBootstrapStepNpm -Config $cfg -Root $root -VerdaccioTaskName 'PakageSync-Verdaccio-QA'

        $s.Status | Should -Be 'done'
        $script:regCount | Should -Be 1
        $script:waitedPort | Should -Be 4876
        $script:robocopyCalls.Count | Should -Be 2
        $script:robocopyCalls[0] | Should -BeLike '*verdaccio-bin'
        $script:robocopyCalls[1] | Should -BeLike '*verdaccio'
    }

    It 'skips registration when a task with the identical action already exists' {
        $root = Join-Path $TestDrive 'n2'
        & $script:NewNpmWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'n2state') 4873
        & $script:SeedRobocopyMock
        Mock Get-OSyncVerdaccioTaskAction { return $script:DesiredAction }
        Mock Get-ScheduledTask {
            return [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = $script:DesiredAction.Execute; Arguments = $script:DesiredAction.Arguments }) }
        }
        $script:regCount = 0
        Mock Register-ScheduledTask { $script:regCount++ }
        Mock Start-ScheduledTask { }
        Mock Test-OSyncPortListening { return $false }
        Mock Wait-OSyncPortListening { return $true }

        $s = Invoke-OSyncBootstrapStepNpm -Config $cfg -Root $root -VerdaccioTaskName 'PakageSync-Verdaccio-QA'
        $s.Status | Should -Be 'done'
        $script:regCount | Should -Be 0
    }

    It 're-registers when the task action changed' {
        $root = Join-Path $TestDrive 'n3'
        & $script:NewNpmWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'n3state') 4873
        & $script:SeedRobocopyMock
        Mock Get-OSyncVerdaccioTaskAction { return $script:DesiredAction }
        Mock Get-ScheduledTask {
            return [pscustomobject]@{ Actions = @([pscustomobject]@{ Execute = 'C:\stale\node.exe'; Arguments = '--stale' }) }
        }
        $script:regCount = 0
        Mock Register-ScheduledTask { $script:regCount++ }
        Mock Start-ScheduledTask { }
        Mock Test-OSyncPortListening { return $false }
        Mock Wait-OSyncPortListening { return $true }

        $s = Invoke-OSyncBootstrapStepNpm -Config $cfg -Root $root -VerdaccioTaskName 'PakageSync-Verdaccio-QA'
        $script:regCount | Should -Be 1
    }

    It 'throws when the port is already occupied' {
        $root = Join-Path $TestDrive 'n4'
        & $script:NewNpmWork $root
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'n4state') 4873
        & $script:SeedRobocopyMock
        Mock Get-OSyncVerdaccioTaskAction { return $script:DesiredAction }
        Mock Get-ScheduledTask { return $null }
        Mock Register-ScheduledTask { }
        Mock Start-ScheduledTask { }
        Mock Test-OSyncPortListening { return $true }

        $err = $null
        try { Invoke-OSyncBootstrapStepNpm -Config $cfg -Root $root -VerdaccioTaskName 'PakageSync-Verdaccio-QA' | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*already in use*'
    }

    It 'throws when verdaccio-b.yml fails the offline assertion' {
        $root = Join-Path $TestDrive 'n5'
        $npmDir = Join-Path $root 'npm'
        New-Item -ItemType Directory -Path $npmDir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $npmDir 'verdaccio-b.yml'), "storage: ./storage`r`nuplinks:`r`n  npmjs:`r`n    url: https://registry.npmjs.org/`r`n")
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'n5state') 4873

        $err = $null
        try { Invoke-OSyncBootstrapStepNpm -Config $cfg -Root $root -VerdaccioTaskName 'PakageSync-Verdaccio-QA' | Out-Null } catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -BeLike '*uplinks*'
    }
}

Describe 'Bootstrap: step 5 - stateDir layout and ACLs' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir, [string]$RepoRoot = 'C:\unused\repo')
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; repoRoot = $RepoRoot; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
    }

    It 'creates the full subdir layout with owner checks passing' {
        $stateDir = Join-Path $TestDrive 'l1'
        $cfg = & $script:NewConfig $stateDir
        $s = Invoke-OSyncBootstrapStepStateDirLayout -Config $cfg
        $s.Status | Should -Be 'done'
        foreach ($sub in @('state', 'run', 'bin', 'work', 'verdaccio', 'verdaccio-bin')) {
            (Test-Path -LiteralPath (Join-Path $stateDir $sub) -PathType Container) | Should -Be $true
        }
        (Test-Path -LiteralPath (Join-Path $stateDir 'run\logs') -PathType Container) | Should -Be $true
    }

    It 'WhatIf creates nothing' {
        $stateDir = Join-Path $TestDrive 'l2'
        $cfg = & $script:NewConfig $stateDir
        $s = Invoke-OSyncBootstrapStepStateDirLayout -Config $cfg -WhatIf
        $s.Status | Should -Be 'done'
        (Test-Path -LiteralPath $stateDir -PathType Container) | Should -Be $false
    }

    It 'trusted owner gate accepts dirs owned by an administrator' {
        $dir = Join-Path $TestDrive 'owner-ok'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Test-OSyncTrustedDirOwner -Dir $dir | Should -Be $true
    }
}

Describe 'Bootstrap: step 6 - tool landing (hermetic mocks, never touches C:\PakageSync)' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
        $script:NewTool = {
            param([string]$Root)
            $tool = Join-Path $Root 'runtime\tool'
            New-Item -ItemType Directory -Path (Join-Path $tool 'src') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $tool 'src\Install-OfflineBootstrap.ps1'), '# dummy', (New-Object System.Text.UTF8Encoding($true)))
            [System.IO.File]::WriteAllText((Join-Path $tool 'packagesync.b.json'), '{ "role": "B" }', (New-Object System.Text.UTF8Encoding($true)))
        }
    }

    It 'robocopies the tool, skips config overwrite and places the launcher' {
        $root = Join-Path $TestDrive 't1'
        & $script:NewTool $root
        $stateDir = Join-Path $TestDrive 't1state'
        $cfg = & $script:NewConfig $stateDir
        $landing = Join-Path $TestDrive 't1-landing'
        # Pre-create the landing config -> the first-copy branch must be skipped.
        New-Item -ItemType Directory -Path (Join-Path $landing 'config') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $landing 'config\packagesync.json'), '{}', (New-Object System.Text.UTF8Encoding($false)))

        $script:robocopyArgs = $null
        Mock Invoke-OSyncRobocopy { param($Source, $Destination, $ExtraArgs) $script:robocopyArgs = $ExtraArgs; return 1 }
        $script:copied = @()
        Mock Copy-Item { param($LiteralPath, $Destination) $script:copied += "$LiteralPath -> $Destination" }

        $s = Invoke-OSyncBootstrapStepToolLanding -Config $cfg -Root $root -LandingRoot $landing

        $s.Status | Should -Be 'done'
        $script:robocopyArgs | Should -Contain '/MIR'
        $script:robocopyArgs | Should -Contain '/XD'
        $script:robocopyArgs | Should -Contain 'config'
        $script:copied.Count | Should -Be 0                    # config already present -> not overwritten
        (Test-Path -LiteralPath (Join-Path $stateDir 'bin\launch-apply.ps1') -PathType Leaf) | Should -Be $true
        # Landing family hardening created .new/.old siblings.
        (Test-Path -LiteralPath ($landing + '.new') -PathType Container) | Should -Be $true
        (Test-Path -LiteralPath ($landing + '.old') -PathType Container) | Should -Be $true
    }

    It 'first-run seeds the landing config from the tool payload' {
        $root = Join-Path $TestDrive 't2'
        & $script:NewTool $root
        $stateDir = Join-Path $TestDrive 't2state'
        $cfg = & $script:NewConfig $stateDir
        $landing = Join-Path $TestDrive 't2-landing'

        Mock Invoke-OSyncRobocopy { return 1 }
        $script:copied = @()
        Mock Copy-Item { param($LiteralPath, $Destination) $script:copied += "$LiteralPath -> $Destination" }

        $s = Invoke-OSyncBootstrapStepToolLanding -Config $cfg -Root $root -LandingRoot $landing

        $s.Status | Should -Be 'done'
        $script:copied.Count | Should -Be 1
        $script:copied[0] | Should -BeLike '*packagesync.b.json -> *config\packagesync.json'
    }

    It 'WhatIf makes no writes (no robocopy, no launcher)' {
        $root = Join-Path $TestDrive 't3'
        & $script:NewTool $root
        $stateDir = Join-Path $TestDrive 't3state'
        $cfg = & $script:NewConfig $stateDir
        $landing = Join-Path $TestDrive 't3-landing'
        $script:roboCount = 0
        Mock Invoke-OSyncRobocopy { $script:roboCount++ }

        $s = Invoke-OSyncBootstrapStepToolLanding -Config $cfg -Root $root -LandingRoot $landing -WhatIf
        $s.Status | Should -Be 'done'
        $script:roboCount | Should -Be 0
        (Test-Path -LiteralPath (Join-Path $stateDir 'bin\launch-apply.ps1')) | Should -Be $false
        (Test-Path -LiteralPath $landing) | Should -Be $false
    }

    It 'launcher content sanity: self-heals .new/.old and never touches user-writable areas' {
        $content = Get-OSyncLaunchApplyScriptContent
        $content | Should -BeLike '*C:\PakageSync*'
        $content | Should -BeLike '*Rename-Item*'
        $content | Should -BeLike '*launch-apply.ps1*'
    }
}

Describe 'Bootstrap: step 7 + orchestration invariants' {
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
        . (Join-Path $PSScriptRoot '..\src\lib\RuntimeExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\WingetApply.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')

        $script:NewConfig = {
            param([string]$StateDir)
            return [pscustomobject]@{ role = 'B'; stateDir = $StateDir; repoRoot = 'C:\unused\repo'; httpPort = 8788; verdaccioPort = 4873;
                categories = [pscustomobject]@{ winget = $true; pip = $true; npm = $true; dotfiles = $true };
                winget = [pscustomobject]@{ scope = 'machine'; architecture = 'x64' } }
        }
        $script:NewRepo = {
            param([string]$Root)
            New-Item -ItemType Directory -Path $Root -Force | Out-Null
            $rt = Join-Path $Root 'runtime'
            New-Item -ItemType Directory -Path $rt -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $rt 'runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $rt
            $wg = Join-Path $Root 'winget'
            New-Item -ItemType Directory -Path $wg -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $wg 'packages.txt'), "7zip.7zip@26.02`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $null = New-OSyncFilesManifest -Dir $wg
            $null = Publish-OSyncIndex -StagingDir $Root
        }

        # Mocks shared by the orchestration tests: step functions except 5/6/7.
        $script:MockAllSteps = {
            Mock Invoke-OSyncBootstrapStepVcRuntime { New-OSyncBootstrapStepResult -Step '0-vcruntime' -Status 'skipped' -Message 'mocked' }
            Mock Invoke-OSyncBootstrapStepAppInstaller { New-OSyncBootstrapStepResult -Step '1-appinstaller' -Status 'done' -Message 'mocked' -Data @{ WingetExe = 'C:\fake\winget.exe' } }
            Mock Invoke-OSyncBootstrapStepLocalManifest { New-OSyncBootstrapStepResult -Step '2-localmanifest' -Status 'skipped' -Message 'mocked' }
            Mock Invoke-OSyncBootstrapStepRuntimeWinget { New-OSyncBootstrapStepResult -Step '3-runtime-winget' -Status 'done' -Message 'mocked' -Data @{ PythonExe = 'C:\Python312\python.exe'; NodeExe = 'C:\node\node.exe' } }
            Mock Invoke-OSyncBootstrapStepNpm { New-OSyncBootstrapStepResult -Step '4-verdaccio' -Status 'done' -Message 'mocked' }
            # Step 5 is REAL in the dedicated 'stateDir layout' describe; here it
            # is mocked because the real icacls hardening makes state\ Users-RX -
            # the TEST process (a non-elevated/filtered token) could then no
            # longer write the system store in step 7 nor clean TestDrive.
            # Production runs elevated, so the real hardening + step 7 coexist.
            Mock Invoke-OSyncBootstrapStepStateDirLayout { New-OSyncBootstrapStepResult -Step '5-statedir-acl' -Status 'done' -Message 'mocked' }
            Mock Invoke-OSyncBootstrapStepToolLanding { New-OSyncBootstrapStepResult -Step '6-tool-landing' -Status 'done' -Message 'mocked' }
        }
    }

    It 'step 7 sets bootstrapped=true and records the runtime hashes' {
        $bw = Join-Path $TestDrive 'bw7'
        New-Item -ItemType Directory -Path (Join-Path $bw 'runtime') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $bw 'runtime\runtime-winget.txt'), "Python.Python.3.12@3.12.10`r`n", (New-Object System.Text.UTF8Encoding($true)))
        $null = New-OSyncFilesManifest -Dir (Join-Path $bw 'runtime')
        $stateDir = Join-Path $TestDrive 's7state'
        $cfg = & $script:NewConfig $stateDir

        $s = Set-OSyncBootstrapComplete -Config $cfg -Bw $bw -WingetExe 'C:\fake\winget.exe' -PythonExe 'C:\py\python.exe' -NodeExe 'C:\node\node.exe'

        $s.Status | Should -Be 'done'
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.bootstrapped | Should -Be $true
        $state.wingetExePath | Should -Be 'C:\fake\winget.exe'
        $state.pythonExePath | Should -Be 'C:\py\python.exe'
        $state.nodeExePath | Should -Be 'C:\node\node.exe'
        $state.runtimeWingetHash | Should -Not -BeNullOrEmpty
        $state.runtimeFilesHash | Should -Not -BeNullOrEmpty
    }

    It 'step 7 WhatIf sets nothing' {
        $bw = Join-Path $TestDrive 'bw7w'
        New-Item -ItemType Directory -Path (Join-Path $bw 'runtime') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $bw 'runtime\runtime-winget.txt'), "x`r`n")
        $stateDir = Join-Path $TestDrive 's7w'
        $cfg = & $script:NewConfig $stateDir
        $s = Set-OSyncBootstrapComplete -Config $cfg -Bw $bw -WhatIf
        $s.Status | Should -Be 'done'
        (Test-Path -LiteralPath (Join-Path $stateDir 'state\system-state.json')) | Should -Be $false
    }

    It 'orchestration: happy path reaches bootstrapped=true' {
        $repo = Join-Path $TestDrive 'repo-happy'
        & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'oh-state'
        $cfg = & $script:NewConfig $stateDir
        $cfg.repoRoot = $repo
        $cfg.categories.npm = $false          # the fixture repo has no npm category
        & $script:MockAllSteps

        $result = Invoke-OSyncBootstrap -Config $cfg -VerdaccioTaskName 'PakageSync-Verdaccio-QA'

        $result.Success | Should -Be $true
        $result.Bootstrapped | Should -Be $true
        $result.WingetExe | Should -Be 'C:\fake\winget.exe'
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.bootstrapped | Should -Be $true
        $result.Steps.Count | Should -Be 7     # 0,1,2,3 (winget) + 5,6,7 (unconditional)
    }

    It 'orchestration: WhatIf makes no state writes' {
        $repo = Join-Path $TestDrive 'repo-wi'
        & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'oiw-state'
        $cfg = & $script:NewConfig $stateDir
        $cfg.repoRoot = $repo
        $cfg.categories.npm = $false
        & $script:MockAllSteps

        $result = Invoke-OSyncBootstrap -Config $cfg -WhatIf -VerdaccioTaskName 'PakageSync-Verdaccio-QA'

        $result.Success | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $stateDir 'state\system-state.json')) | Should -Be $false
    }

    It 'orchestration: a failing step keeps bootstrapped=false' {
        $repo = Join-Path $TestDrive 'repo-fail'
        & $script:NewRepo $repo
        $stateDir = Join-Path $TestDrive 'of-state'
        $cfg = & $script:NewConfig $stateDir
        $cfg.repoRoot = $repo
        $cfg.categories.npm = $false
        & $script:MockAllSteps
        Mock Invoke-OSyncBootstrapStepRuntimeWinget { throw 'winget install FAILED (mocked)' }

        $result = Invoke-OSyncBootstrap -Config $cfg -VerdaccioTaskName 'PakageSync-Verdaccio-QA'

        $result.Success | Should -Be $false
        $result.Bootstrapped | Should -Be $false
        $result.Error | Should -BeLike '*FAILED*'
        $state = Get-OSyncState -Category winget -StateDir $stateDir
        $state.bootstrapped | Should -Be $false
    }

    It 'orchestration: corrupt repository aborts before any step, bootstrapped=false' {
        $repo = Join-Path $TestDrive 'repo-corrupt'
        & $script:NewRepo $repo
        # Tamper a manifest-listed file -> winget category Incomplete.
        [System.IO.File]::WriteAllText((Join-Path $repo 'winget\packages.txt'), "tampered`r`n")
        $stateDir = Join-Path $TestDrive 'oc-state'
        $cfg = & $script:NewConfig $stateDir
        $cfg.repoRoot = $repo
        $cfg.categories.npm = $false
        $stepCalled = $false
        Mock Invoke-OSyncBootstrapStepVcRuntime { $stepCalled = $true }

        $result = Invoke-OSyncBootstrap -Config $cfg -VerdaccioTaskName 'PakageSync-Verdaccio-QA'

        $result.Success | Should -Be $false
        $result.Bootstrapped | Should -Be $false
        $result.Error | Should -BeLike '*winget*'
        $stepCalled | Should -Be $false
    }

    It 'orchestration: role must be B' {
        $cfg = & $script:NewConfig (Join-Path $TestDrive 'role-state')
        $cfg.role = 'A'
        $result = Invoke-OSyncBootstrap -Config $cfg
        $result.Success | Should -Be $false
        $result.Error | Should -BeLike "*role must be 'B'*"
    }
}

Describe 'Bootstrap: apply.lock helpers' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Bootstrap.ps1')
    }

    It 'acquires a fresh lock and releases it only when owned' {
        $stateDir = Join-Path $TestDrive 'lock1'
        Test-OSyncAcquireBootstrapLock -StateDir $stateDir -TimeoutSeconds 5 | Should -Be $true
        (Test-Path -LiteralPath (Join-Path $stateDir 'run\apply.lock') -PathType Leaf) | Should -Be $true
        Remove-OSyncBootstrapLock -StateDir $stateDir
        (Test-Path -LiteralPath (Join-Path $stateDir 'run\apply.lock')) | Should -Be $false
    }

    It 'does not release a lock it does not own' {
        $stateDir = Join-Path $TestDrive 'lock2'
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        $other = 'PID=999999 TIMESTAMP=' + [DateTime]::UtcNow.ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'run\apply.lock'), $other)
        Remove-OSyncBootstrapLock -StateDir $stateDir
        (Test-Path -LiteralPath (Join-Path $stateDir 'run\apply.lock') -PathType Leaf) | Should -Be $true
    }

    It 'breaks a stale (>2h) lock and acquires' {
        $stateDir = Join-Path $TestDrive 'lock3'
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        $old = 'PID=999999 TIMESTAMP=' + [DateTime]::UtcNow.AddHours(-3).ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'run\apply.lock'), $old)
        Test-OSyncAcquireBootstrapLock -StateDir $stateDir -TimeoutSeconds 5 | Should -Be $true
    }

    It 'breaks a future-timestamp (>5min ahead) lock and acquires' {
        $stateDir = Join-Path $TestDrive 'lock4'
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        $future = 'PID=999999 TIMESTAMP=' + [DateTime]::UtcNow.AddMinutes(10).ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'run\apply.lock'), $future)
        Test-OSyncAcquireBootstrapLock -StateDir $stateDir -TimeoutSeconds 5 | Should -Be $true
    }

    It 'waits and gives up while a fresh lock is held' {
        $stateDir = Join-Path $TestDrive 'lock5'
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        $fresh = 'PID=999999 TIMESTAMP=' + [DateTime]::UtcNow.ToString('o')
        [System.IO.File]::WriteAllText((Join-Path $stateDir 'run\apply.lock'), $fresh)
        Test-OSyncAcquireBootstrapLock -StateDir $stateDir -TimeoutSeconds 1 | Should -Be $false
    }
}

# The real step-5 ACL hardening leaves Users-RX dirs inside TestDrive; the test
# process (a non-elevated / filtered token) could not remove them, so re-grant
# full control to Users before Pester's Remove-TestDrive runs.
AfterAll {
    if (Test-Path -LiteralPath $TestDrive) {
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $null = @(& icacls.exe $TestDrive /grant '*S-1-5-32-545:(OI)(CI)F' /T /C 2>&1)
        $ErrorActionPreference = $old
    }
}

