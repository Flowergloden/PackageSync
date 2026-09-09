#Requires -Version 5.1
<#
  NpmExport.Tests.ps1 - Pester 5 tests for src\lib\NpmExport.ps1.

  Pure unit tests - none of them start a server and none of them touch the
  network: the verdaccio yml generators and the B-config leak assertion are
  exercised directly, and the npm-touching parts (PIN-ME resolution, engines
  cross-assertion, the pin-in-place write-back) run against a fake npm.cmd
  that is prepended to PATH for the duration of the suite. The real warm-up
  (real npm install through a real one-shot Verdaccio) is covered by the QA
  evidence log, not here. The bun parallel-frontend coverage additionally
  drives Export-OSyncNpm through its warm-up loop with the server/robocopy
  machinery MOCKED via InModuleScope, asserting the merged warm sequence and
  the bun-packages.txt delivery contract.

  Run:
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\NpmExport.Tests.ps1 -PassThru"
    pwsh      -NoProfile -Command "Invoke-Pester tests\NpmExport.Tests.ps1 -PassThru"
#>

BeforeAll {
    # Import the real module: it dot-sources every lib\*.ps1 (incl.
    # NpmExport.ps1 and its Util/Config/ManifestParse dependencies).
    Import-Module (Join-Path $PSScriptRoot '..\src\OfflineSync.psd1') -Force

    # One shared temp root per run; every test builds its own files.
    $script:neRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-ne-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:neRoot -Force | Out-Null

    # --- fake npm.cmd (dispatches on the arguments, output driven by env) ---
    #   args contain "engines"  -> echo %FAKE_NPM_ENGINES%
    #   args contain "version"  -> echo %FAKE_NPM_VERSION%
    #   anything else (install) -> exit silently with %FAKE_NPM_EXIT%
    $script:fakeBin = Join-Path $script:neRoot 'fake-bin'
    New-Item -ItemType Directory -Path $script:fakeBin -Force | Out-Null
    $fakeNpm = @'
@echo off
rem When FAKE_NPM_ARGSLOG is defined, append this invocation's args to it.
if defined FAKE_NPM_ARGSLOG echo %*>> "%FAKE_NPM_ARGSLOG%"
echo %* | findstr /C:"engines" >nul
if not errorlevel 1 goto engines
echo %* | findstr /C:"version" >nul
if not errorlevel 1 goto version
goto end
:engines
if defined FAKE_NPM_ENGINES echo %FAKE_NPM_ENGINES%
exit /b %FAKE_NPM_EXIT%
:version
if defined FAKE_NPM_VERSION echo %FAKE_NPM_VERSION%
exit /b %FAKE_NPM_EXIT%
:end
exit /b %FAKE_NPM_EXIT%
'@
    [System.IO.File]::WriteAllText((Join-Path $script:fakeBin 'npm.cmd'), $fakeNpm, [System.Text.Encoding]::ASCII)

    $script:originalPath = $env:PATH
    $env:PATH = $script:fakeBin + ';' + $env:PATH

    # --- helpers (Pester 5 runs It blocks in child scopes of BeforeAll,
    # --- so functions must be defined here, not at file top level) ---

    function Reset-NewFakeEnv {
        $env:FAKE_NPM_ENGINES = $null
        $env:FAKE_NPM_VERSION = $null
        $env:FAKE_NPM_EXIT = $null
        $env:FAKE_NPM_ARGSLOG = $null
    }

    function New-NeTempFile {
        param([string]$Name, [string]$Content)
        $p = Join-Path $script:neRoot $Name
        $parent = Split-Path -Parent $p
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($p, $Content, (New-Object System.Text.UTF8Encoding($false)))
        return $p
    }

    # A config JSON shaped like the real config\packagesync.json (with the
    # pins.npm.verdaccioVersion value given) - used for Write-OSyncNpmPin
    # and Export-OSyncNpm tests.
    function New-NeConfigJson {
        param([string]$VerdaccioVersion)
        $text = @"
{
  "schemaVersion": 1,
  "role": "A",
  "repoRoot": "D:\\OfflineRepo",
  "stagingRoot": "D:\\PakageSync-staging",
  "httpPort": 8788,
  "verdaccioPort": 4873,
  "npm": {
    "aVerdaccioPort": 4874
  },
  "paths": {
    "runtimeWhitelist": "manifests\\runtime-winget.txt",
    "npmList": "manifests\\npm-packages.txt"
  },
  "pins": {
    "npm": {
      "verdaccioVersion": "$VerdaccioVersion"
    }
  }
}
"@
        return $text
    }

    # A synthetic in-memory config object for Export-OSyncNpm. All paths are
    # absolute so Resolve-OSyncConfigPath uses them verbatim (absolute paths
    # never resolve against the tool root).
    # Optional bun parallel-frontend fixture: -BunEnabled mirrors the bun
    # section of config\packagesync.json (version 1.4.2 / sha256 PIN-ME) and
    # -BunListPath adds the 'paths.bunList' key. An absent 'pins.bun' section
    # (= the current baseline config shape) means bun is disabled.
    function New-NeConfig {
        param(
            [string]$VerdaccioVersion,
            [string]$NpmListPath,
            [string]$RuntimeWhitelistPath,
            [string]$RepoRoot,
            [string]$StagingRoot,
            [string]$BunListPath,
            [switch]$BunEnabled
        )
        $paths = [pscustomobject]@{
            npmList          = $NpmListPath
            runtimeWhitelist = $RuntimeWhitelistPath
        }
        if (-not [string]::IsNullOrWhiteSpace($BunListPath)) {
            $paths | Add-Member -NotePropertyName bunList -NotePropertyValue $BunListPath -Force
        }
        $pins = [pscustomobject]@{
            npm = [pscustomobject]@{ verdaccioVersion = $VerdaccioVersion }
        }
        if ($BunEnabled) {
            $pins | Add-Member -NotePropertyName bun -NotePropertyValue ([pscustomobject]@{
                version = '1.4.2'
                url     = 'https://github.com/oven-sh/bun/releases/download/bun-v1.4.2/bun-windows-x64.zip'
                sha256  = 'PIN-ME'
            }) -Force
        }
        return [pscustomobject]@{
            schemaVersion  = 1
            role           = 'A'
            repoRoot       = $RepoRoot
            stagingRoot    = $StagingRoot
            verdaccioPort  = 4873
            npm            = [pscustomobject]@{ aVerdaccioPort = 4874 }
            paths          = $paths
            pins           = $pins
        }
    }
}

AfterAll {
    if ($null -ne $script:originalPath) { $env:PATH = $script:originalPath }
    if (Test-Path -LiteralPath $script:neRoot) {
        Remove-Item -LiteralPath $script:neRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-OSyncVerdaccioAYaml' {
    It 'points storage at the staging storage dir with forward slashes' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\gen\npm\storage' -Port 4874
        $yaml | Should -Match 'storage:\s*D:/gen/npm/storage'
    }

    It 'contains the npmjs uplink url' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\gen\npm\storage' -Port 4874
        $yaml | Should -Match '(?m)^\s+url:\s*https://registry\.npmjs\.org\s*$'
    }

    It 'proxies both scoped and unscoped packages to npmjs' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\gen\npm\storage' -Port 4874
        $yaml | Should -Match '(?m)^\s+proxy:\s*npmjs\s*$'
        ([regex]::Matches($yaml, '(?m)^\s+proxy:\s*npmjs\s*$')).Count | Should -Be 2
    }

    It 'listens on the one-shot A port' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\gen\npm\storage' -Port 4874
        $yaml | Should -Match '(?m)^listen:\s*127\.0\.0\.1:4874\s*$'
    }

    It 'honors a custom uplink url' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\x' -Port 4874 -UplinkUrl 'https://mirror.example/'
        $yaml | Should -Match 'url:\s*https://mirror\.example/'
    }
}

Describe 'New-OSyncVerdaccioBYaml' {
    It 'uses the relative storage path ./storage' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $yaml | Should -Match '(?m)^\s*storage:\s*\./storage\s*$'
    }

    It 'listens on the B port' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $yaml | Should -Match '(?m)^listen:\s*127\.0\.0\.1:4873\s*$'
    }

    It 'disables the web UI' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $yaml | Should -Match '(?m)^web:\s*$'
        $yaml | Should -Match '(?m)^\s+enable:\s*false\s*$'
    }

    It 'has access $all for the ** rule and no other package rules' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $yaml | Should -Match '(?m)^\s+access:\s*\$all\s*$'
        ([regex]::Matches($yaml, '(?m)^\s+access:')).Count | Should -Be 1
    }

    It 'contains no uplinks or proxy keys' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $yaml | Should -Not -Match '(?im)^\s*(uplinks|proxy)\s*:'
    }
}

Describe 'Test-OSyncVerdaccioBYaml (leak assertion)' {
    It 'accepts a valid B config' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        Test-OSyncVerdaccioBYaml -Content $yaml | Should -Be $true
    }

    It 'rejects content with a proxy key' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $tampered = $yaml + "`nproxy: npmjs`n"
        Test-OSyncVerdaccioBYaml -Content $tampered | Should -Be $false
    }

    It 'rejects content with an uplinks key' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $tampered = $yaml + "`nuplinks:`n  npmjs:`n    url: https://registry.npmjs.org`n"
        Test-OSyncVerdaccioBYaml -Content $tampered | Should -Be $false
    }

    It 'rejects an absolute storage path' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $tampered = $yaml -replace 'storage:\s*\./storage', 'storage: C:\snapshot\storage'
        Test-OSyncVerdaccioBYaml -Content $tampered | Should -Be $false
    }

    It 'rejects content without a storage line' {
        $yaml = (New-OSyncVerdaccioBYaml -Port 4873) -replace '(?m)^storage:.*\r?\n', ''
        Test-OSyncVerdaccioBYaml -Content $yaml | Should -Be $false
    }

    It 'rejects empty content' {
        Test-OSyncVerdaccioBYaml -Content '' | Should -Be $false
    }

    It 'does not false-positive on a comment mentioning proxy' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $commented = $yaml -replace '(?m)^(storage:)', "# a comment about proxy and uplinks`n`$1"
        Test-OSyncVerdaccioBYaml -Content $commented | Should -Be $true
    }
}

Describe 'Resolve-OSyncNpmVerdaccioVersion' {
    BeforeEach { Reset-NewFakeEnv }

    It 'passes an already-pinned version through untouched' {
        Resolve-OSyncNpmVerdaccioVersion -Version '5.9.1' | Should -Be '5.9.1'
    }

    It 'resolves PIN-ME via npm view' {
        $env:FAKE_NPM_VERSION = '6.10.2'
        Resolve-OSyncNpmVerdaccioVersion -Version 'PIN-ME' | Should -Be '6.10.2'
    }

    It 'throws when npm view fails' {
        $env:FAKE_NPM_VERSION = '6.10.2'
        $env:FAKE_NPM_EXIT = '1'
        $err = $null
        try { Resolve-OSyncNpmVerdaccioVersion -Version 'PIN-ME' | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike "*npm view verdaccio version*"
    }

    It 'throws on a non-semver npm output' {
        $env:FAKE_NPM_VERSION = 'not-a-version'
        $err = $null
        try { Resolve-OSyncNpmVerdaccioVersion -Version 'PIN-ME' | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*unexpected version output*'
    }
}

Describe 'Write-OSyncNpmPin (pin-in-place write-back)' {
    It 'replaces the PIN-ME value and keeps everything else byte-identical' {
        $cfgPath = New-NeTempFile -Name 'pin\packagesync.json' -Content (New-NeConfigJson 'PIN-ME')
        Write-OSyncNpmPin -ConfigPath $cfgPath -Version '6.10.2'
        $text = [System.IO.File]::ReadAllText($cfgPath)
        $text | Should -Match '    "verdaccioVersion": "6\.10\.2"'
        $text | Should -Not -Match 'PIN-ME'
        $text | Should -Match '"repoRoot": "D:\\\\OfflineRepo"'
        $text | Should -Match '"aVerdaccioPort": 4874'
        # Indentation of the surrounding lines is preserved.
        $text | Should -Match '  "pins": \{'
    }

    It 'preserves a UTF-8 BOM' {
        $cfgPath = New-NeTempFile -Name 'pin\with-bom.json' -Content (New-NeConfigJson 'PIN-ME')
        # Force a BOM on the file (the real config has one).
        $bytes = [System.IO.File]::ReadAllBytes($cfgPath)
        $withBom = New-Object byte[] ($bytes.Length + 3)
        [Array]::Copy($bytes, 0, $withBom, 3, $bytes.Length)
        $withBom[0] = 0xEF; $withBom[1] = 0xBB; $withBom[2] = 0xBF
        [System.IO.File]::WriteAllBytes($cfgPath, $withBom)

        Write-OSyncNpmPin -ConfigPath $cfgPath -Version '6.10.2'
        $after = [System.IO.File]::ReadAllBytes($cfgPath)
        $after[0] | Should -Be 0xEF
        $after[1] | Should -Be 0xBB
        $after[2] | Should -Be 0xBF
    }

    It 'falls back to a full round-trip when the key literal is absent' {
        $json = (New-NeConfigJson 'PIN-ME') -replace '"verdaccioVersion"\s*:\s*"[^"]*"\r?\n', ''
        $cfgPath = New-NeTempFile -Name 'pin\no-key.json' -Content $json
        Write-OSyncNpmPin -ConfigPath $cfgPath -Version '6.10.2'
        $obj = [System.IO.File]::ReadAllText($cfgPath) | ConvertFrom-Json
        $obj.pins.npm.verdaccioVersion | Should -Be '6.10.2'
    }

    It 'refuses a non-semver version' {
        $cfgPath = New-NeTempFile -Name 'pin\bad.json' -Content (New-NeConfigJson 'PIN-ME')
        $err = $null
        try { Write-OSyncNpmPin -ConfigPath $cfgPath -Version 'latest' | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*refusing to pin*'
    }
}

Describe 'Test-OSyncNpmNodeCompat (engines cross-assertion)' {
    BeforeEach { Reset-NewFakeEnv }

    It 'accepts pinned node 24 for engines >=22' {
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        $r = Test-OSyncNpmNodeCompat -VerdaccioVersion '6.10.2' -PinnedNodeMajor 24
        $r.Compatible | Should -Be $true
        $r.EnginesNode | Should -Be '>=22'
    }

    It 'rejects pinned node 18 for engines ^20' {
        $env:FAKE_NPM_ENGINES = '{"node":"^20.0.0"}'
        $r = Test-OSyncNpmNodeCompat -VerdaccioVersion '6.10.2' -PinnedNodeMajor 18
        $r.Compatible | Should -Be $false
    }

    It 'accepts 24 inside >=12 <25' {
        $env:FAKE_NPM_ENGINES = '{"node":">=12 <25"}'
        $r = Test-OSyncNpmNodeCompat -VerdaccioVersion '6.10.2' -PinnedNodeMajor 24
        $r.Compatible | Should -Be $true
    }

    It 'rejects 26 outside >=12 <25' {
        $env:FAKE_NPM_ENGINES = '{"node":">=12 <25"}'
        $r = Test-OSyncNpmNodeCompat -VerdaccioVersion '6.10.2' -PinnedNodeMajor 26
        $r.Compatible | Should -Be $false
    }

    It 'rejects unparsable engines output (fail-safe)' {
        $env:FAKE_NPM_ENGINES = 'not json at all'
        $r = Test-OSyncNpmNodeCompat -VerdaccioVersion '6.10.2' -PinnedNodeMajor 24
        $r.Compatible | Should -Be $false
        $r.Reason | Should -BeLike '*not parseable*'
    }

    It 'treats missing engines data as compatible (no constraint)' {
        $env:FAKE_NPM_ENGINES = $null
        $r = Test-OSyncNpmNodeCompat -VerdaccioVersion '6.10.2' -PinnedNodeMajor 24
        $r.Compatible | Should -Be $true
        $r.EnginesNode | Should -Be ''
    }
}

Describe 'Export-OSyncNpm pin-in-place flow (no server)' {
    BeforeEach { Reset-NewFakeEnv }

    It 'resolves PIN-ME, writes the pin back into the config file, then fails at the (fake) install - never starts a server' {
        $env:FAKE_NPM_VERSION = '6.10.2'
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        $cfgPath = New-NeTempFile -Name 'export\config.json' -Content (New-NeConfigJson 'PIN-ME')
        $npmList = New-NeTempFile -Name 'export\npm-list.txt' -Content 'is-odd@3.0.1'
        $runtime = New-NeTempFile -Name 'export\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $repoRoot = Join-Path $script:neRoot 'export\repo'
        $stagingRoot = Join-Path $script:neRoot 'export\staging-root'
        $stagingDir = Join-Path $script:neRoot 'export\gen1'
        $cfg = New-NeConfig -VerdaccioVersion 'PIN-ME' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot $repoRoot -StagingRoot $stagingRoot

        $err = $null
        try { Export-OSyncNpm -Config $cfg -StagingDir $stagingDir -ConfigPath $cfgPath | Out-Null }
        catch { $err = $_ }

        # Pin-in-place happened BEFORE the install step failed.
        $text = [System.IO.File]::ReadAllText($cfgPath)
        $text | Should -Match '"verdaccioVersion": "6\.10\.2"'
        $text | Should -Not -Match 'PIN-ME'
        # The fake npm install produced no real verdaccio -> clean early throw.
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*verdaccio*entry script not found*'
    }

    It 'fails fast on an incompatible engines range before any install' {
        $env:FAKE_NPM_ENGINES = '{"node":">=30"}'
        $cfgPath = New-NeTempFile -Name 'export2\config.json' -Content (New-NeConfigJson '6.10.2')
        $npmList = New-NeTempFile -Name 'export2\npm-list.txt' -Content 'is-odd@3.0.1'
        $runtime = New-NeTempFile -Name 'export2\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'export2\repo') `
            -StagingRoot (Join-Path $script:neRoot 'export2\staging-root')

        $err = $null
        try { Export-OSyncNpm -Config $cfg -StagingDir (Join-Path $script:neRoot 'export2\gen1') -ConfigPath $cfgPath | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*cross-assertion failed*'
        $err.Exception.Message | Should -BeLike '*incompatible*'
    }

    It 'fails when the runtime whitelist has no pinned Node entry' {
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        $cfgPath = New-NeTempFile -Name 'export3\config.json' -Content (New-NeConfigJson '6.10.2')
        $npmList = New-NeTempFile -Name 'export3\npm-list.txt' -Content 'is-odd@3.0.1'
        $runtime = New-NeTempFile -Name 'export3\runtime-winget.txt' -Content "Python.Python.3.12@3.12.10`n"
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'export3\repo') `
            -StagingRoot (Join-Path $script:neRoot 'export3\staging-root')

        $err = $null
        try { Export-OSyncNpm -Config $cfg -StagingDir (Join-Path $script:neRoot 'export3\gen1') -ConfigPath $cfgPath | Out-Null }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*no *OpenJS.NodeJS*entry*'
    }
}

Describe 'Export-OSyncNpm with a UNC staging root (no server)' {
    BeforeEach { Reset-NewFakeEnv }

    # The UNC-looking stagingRoot ('\\fake-share\osync-staging') is NEVER
    # created on disk - only the LOCAL temp paths get exercised. FAKE_NPM_EXIT
    # makes the fake npm abort the verdaccio install, so the export throws
    # right after the install attempt (before any server/UNC-side write) and
    # the recorded npm args prove the --prefix was local.
    It 'installs the one-shot verdaccio with a LOCAL --prefix when stagingRoot is a UNC path' {
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        $env:FAKE_NPM_EXIT = '1'
        $argsLog = Join-Path $script:neRoot 'unc-export\npm-args.log'
        $env:FAKE_NPM_ARGSLOG = $argsLog
        $npmList = New-NeTempFile -Name 'unc-export\npm-list.txt' -Content 'is-odd@3.0.1'
        $runtime = New-NeTempFile -Name 'unc-export\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'unc-export\repo') `
            -StagingRoot '\\fake-share\osync-staging'

        $err = $null
        try { Export-OSyncNpm -Config $cfg -StagingDir (Join-Path $script:neRoot 'unc-export\gen1') | Out-Null }
        catch { $err = $_ }

        # The fake npm failed the verdaccio install - the export must have
        # aborted right there, before starting any server.
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike '*npm install verdaccio@6.10.2*failed*'

        # The failed invocation was the tool install; its --prefix must be a
        # LOCAL temp path, never a UNC one (npm arborist 'realpathCached'
        # infinitely recurses on UNC prefixes).
        $installLine = @(Get-Content -LiteralPath $argsLog -ErrorAction Stop |
            Where-Object { $_ -like 'install --prefix*' } | Select-Object -Last 1)
        $installLine.Count | Should -Be 1
        $prefix = [regex]::Match($installLine[0], 'install --prefix\s+(\S+)').Groups[1].Value
        $prefix | Should -Not -Be ''
        $prefix | Should -Not -Match '^\\\\'
        $prefix.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) | Should -Be $true
    }

    It 'resolves PIN-ME and still installs with a LOCAL --prefix under a UNC stagingRoot' {
        $env:FAKE_NPM_VERSION = '6.10.2'
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        # FAKE_NPM_EXIT intentionally left undefined: the version-view call
        # then exits 0 while the install call exits 1 (last findstr missed) -
        # same abort-after-install semantics as the existing pin-in-place test.
        $argsLog = Join-Path $script:neRoot 'unc-export2\npm-args.log'
        $env:FAKE_NPM_ARGSLOG = $argsLog
        $cfgPath = New-NeTempFile -Name 'unc-export2\config.json' -Content (New-NeConfigJson 'PIN-ME')
        $npmList = New-NeTempFile -Name 'unc-export2\npm-list.txt' -Content 'is-odd@3.0.1'
        $runtime = New-NeTempFile -Name 'unc-export2\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $cfg = New-NeConfig -VerdaccioVersion 'PIN-ME' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'unc-export2\repo') `
            -StagingRoot '\\fake-share\osync-staging'

        $err = $null
        try { Export-OSyncNpm -Config $cfg -StagingDir (Join-Path $script:neRoot 'unc-export2\gen1') -ConfigPath $cfgPath | Out-Null }
        catch { $err = $_ }

        # Pin-in-place wrote the resolved version before the install failed.
        ([System.IO.File]::ReadAllText($cfgPath)) | Should -Match '"verdaccioVersion": "6\.10\.2"'
        $err | Should -Not -BeNullOrEmpty

        $installLine = @(Get-Content -LiteralPath $argsLog -ErrorAction Stop |
            Where-Object { $_ -like 'install --prefix*' } | Select-Object -Last 1)
        $installLine.Count | Should -Be 1
        $prefix = [regex]::Match($installLine[0], 'install --prefix\s+(\S+)').Groups[1].Value
        $prefix | Should -Not -Match '^\\\\'
        $prefix.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase) | Should -Be $true
    }
}

Describe 'Get-ONpmExportLocalWorkRoot (npm scratch path selection)' {
    # Both npm-touching call sites of Export-OSyncNpm (the verdaccio install
    # and the warm-up installs/cache) place their --prefix/--cache dirs under
    # this root, so a local result here means every npm prefix stays local
    # even when stagingRoot is UNC (not reachable in a no-server unit test).
    # The helper is module-internal (OfflineSync.psm1 only exports *-OSync*
    # functions), so it is reached via InModuleScope - the same scope from
    # which Export-OSyncNpm calls it.
    It 'returns a fresh non-UNC path under the OS temp dir' {
        $root = InModuleScope OfflineSync { Get-ONpmExportLocalWorkRoot }
        try {
            $root | Should -Not -BeNullOrEmpty
            $root | Should -Not -Match '^\\\\'
            $root | Should -BeLike ('{0}*' -f [System.IO.Path]::GetTempPath())
            $root | Should -BeLike '*osync-npm-export-*'
            Test-Path -LiteralPath $root -PathType Container | Should -Be $true
        }
        finally {
            if (Test-Path -LiteralPath $root -PathType Container) {
                Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns a distinct root on every call' {
        $a = InModuleScope OfflineSync { Get-ONpmExportLocalWorkRoot }
        $b = InModuleScope OfflineSync { Get-ONpmExportLocalWorkRoot }
        try {
            $a | Should -Not -Be $b
        }
        finally {
            Remove-Item -LiteralPath $a -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $b -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'port checks' {
    It 'Test-OSyncPortListening is true when a listener is bound' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
        try {
            $listener.Start()
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Test-OSyncPortListening -Port $port | Should -Be $true
        }
        finally {
            $listener.Stop()
        }
    }

    It 'Test-OSyncPortListening is false on a free port' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        Test-OSyncPortListening -Port $port | Should -Be $false
    }

    It 'Wait-OSyncPortListening times out when nothing listens' {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
        $listener.Start()
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $listener.Stop()
        Wait-OSyncPortListening -Port $port -TimeoutSeconds 1 | Should -Be $false
    }
}

Describe 'Export-OSyncNpm bun parallel frontend' {
    # bun is a PARALLEL FRONTEND of the npm category: its manifest entries are
    # merged into the SAME one-shot Verdaccio warm list (npm entries first,
    # bun-only entries after, dedup by package name - npm wins) and the bun
    # manifest is shipped verbatim to <staging>\npm\bun-packages.txt. A
    # missing/empty bun list or a config without pins.bun skips bun entirely -
    # never an error (an empty bun list is legal: bun on B installs everything
    # from the npm list through the same registry).
    #
    # These run the REAL Export-OSyncNpm (the fake npm.cmd answers the engines
    # cross-assertion and the verdaccio install), but the server/robocopy
    # machinery is MOCKED so no server starts and nothing touches the network.
    # The module-internal calls (Invoke-ONpmInstall, Start/Stop-OVerdaccioProcess,
    # Get-ONpmExportLocalWorkRoot, ...) are intercepted via InModuleScope -
    # Pester cannot mock non-exported module functions from the test scope, and
    # the mocks DO intercept when the exported function is invoked from here.
    BeforeEach {
        Reset-NewFakeEnv
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        $env:FAKE_NPM_EXIT = '0'
        InModuleScope OfflineSync {
            $script:BunSpecs = @()
            Mock Get-ONodeExe { return 'C:\dummy\node.exe' }
            Mock Test-OSyncPortListening { return $false }
            Mock Wait-OSyncPortListening { return $true }
            Mock Start-OVerdaccioProcess { return [pscustomobject]@{ Id = 12345 } }
            Mock Stop-OVerdaccioProcess { }
            Mock Start-Sleep { }
            Mock Invoke-OSyncRobocopy { }
            Mock Get-ONpmExportLocalWorkRoot {
                # The fake verdaccio install "lands" here: pre-seed the entry
                # script the export checks right after the (fake, exit-0) install.
                $script:BunLocalWork = Join-Path $TestDrive ('lw-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path (Join-Path $script:BunLocalWork 'verdaccio-a\node_modules\verdaccio\bin') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $script:BunLocalWork 'verdaccio-a\node_modules\verdaccio\bin\verdaccio'), 'fake entry', (New-Object System.Text.UTF8Encoding($false)))
                return $script:BunLocalWork
            }
            Mock Invoke-ONpmInstall {
                param([string]$NpmExe, [string]$Spec, [string]$Registry, [string]$Prefix, [string]$CacheDir)
                $script:BunSpecs += $Spec
                return [pscustomobject]@{ ExitCode = 0; Output = 'ok' }
            }
        }
    }

    It 'merges bun-only entries after the npm list, warms a shared name once and delivers bun-packages.txt' {
        $npmList = New-NeTempFile -Name 'bun-a\npm-list.txt' -Content "is-odd@3.0.1`nleft-pad@1.3.0"
        $bunList = New-NeTempFile -Name 'bun-a\bun-list.txt' -Content "is-odd@3.0.1`nbun-only-pkg@1.0.0"
        $runtime = New-NeTempFile -Name 'bun-a\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $stagingDir = Join-Path $script:neRoot 'bun-a\gen1'
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'bun-a\repo') `
            -StagingRoot (Join-Path $script:neRoot 'bun-a\staging-root') `
            -BunListPath $bunList -BunEnabled

        $report = Export-OSyncNpm -Config $cfg -StagingDir $stagingDir

        # Warm sequence: npm entries first, then the bun-only entry; the name
        # present in BOTH lists (is-odd) is warmed exactly once (npm wins).
        $specs = @(InModuleScope OfflineSync { @($script:BunSpecs) })
        ($specs -join ',') | Should -Be 'is-odd@3.0.1,left-pad@1.3.0,bun-only-pkg@1.0.0'

        # Report bun section.
        $report.bun.enabled | Should -Be $true
        $report.bun.listPath | Should -Be $bunList
        $report.bun.entriesAdded | Should -Be 1
        $report.bun.delivered | Should -Be (Join-Path $stagingDir 'npm\bun-packages.txt')

        # Contract file delivered with the bun list content (verbatim copy).
        $delivered = Join-Path $stagingDir 'npm\bun-packages.txt'
        (Test-Path -LiteralPath $delivered) | Should -BeTrue
        ([System.IO.File]::ReadAllText($delivered)) | Should -BeExactly ([System.IO.File]::ReadAllText($bunList))
    }

    It 'skips bun warming and delivery when the bun list file is missing (no error)' {
        $npmList = New-NeTempFile -Name 'bun-b\npm-list.txt' -Content "is-odd@3.0.1"
        $bunList = Join-Path $script:neRoot 'bun-b\missing-bun-list.txt'
        $runtime = New-NeTempFile -Name 'bun-b\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $stagingDir = Join-Path $script:neRoot 'bun-b\gen1'
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'bun-b\repo') `
            -StagingRoot (Join-Path $script:neRoot 'bun-b\staging-root') `
            -BunListPath $bunList -BunEnabled

        $report = Export-OSyncNpm -Config $cfg -StagingDir $stagingDir

        # No extra warming - only the npm entry was warmed.
        $specs = @(InModuleScope OfflineSync { @($script:BunSpecs) })
        ($specs -join ',') | Should -Be 'is-odd@3.0.1'

        $report.bun.enabled | Should -Be $true
        $report.bun.listPath | Should -Be $bunList
        $report.bun.entriesAdded | Should -Be 0
        $report.bun.delivered | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $stagingDir 'npm\bun-packages.txt')) | Should -BeFalse
    }

    It 'skips bun warming and delivery when the bun list is empty (comments only)' {
        $npmList = New-NeTempFile -Name 'bun-c\npm-list.txt' -Content "is-odd@3.0.1"
        $bunList = New-NeTempFile -Name 'bun-c\bun-list.txt' -Content "# comments only`n# an empty bun list is legal"
        $runtime = New-NeTempFile -Name 'bun-c\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $stagingDir = Join-Path $script:neRoot 'bun-c\gen1'
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'bun-c\repo') `
            -StagingRoot (Join-Path $script:neRoot 'bun-c\staging-root') `
            -BunListPath $bunList -BunEnabled

        $report = Export-OSyncNpm -Config $cfg -StagingDir $stagingDir

        $specs = @(InModuleScope OfflineSync { @($script:BunSpecs) })
        ($specs -join ',') | Should -Be 'is-odd@3.0.1'

        $report.bun.enabled | Should -Be $true
        $report.bun.entriesAdded | Should -Be 0
        $report.bun.delivered | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $stagingDir 'npm\bun-packages.txt')) | Should -BeFalse
    }

    It 'behaves like the baseline when the config has no pins.bun (bun disabled, no delivery)' {
        $npmList = New-NeTempFile -Name 'bun-d\npm-list.txt' -Content "is-odd@3.0.1"
        $bunList = New-NeTempFile -Name 'bun-d\bun-list.txt' -Content "bun-only-pkg@1.0.0"
        $runtime = New-NeTempFile -Name 'bun-d\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $stagingDir = Join-Path $script:neRoot 'bun-d\gen1'
        # Even with paths.bunList configured, an absent pins.bun section keeps
        # the export identical to the pre-bun baseline: the bun list is never
        # read, nothing extra is warmed, nothing is delivered.
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'bun-d\repo') `
            -StagingRoot (Join-Path $script:neRoot 'bun-d\staging-root') `
            -BunListPath $bunList

        $report = Export-OSyncNpm -Config $cfg -StagingDir $stagingDir

        $specs = @(InModuleScope OfflineSync { @($script:BunSpecs) })
        ($specs -join ',') | Should -Be 'is-odd@3.0.1'

        $report.bun.enabled | Should -Be $false
        $report.bun.listPath | Should -BeNullOrEmpty
        $report.bun.entriesAdded | Should -Be 0
        $report.bun.delivered | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $stagingDir 'npm\bun-packages.txt')) | Should -BeFalse
    }

    It 'skips bun when enabled but the config has no paths.bunList key (no error)' {
        $npmList = New-NeTempFile -Name 'bun-e\npm-list.txt' -Content "is-odd@3.0.1"
        $runtime = New-NeTempFile -Name 'bun-e\runtime-winget.txt' -Content "OpenJS.NodeJS.LTS@24.19.0`n"
        $stagingDir = Join-Path $script:neRoot 'bun-e\gen1'
        # pins.bun present (bun enabled) but no paths.bunList key:
        # Resolve-OSyncConfigPath returns $null and the merge is skipped.
        $cfg = New-NeConfig -VerdaccioVersion '6.10.2' -NpmListPath $npmList `
            -RuntimeWhitelistPath $runtime -RepoRoot (Join-Path $script:neRoot 'bun-e\repo') `
            -StagingRoot (Join-Path $script:neRoot 'bun-e\staging-root') `
            -BunEnabled

        $report = Export-OSyncNpm -Config $cfg -StagingDir $stagingDir

        $specs = @(InModuleScope OfflineSync { @($script:BunSpecs) })
        ($specs -join ',') | Should -Be 'is-odd@3.0.1'

        $report.bun.enabled | Should -Be $true
        $report.bun.listPath | Should -BeNullOrEmpty
        $report.bun.entriesAdded | Should -Be 0
        $report.bun.delivered | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $stagingDir 'npm\bun-packages.txt')) | Should -BeFalse
    }
}
