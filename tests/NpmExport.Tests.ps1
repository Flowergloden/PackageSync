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
    # Optional npm local-package fixture: -NpmLocalDirs adds the
    # 'paths.npmLocalDirs' key (presence-gated; passing an EMPTY array is
    # legal and must behave exactly like the absent key). The key is only
    # added when the parameter is actually bound, so the default config
    # shape stays identical to the pre-local baseline.
    function New-NeConfig {
        param(
            [string]$VerdaccioVersion,
            [string]$NpmListPath,
            [string]$RuntimeWhitelistPath,
            [string]$RepoRoot,
            [string]$StagingRoot,
            [string]$BunListPath,
            [switch]$BunEnabled,
            [object[]]$NpmLocalDirs
        )
        $paths = [pscustomobject]@{
            npmList          = $NpmListPath
            runtimeWhitelist = $RuntimeWhitelistPath
        }
        if (-not [string]::IsNullOrWhiteSpace($BunListPath)) {
            $paths | Add-Member -NotePropertyName bunList -NotePropertyValue $BunListPath -Force
        }
        if ($PSBoundParameters.ContainsKey('NpmLocalDirs')) {
            # The parameter is typed [object[]], so it is already an array
            # (empty, single-element, or multi-element). Avoid double-wrapping.
            $paths | Add-Member -NotePropertyName npmLocalDirs -NotePropertyValue $NpmLocalDirs -Force
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

    It 'allows anonymous publish ($all) on both scoped and unscoped package rules' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\gen\npm\storage' -Port 4874
        $yaml | Should -Match '(?m)^\s+publish:\s*\$all\s*$'
        ([regex]::Matches($yaml, '(?m)^\s+publish:\s*\$all\s*$')).Count | Should -Be 2
    }

    It 'sets max_body_size to 100mb so local private tarballs do not hit the default 413 limit' {
        $yaml = New-OSyncVerdaccioAYaml -StorageDir 'D:\gen\npm\storage' -Port 4874
        $yaml | Should -Match '(?m)^max_body_size:\s*100mb\s*$'
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

    It 'contains no uplinks, proxy or publish keys' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $yaml | Should -Not -Match '(?im)^\s*(uplinks|proxy|publish)\s*:'
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

    It 'rejects content with a publish key' {
        $yaml = New-OSyncVerdaccioBYaml -Port 4873
        $tampered = $yaml + "`npublish: \$all`n"
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

Describe 'Read-ONpmPackageJson' {
    # The local-package discovery reader: package.json -> { Name, Version },
    # throwing NAMING THE DIR on any problem so the caller can record a
    # failed entry and keep going with the remaining package dirs.
    It 'returns name and version from a valid package.json' {
        $dir = Join-Path $script:neRoot 'readpkg\ok'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'), '{ "name": "my-pkg", "version": "1.2.3" }', (New-Object System.Text.UTF8Encoding($false)))
        $pkg = InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Read-ONpmPackageJson -PackageDir $dir
        }
        $pkg.Name | Should -Be 'my-pkg'
        $pkg.Version | Should -Be '1.2.3'
    }

    It 'throws naming the dir when package.json is missing' {
        $dir = Join-Path $script:neRoot 'readpkg\missing'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $err = $null
        try {
            InModuleScope OfflineSync -ArgumentList $dir {
                param($dir)
                Read-ONpmPackageJson -PackageDir $dir
            } | Out-Null
        }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike "*$dir*"
    }

    It 'throws naming the dir when version is missing' {
        $dir = Join-Path $script:neRoot 'readpkg\nover'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'), '{ "name": "my-pkg" }', (New-Object System.Text.UTF8Encoding($false)))
        $err = $null
        try {
            InModuleScope OfflineSync -ArgumentList $dir {
                param($dir)
                Read-ONpmPackageJson -PackageDir $dir
            } | Out-Null
        }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike "*version*"
        $err.Exception.Message | Should -BeLike "*$dir*"
    }

    It 'throws naming the dir when the JSON is malformed' {
        $dir = Join-Path $script:neRoot 'readpkg\bad'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'), '{ not json', (New-Object System.Text.UTF8Encoding($false)))
        $err = $null
        try {
            InModuleScope OfflineSync -ArgumentList $dir {
                param($dir)
                Read-ONpmPackageJson -PackageDir $dir
            } | Out-Null
        }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -BeLike "*not valid JSON*"
    }
}

Describe 'Get-ONpmLocalPackageDirs' {
    # Discovery semantics: a configured dir that itself holds package.json IS
    # one package dir; otherwise only IMMEDIATE subdirs are scanned; a dir
    # yielding nothing is a Warning entry; a missing dir is an Error entry;
    # candidates are de-duplicated by LOWERCASED package name (first wins).
    It 'treats a dir containing package.json as one package dir' {
        $dir = Join-Path $script:neRoot 'disc\self'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'), '{ "name": "self-pkg", "version": "1.0.0" }', (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Get-ONpmLocalPackageDirs -Dirs @($dir)
        })
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'self-pkg'
        $r[0].Version | Should -Be '1.0.0'
        $r[0].Dir | Should -Be $dir
        $r[0].Error | Should -BeNullOrEmpty
        $r[0].Warning | Should -BeNullOrEmpty
    }

    It 'scans immediate subdirs only (non-recursive)' {
        $parent = Join-Path $script:neRoot 'disc\parent'
        $child = Join-Path $parent 'child-pkg'
        $grandchild = Join-Path $child 'grandchild-pkg'
        New-Item -ItemType Directory -Path $grandchild -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $child 'package.json'), '{ "name": "child-pkg", "version": "2.0.0" }', (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $grandchild 'package.json'), '{ "name": "grandchild-pkg", "version": "3.0.0" }', (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $parent {
            param($parent)
            Get-ONpmLocalPackageDirs -Dirs @($parent)
        })
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'child-pkg'
    }

    It 'reports a missing dir as an Error entry' {
        $missing = Join-Path $script:neRoot 'disc\missing'
        $r = @(InModuleScope OfflineSync -ArgumentList $missing {
            param($missing)
            Get-ONpmLocalPackageDirs -Dirs @($missing)
        })
        $r.Count | Should -Be 1
        $r[0].Error | Should -Not -BeNullOrEmpty
        $r[0].Error | Should -BeLike '*not found*'
        $r[0].Name | Should -BeNullOrEmpty
    }

    It 'reports a dir with no package.json as a Warning entry' {
        $empty = Join-Path $script:neRoot 'disc\empty'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $r = @(InModuleScope OfflineSync -ArgumentList $empty {
            param($empty)
            Get-ONpmLocalPackageDirs -Dirs @($empty)
        })
        $r.Count | Should -Be 1
        $r[0].Warning | Should -Not -BeNullOrEmpty
        $r[0].Error | Should -BeNullOrEmpty
        $r[0].Name | Should -BeNullOrEmpty
    }

    It 'dedups by lowercased name - first wins, later gets a Warning entry' {
        $dirA = Join-Path $script:neRoot 'disc\a'
        $dirB = Join-Path $script:neRoot 'disc\b'
        New-Item -ItemType Directory -Path $dirA -Force | Out-Null
        New-Item -ItemType Directory -Path $dirB -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dirA 'package.json'), '{ "name": "Dup-Pkg", "version": "1.0.0" }', (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText((Join-Path $dirB 'package.json'), '{ "name": "dup-pkg", "version": "9.9.9" }', (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dirA, $dirB {
            param($dirA, $dirB)
            Get-ONpmLocalPackageDirs -Dirs @($dirA, $dirB)
        })
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'Dup-Pkg'
        $r[0].Version | Should -Be '1.0.0'
        $r[0].Warning | Should -BeNullOrEmpty
        $r[1].Name | Should -Be 'dup-pkg'
        $r[1].Warning | Should -BeLike '*duplicate*'
    }
# --- deps-manifest-dir discovery ---
    # A package.json that lacks name/version but has a non-empty
    # 'dependencies' object becomes a "deps-manifest" entry (Deps
    # property = array of 'name@spec' strings, Warning explaining the
    # treatment). Invalid JSON or no dependencies at all are still
    # Error entries; publishable packages (name+version present) are
    # unchanged.
    It 'treats a deps-only package.json as a Deps entry (no name/version, has dependencies)' {
        $dir = Join-Path $script:neRoot 'depsdisc\ok'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'),
            '{ "dependencies": { "@opencode-ai/plugin": "1.18.21", "is-odd": "^3.0.0" } }',
            (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Get-ONpmLocalPackageDirs -Dirs @($dir)
        })
        $r.Count | Should -Be 1
        $r[0].Name | Should -BeNullOrEmpty
        $r[0].Version | Should -BeNullOrEmpty
        $r[0].Error | Should -BeNullOrEmpty
        $r[0].Warning | Should -BeLike '*no name/version*treated as a dependency manifest*'
        $r[0].Deps | Should -Not -BeNullOrEmpty
        @($r[0].Deps).Count | Should -Be 2
        @($r[0].Deps | Where-Object { $_ -eq '@opencode-ai/plugin@1.18.21' }).Count | Should -Be 1
        @($r[0].Deps | Where-Object { $_ -eq 'is-odd@^3.0.0' }).Count | Should -Be 1
    }

    It 'keeps a publishable package.json (name+version) unchanged - no Deps entry' {
        $dir = Join-Path $script:neRoot 'depsdisc\publishable'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'),
            '{ "name": "my-pkg", "version": "1.0.0", "dependencies": { "is-odd": "^3.0.0" } }',
            (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Get-ONpmLocalPackageDirs -Dirs @($dir)
        })
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'my-pkg'
        $r[0].Version | Should -Be '1.0.0'
        $r[0].Deps | Should -BeNullOrEmpty
        $r[0].Error | Should -BeNullOrEmpty
        $r[0].Warning | Should -BeNullOrEmpty
    }

    It 'reports an Error mentioning both requirements when package.json has no name/version AND no dependencies' {
        $dir = Join-Path $script:neRoot 'depsdisc\nodeps'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'),
            '{ "description": "no deps, no name" }',
            (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Get-ONpmLocalPackageDirs -Dirs @($dir)
        })
        $r.Count | Should -Be 1
        $r[0].Error | Should -Not -BeNullOrEmpty
        $r[0].Error | Should -BeLike '*publishable package needs name+version*'
        $r[0].Error | Should -BeLike '*dependency manifest needs a non-empty*dependencies*object*'
        $r[0].Deps | Should -BeNullOrEmpty
    }

    It 'reports an Error mentioning both requirements when dependencies is empty' {
        $dir = Join-Path $script:neRoot 'depsdisc\emptydeps'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'),
            '{ "dependencies": {} }',
            (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Get-ONpmLocalPackageDirs -Dirs @($dir)
        })
        $r.Count | Should -Be 1
        $r[0].Error | Should -Not -BeNullOrEmpty
        $r[0].Error | Should -BeLike '*publishable package needs name+version*'
        $r[0].Error | Should -BeLike '*dependency manifest needs a non-empty*dependencies*object*'
        $r[0].Deps | Should -BeNullOrEmpty
    }

    It 'does NOT attempt deps fallback on invalid JSON - Error as before' {
        $dir = Join-Path $script:neRoot 'depsdisc\invalidjson'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'),
            '{ this is not json',
            (New-Object System.Text.UTF8Encoding($false)))
        $r = @(InModuleScope OfflineSync -ArgumentList $dir {
            param($dir)
            Get-ONpmLocalPackageDirs -Dirs @($dir)
        })
        $r.Count | Should -Be 1
        $r[0].Error | Should -Not -BeNullOrEmpty
        $r[0].Error | Should -BeLike '*not valid JSON*'
        $r[0].Deps | Should -BeNullOrEmpty
    }
}

Describe 'Test-ONpmPackageInStorage' {
    # Belt-and-braces publish verification: the name-level dir must exist
    # under the one-shot storage; scoped names map to the two-level
    # '@scope\name' path.
    It 'is true when the name-level dir exists under storage' {
        $storage = Join-Path $script:neRoot 'storage\ok'
        New-Item -ItemType Directory -Path (Join-Path $storage 'my-pkg') -Force | Out-Null
        InModuleScope OfflineSync -ArgumentList $storage {
            param($storage)
            Test-ONpmPackageInStorage -StorageDir $storage -Name 'my-pkg'
        } | Should -BeTrue
    }

    It 'maps a scoped name to the two-level @scope\name path' {
        $storage = Join-Path $script:neRoot 'storage\scoped'
        New-Item -ItemType Directory -Path (Join-Path $storage '@my-scope\my-pkg') -Force | Out-Null
        InModuleScope OfflineSync -ArgumentList $storage {
            param($storage)
            Test-ONpmPackageInStorage -StorageDir $storage -Name '@my-scope/my-pkg'
        } | Should -BeTrue
    }

    It 'is false when the package is not in storage' {
        $storage = Join-Path $script:neRoot 'storage\missing'
        New-Item -ItemType Directory -Path $storage -Force | Out-Null
        InModuleScope OfflineSync -ArgumentList $storage {
            param($storage)
            Test-ONpmPackageInStorage -StorageDir $storage -Name 'not-there'
        } | Should -BeFalse
    }
}

Describe 'Invoke-ONpmPublish' {
    # The real publish helper against the fake npm.cmd (args logged via
    # FAKE_NPM_ARGSLOG): --access public is MANDATORY (npm defaults scoped
    # publishes to restricted, which Verdaccio rejects), --userconfig carries
    # the one-shot dummy-auth npmrc (npm refuses credential-less publish
    # client-side while Verdaccio publish: $all accepts any credential) and
    # --no-update-notifier keeps the npm packument out of the storage
    # snapshot; the registry URL must be the one-shot A registry.
    BeforeEach { Reset-NewFakeEnv }

    It 'publishes with --access public and the dummy-auth --userconfig against the given registry' {
        $argsLog = Join-Path $script:neRoot ('publish-args-' + [guid]::NewGuid().ToString('N') + '.log')
        $env:FAKE_NPM_ARGSLOG = $argsLog
        $env:FAKE_NPM_EXIT = '0'
        $npmCmd = Join-Path $script:fakeBin 'npm.cmd'
        $userConfig = Join-Path $TestDrive 'publish.npmrc'
        $r = InModuleScope OfflineSync -ArgumentList $npmCmd, $userConfig {
            param($npmCmd, $userConfig)
            Invoke-ONpmPublish -NpmExe $npmCmd -PackageDir 'D:\pkg-a' -Registry 'http://127.0.0.1:4874' -UserConfig $userConfig
        }
        $r.ExitCode | Should -Be 0
        $line = [System.IO.File]::ReadAllText($argsLog)
        $line | Should -BeLike '*publish D:\pkg-a*'
        $line | Should -BeLike '*--registry http://127.0.0.1:4874*'
        $line | Should -BeLike "*--userconfig $userConfig*"
        $line | Should -BeLike '*--access public*'
        $line | Should -BeLike '*--ignore-scripts*'
        $line | Should -BeLike '*--no-audit*'
        $line | Should -BeLike '*--no-fund*'
        $line | Should -BeLike '*--no-update-notifier*'
        $line | Should -BeLike '*--loglevel error*'
    }

    It 'returns the exit code and output on failure' {
        $env:FAKE_NPM_EXIT = '1'
        $npmCmd = Join-Path $script:fakeBin 'npm.cmd'
        $r = InModuleScope OfflineSync -ArgumentList $npmCmd {
            param($npmCmd)
            Invoke-ONpmPublish -NpmExe $npmCmd -PackageDir 'D:\pkg-a' -Registry 'http://127.0.0.1:4874' -UserConfig (Join-Path $TestDrive 'publish.npmrc')
        }
        $r.ExitCode | Should -Be 1
    }
}

Describe 'Export-OSyncNpm local package prewarm' {
    # The npm LOCAL package prewarm (presence-gated on paths.npmLocalDirs):
    # discovered local packages are published into the SAME one-shot Verdaccio
    # snapshot (phase 1 - ALL publishes first, so local-to-local deps resolve
    # regardless of discovery order) and then install-verified as name@version
    # with a per-package FRESH cache (phase 2). When at least one package was
    # published, <staging>\npm\local-packages.txt is delivered with
    # 'name@version  # local: <source dir>' lines (same parser as
    # packages.txt). An absent key or an empty array keeps the export
    # byte-identical to the pre-local baseline.
    #
    # Same machinery as the bun suite: the REAL Export-OSyncNpm runs against
    # the fake npm.cmd, the server/robocopy/publish/install calls are MOCKED
    # via InModuleScope, and the REAL Test-ONpmPackageInStorage verifies the
    # storage marker dirs the tests pre-create (belt-and-braces publish
    # verification stays exercised).
    BeforeAll {
        # Fixture helpers for the local-package prewarm suite. Defined in
        # BeforeAll so they are visible to every It block (Pester 5 scopes
        # functions defined directly in a Describe body inconsistently).

        function New-LocalPkgDir {
            # Creates a package dir with a package.json; -Json overrides the
            # default well-formed content (for malformed/missing-version cases).
            param([string]$Parent, [string]$Name, [string]$Version, [string]$Json = $null)
            $dir = Join-Path $Parent $Name
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ([string]::IsNullOrWhiteSpace($Json)) {
                $Json = '{"name":"' + $Name + '","version":"' + $Version + '"}'
            }
            [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'), $Json, (New-Object System.Text.UTF8Encoding($false)))
            return $dir
        }

        function New-DepsManifestDir {
            # Creates a deps-manifest dir (package.json with dependencies
            # but no name/version). -DepsJson is the JSON value for the
            # 'dependencies' object (e.g. '{"is-odd":"^3.0.0"}').
            param([string]$Parent, [string]$DirName, [string]$DepsJson)
            $dir = Join-Path $Parent $DirName
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $pkgJson = '{ "dependencies": ' + $DepsJson + ' }'
            [System.IO.File]::WriteAllText((Join-Path $dir 'package.json'), $pkgJson, (New-Object System.Text.UTF8Encoding($false)))
            return $dir
        }

        function New-LocalExportFixture {
            # Standard export fixture: npm list + runtime whitelist + config.
            # -NoNpmLocalDirs leaves the paths.npmLocalDirs key ABSENT (baseline
            # shape); otherwise the key is added with the given dirs.
            param(
                [string]$Name,
                [string[]]$NpmLocalDirs,
                [switch]$NoNpmLocalDirs,
                [string]$NpmListContent = 'is-odd@3.0.1'
            )
            $root = Join-Path $script:neRoot ('local-' + $Name)
            $npmList = New-NeTempFile -Name ("local-$Name\npm-list.txt") -Content $NpmListContent
            $runtime = New-NeTempFile -Name ("local-$Name\runtime-winget.txt") -Content "OpenJS.NodeJS.LTS@24.19.0`n"
            $stagingDir = Join-Path $root 'gen1'
            $cfgArgs = @{
                VerdaccioVersion     = '6.10.2'
                NpmListPath          = $npmList
                RuntimeWhitelistPath = $runtime
                RepoRoot             = Join-Path $root 'repo'
                StagingRoot          = Join-Path $root 'staging-root'
            }
        if (-not $NoNpmLocalDirs) {
            # $NpmLocalDirs is already an array; pass it through without
            # double-wrapping so New-NeConfig sees the intended elements.
            $cfgArgs.NpmLocalDirs = $NpmLocalDirs
        }
            $cfg = New-NeConfig @cfgArgs
            return [pscustomobject]@{ Config = $cfg; StagingDir = $stagingDir; NpmList = $npmList; Root = $root }
        }

        function New-LocalStorageMarker {
            # Pre-creates the storage name-level dirs the REAL
            # Test-ONpmPackageInStorage checks after the (mocked) publish.
            param([string]$StagingDir, [string[]]$Names)
            foreach ($n in @($Names)) {
                $p = Join-Path $StagingDir ('npm\storage\' + $n.Replace('/', '\'))
                New-Item -ItemType Directory -Path $p -Force | Out-Null
            }
        }
    }

    BeforeEach {
        Reset-NewFakeEnv
        $env:FAKE_NPM_ENGINES = '{"node":">=22"}'
        $env:FAKE_NPM_EXIT = '0'
        InModuleScope OfflineSync {
            $script:LocalPublishCalls = @()
            $script:LocalInstallCalls = @()
            $script:LocalRobocopyCalls = @()
            $script:LocalCallOrder = @()
            $script:LocalPublishFailOnCall = 0
            $script:LocalInstallFailSpecs = @()
            Mock Get-ONodeExe { return 'C:\dummy\node.exe' }
            Mock Test-OSyncPortListening { return $false }
            Mock Wait-OSyncPortListening { return $true }
            Mock Start-OVerdaccioProcess { return [pscustomobject]@{ Id = 12345 } }
            Mock Stop-OVerdaccioProcess { }
            Mock Start-Sleep { }
            Mock Invoke-OSyncRobocopy {
                param([string]$Source, [string]$Destination, [string[]]$ExtraArgs = @())
                $script:LocalRobocopyCalls += [pscustomobject]@{ Source = $Source; Destination = $Destination; ExtraArgs = @($ExtraArgs) }
                # Simulate the copy: the publish step must receive an EXISTING
                # local dir (the real flow robocopies the package tree first).
                if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
                    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
                }
                return 0
            }
            Mock Get-ONpmExportLocalWorkRoot {
                # The fake verdaccio install "lands" here: pre-seed the entry
                # script the export checks right after the (fake, exit-0)
                # install, exactly like the bun suite.
                $script:LocalWorkRoot = Join-Path $TestDrive ('local-work-' + [guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path (Join-Path $script:LocalWorkRoot 'verdaccio-a\node_modules\verdaccio\bin') -Force | Out-Null
                [System.IO.File]::WriteAllText((Join-Path $script:LocalWorkRoot 'verdaccio-a\node_modules\verdaccio\bin\verdaccio'), 'fake entry', (New-Object System.Text.UTF8Encoding($false)))
                return $script:LocalWorkRoot
            }
            Mock Invoke-ONpmPublish {
                param([string]$NpmExe, [string]$PackageDir, [string]$Registry, [string]$UserConfig, [bool]$Echo = $false)
                $script:LocalPublishCalls += [pscustomobject]@{ PackageDir = $PackageDir; Registry = $Registry; UserConfig = $UserConfig; Echo = $Echo }
                # Capture the one-shot dummy-auth npmrc WHILE the export still
                # has it on disk (the scratch root is deleted at the end of
                # Export-OSyncNpm, before any assertion can read the file).
                $script:LocalNpmrcContent = [System.IO.File]::ReadAllText($UserConfig)
                $script:LocalCallOrder += ('publish:' + (Split-Path -Leaf $PackageDir))
                if ($script:LocalPublishFailOnCall -gt 0 -and @($script:LocalPublishCalls).Count -eq $script:LocalPublishFailOnCall) {
                    return [pscustomobject]@{ ExitCode = 1; Output = @('npm ERR! E402 private package') }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = @('ok') }
            }
            Mock Invoke-ONpmInstall {
                param([string]$NpmExe, [string]$Spec, [string]$Registry, [string]$Prefix, [string]$CacheDir, [bool]$Echo = $false)
                $script:LocalInstallCalls += [pscustomobject]@{ Spec = $Spec; Registry = $Registry; Prefix = $Prefix; CacheDir = $CacheDir; Echo = $Echo }
                $script:LocalCallOrder += ('install:' + $Spec)
                if (@($script:LocalInstallFailSpecs) -contains $Spec) {
                    return [pscustomobject]@{ ExitCode = 1; Output = @('npm ERR! 404 not found') }
                }
                return [pscustomobject]@{ ExitCode = 0; Output = @('ok') }
            }
        }
    }

    It 'publishes all discovered packages first, then install-verifies each, and delivers local-packages.txt' {
        $root = Join-Path $script:neRoot 'local-happy'
        # Package A: the configured dir IS the package dir (self-dir).
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'local-self' -Version '1.0.0'
        # Package B: found via the immediate-subdir scan of the configured dir.
        $parentDir = Join-Path $root 'src-parent'
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        $childDir = New-LocalPkgDir -Parent $parentDir -Name 'local-child' -Version '2.0.0'
        $fx = New-LocalExportFixture -Name 'happy' -NpmLocalDirs @($selfDir, $parentDir)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('local-self', 'local-child')

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        # Phase separation: every publish happened before ANY local install.
        $order = @(InModuleScope OfflineSync { @($script:LocalCallOrder) })
        $publishIdx = @(for ($i = 0; $i -lt $order.Count; $i++) { if ($order[$i] -like 'publish:*') { $i } })
        $localInstallIdx = @(for ($i = 0; $i -lt $order.Count; $i++) { if ($order[$i] -like 'install:local-*') { $i } })
        $publishIdx.Count | Should -Be 2
        $localInstallIdx.Count | Should -Be 2
        ($publishIdx[-1] -lt $localInstallIdx[0]) | Should -BeTrue

        # Publish: one call per package, against the one-shot registry, from a
        # LOCAL scratch copy (never the original source dir).
        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 2
        foreach ($p in $pubs) {
            $p.Registry | Should -Be 'http://127.0.0.1:4874'
            $p.PackageDir | Should -Not -Be $selfDir
            $p.PackageDir | Should -Not -Be $childDir
            $p.PackageDir | Should -BeLike '*local-pkg-*'
        }

        # Dummy-auth npmrc: every publish used the one-shot --userconfig, and
        # the file content keys the dummy _auth to the exact one-shot
        # host:port (npm refuses credential-less publish client-side while
        # publish: $all accepts any credential; the constant is base64
        # 'user:pass', a dummy - never a real credential, loopback-only).
        $pubs[0].UserConfig | Should -BeLike '*publish.npmrc'
        $pubs[1].UserConfig | Should -Be $pubs[0].UserConfig
        $npmrcText = InModuleScope OfflineSync { $script:LocalNpmrcContent }
        $npmrcText | Should -Match '//127\.0\.0\.1:4874/:_auth="dXNlcjpwYXNz"'

        # Install-verify: one call per published package with a per-package
        # fresh cache dir.
        $installs = @(InModuleScope OfflineSync { @($script:LocalInstallCalls) })
        $localInstalls = @($installs | Where-Object { $_.Spec -like 'local-*' })
        $localInstalls.Count | Should -Be 2
        @($localInstalls | Where-Object { $_.Spec -eq 'local-self@1.0.0' }).Count | Should -Be 1
        @($localInstalls | Where-Object { $_.Spec -eq 'local-child@2.0.0' }).Count | Should -Be 1
        $localInstalls[0].CacheDir | Should -Not -Be $localInstalls[1].CacheDir
        $localInstalls[0].Prefix | Should -BeLike '*install-local-*'

        # Report.
        $report.local.enabled | Should -BeTrue
        $report.local.published.Count | Should -Be 2
        $report.local.failed.Count | Should -Be 0
        $report.local.listPath | Should -Be (Join-Path $fx.StagingDir 'npm\local-packages.txt')
        @($report.local.published | Where-Object { $_.Name -eq 'local-self' }).Count | Should -Be 1
        @($report.local.published | Where-Object { $_.Name -eq 'local-child' }).Count | Should -Be 1

        # Delivery contract: parses with the same parser as packages.txt and
        # carries the '# local:' provenance comment.
        $listPath = Join-Path $fx.StagingDir 'npm\local-packages.txt'
        (Test-Path -LiteralPath $listPath) | Should -BeTrue
        $parsed = @(Read-OSyncNpmList -Path $listPath)
        $parsed.Count | Should -Be 2
        @($parsed | Where-Object { $_.Name -eq 'local-self' -and $_.Version -eq '1.0.0' }).Count | Should -Be 1
        @($parsed | Where-Object { $_.Name -eq 'local-child' -and $_.Version -eq '2.0.0' }).Count | Should -Be 1
        $text = [System.IO.File]::ReadAllText($listPath)
        $text | Should -Match 'local-self@1\.0\.0\s+# local: '
        $text | Should -Match 'local-child@2\.0\.0\s+# local: '
    }

    It 'records a publish failure in report.local.failed and still processes the other package' {
        $root = Join-Path $script:neRoot 'local-pubfail'
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'local-self' -Version '1.0.0'
        $parentDir = Join-Path $root 'src-parent'
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        $childDir = New-LocalPkgDir -Parent $parentDir -Name 'local-child' -Version '2.0.0'
        $fx = New-LocalExportFixture -Name 'pubfail' -NpmLocalDirs @($selfDir, $parentDir)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('local-self', 'local-child')
        InModuleScope OfflineSync { $script:LocalPublishFailOnCall = 1 }

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $report.local.failed.Count | Should -Be 1
        $report.local.failed[0].Name | Should -Be 'local-self'
        $report.local.failed[0].SourceDir | Should -Be $selfDir
        $report.local.failed[0].Error | Should -BeLike '*npm publish failed*'

        # The failed package was NOT install-verified; the other one was.
        $installs = @(InModuleScope OfflineSync { @($script:LocalInstallCalls) })
        $localInstalls = @($installs | Where-Object { $_.Spec -like 'local-*' })
        $localInstalls.Count | Should -Be 1
        $localInstalls[0].Spec | Should -Be 'local-child@2.0.0'

        $report.local.published.Count | Should -Be 1
        $report.local.published[0].Name | Should -Be 'local-child'
    }

    It 'records an install-verify failure after a successful publish' {
        $root = Join-Path $script:neRoot 'local-instfail'
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'local-self' -Version '1.0.0'
        $parentDir = Join-Path $root 'src-parent'
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        $childDir = New-LocalPkgDir -Parent $parentDir -Name 'local-child' -Version '2.0.0'
        $fx = New-LocalExportFixture -Name 'instfail' -NpmLocalDirs @($selfDir, $parentDir)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('local-self', 'local-child')
        InModuleScope OfflineSync { $script:LocalInstallFailSpecs = @('local-self@1.0.0') }

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        # Both packages were published (publish happens before the install
        # phase), the failing install-verify is recorded as a failure.
        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 2
        $report.local.published.Count | Should -Be 2
        $report.local.failed.Count | Should -Be 1
        $report.local.failed[0].Name | Should -Be 'local-self'
        $report.local.failed[0].Error | Should -BeLike '*install-verify failed*'
    }

    It 'is identical to the baseline when the config has no paths.npmLocalDirs key' {
        $fx = New-LocalExportFixture -Name 'gateoff' -NoNpmLocalDirs
        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 0
        $report.local.enabled | Should -BeFalse
        $report.local.published.Count | Should -Be 0
        $report.local.failed.Count | Should -Be 0
        $report.local.dirs.Count | Should -Be 0
        $report.local.listPath | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $fx.StagingDir 'npm\local-packages.txt')) | Should -BeFalse
    }

    It 'treats an empty paths.npmLocalDirs array exactly like the absent key' {
        $fx = New-LocalExportFixture -Name 'gateempty' -NpmLocalDirs @()
        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 0
        $report.local.enabled | Should -BeFalse
        $report.local.published.Count | Should -Be 0
        $report.local.failed.Count | Should -Be 0
        $report.local.listPath | Should -BeNullOrEmpty
        (Test-Path -LiteralPath (Join-Path $fx.StagingDir 'npm\local-packages.txt')) | Should -BeFalse
    }

    It 'records a missing configured dir as a failed entry and continues with the others' {
        $root = Join-Path $script:neRoot 'local-missing'
        $missingDir = Join-Path $root 'does-not-exist'
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'local-self' -Version '1.0.0'
        $fx = New-LocalExportFixture -Name 'missing' -NpmLocalDirs @($missingDir, $selfDir)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('local-self')

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $report.local.failed.Count | Should -Be 1
        $report.local.failed[0].SourceDir | Should -Be $missingDir
        $report.local.failed[0].Error | Should -BeLike '*not found*'
        $report.local.published.Count | Should -Be 1
        $report.local.published[0].Name | Should -Be 'local-self'
    }

    It 'records a package.json without a version as a failed entry and never publishes it' {
        $root = Join-Path $script:neRoot 'local-nover'
        $badDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'no-version-pkg' -Version '1.0.0' -Json '{ "name": "no-version-pkg" }'
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src2') -Name 'local-self' -Version '1.0.0'
        $fx = New-LocalExportFixture -Name 'nover' -NpmLocalDirs @($badDir, $selfDir)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('local-self')

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $report.local.failed.Count | Should -Be 1
        $report.local.failed[0].SourceDir | Should -Be $badDir
        $report.local.failed[0].Error | Should -BeLike '*version*'
        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 1
        $report.local.published.Count | Should -Be 1
        $report.local.published[0].Name | Should -Be 'local-self'
    }

    It 'records a malformed package.json as a failed entry' {
        $root = Join-Path $script:neRoot 'local-malformed'
        $badDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'broken-pkg' -Version '1.0.0' -Json '{ this is not json'
        $fx = New-LocalExportFixture -Name 'malformed' -NpmLocalDirs @($badDir)

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $report.local.failed.Count | Should -Be 1
        $report.local.failed[0].SourceDir | Should -Be $badDir
        $report.local.failed[0].Error | Should -BeLike '*not valid JSON*'
        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 0
        $report.local.published.Count | Should -Be 0
    }

    It 'publishes a duplicate package name only once (first occurrence wins)' {
        $root = Join-Path $script:neRoot 'local-dedup'
        $dirA = New-LocalPkgDir -Parent (Join-Path $root 'src-a') -Name 'dup-pkg' -Version '1.0.0'
        $dirB = New-LocalPkgDir -Parent (Join-Path $root 'src-b') -Name 'dup-pkg' -Version '9.9.9'
        $fx = New-LocalExportFixture -Name 'dedup' -NpmLocalDirs @($dirA, $dirB)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('dup-pkg')

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 1
        $report.local.published.Count | Should -Be 1
        $report.local.published[0].Name | Should -Be 'dup-pkg'
        $report.local.published[0].Version | Should -Be '1.0.0'
        $report.local.published[0].SourceDir | Should -Be $dirA
        # The duplicate is a WARNING, not a failure.
        $report.local.failed.Count | Should -Be 0
    }

    It 'copies a UNC source dir to the local scratch and publishes only the local copy' {
        $uncDir = '\\fake-share\pkg'
        $fx = New-LocalExportFixture -Name 'unc' -NpmLocalDirs @($uncDir)
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('unc-pkg')
        # The UNC share does not exist on this machine - discovery is mocked
        # to return the UNC dir as a discovered package (the real discovery
        # path is covered by the other tests).
        InModuleScope OfflineSync {
            Mock Get-ONpmLocalPackageDirs {
                param([string[]]$Dirs)
                return @([pscustomobject]@{ Dir = '\\fake-share\pkg'; Name = 'unc-pkg'; Version = '1.0.0'; Error = $null; Warning = $null })
            }
        }

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        # Robocopy was invoked with the UNC source (the export also mirrors the
        # verdaccio install, so filter to the local-package copy).
        $robos = @(InModuleScope OfflineSync { @($script:LocalRobocopyCalls) })
        $localRobos = @($robos | Where-Object { $_.Source -eq $uncDir })
        $localRobos.Count | Should -Be 1
        $localRobos[0].Source | Should -Be $uncDir
        # ...and the publish step received the LOCAL scratch copy, never UNC.
        $pubs = @(InModuleScope OfflineSync { @($script:LocalPublishCalls) })
        $pubs.Count | Should -Be 1
        $pubs[0].PackageDir | Should -Not -Match '^\\\\'
        $pubs[0].PackageDir | Should -BeLike '*local-pkg-*'
        $report.local.published.Count | Should -Be 1
        $report.local.published[0].SourceDir | Should -Be $uncDir
    }

    It 'keeps packages.txt verbatim, b-yaml clean and warmed unaffected by the local flow' {
        $root = Join-Path $script:neRoot 'local-regress'
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'local-self' -Version '1.0.0'
        $fx = New-LocalExportFixture -Name 'regress' -NpmLocalDirs @($selfDir) -NpmListContent "is-odd@3.0.1`nleft-pad@1.3.0"
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('local-self')

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        # packages.txt is still the verbatim manifest copy (delivery contract).
        $packagesTxt = Join-Path $fx.StagingDir 'npm\packages.txt'
        ([System.IO.File]::ReadAllText($packagesTxt)) | Should -BeExactly ([System.IO.File]::ReadAllText($fx.NpmList))
        # b-yaml still passes the leak assertion.
        $bYaml = [System.IO.File]::ReadAllText((Join-Path $fx.StagingDir 'npm\verdaccio-b.yml'))
        Test-OSyncVerdaccioBYaml -Content $bYaml | Should -BeTrue
        # warmed is exactly the manifest entries - local packages are NOT
        # counted as warmed.
        $report.warmed.Count | Should -Be 2
        @($report.warmed | Where-Object { $_.Name -like 'local-*' }).Count | Should -Be 0
$report.local.published.Count | Should -Be 1
    }

    # --- /deps-manifest integration ---
    It 'warms deps specs from a deps-manifest dir and reports them in report.local.deps' {
        $root = Join-Path $script:neRoot 'deps-warm-basic'
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg' -DepsJson '{"@opencode-ai/plugin":"1.18.21","is-odd":"^3.0.0"}'
        $fx = New-LocalExportFixture -Name 'deps-warm-basic' -NpmLocalDirs @($depsDir) -NpmListContent 'left-pad@1.3.0'

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        # The manifest entry was warmed (main loop).
        $report.warmed.Count | Should -Be 1
        # No local published packages (deps-manifest dir is not publishable).
        $report.local.published.Count | Should -Be 0
        # Deps were warmed into the same one-shot registry.
        $report.local.deps.Count | Should -Be 2
        @($report.local.deps | Where-Object { $_.Status -eq 'warmed' }).Count | Should -Be 2
        @($report.local.deps | Where-Object { $_.Name -eq '@opencode-ai/plugin' -and $_.Spec -eq '@opencode-ai/plugin@1.18.21' }).Count | Should -Be 1
        @($report.local.deps | Where-Object { $_.Name -eq 'is-odd' -and $_.Spec -eq 'is-odd@^3.0.0' }).Count | Should -Be 1

        # Install mock was called for the deps specs.
        $installs = @(InModuleScope OfflineSync { @($script:LocalInstallCalls) })
        @($installs | Where-Object { $_.Spec -eq 'left-pad@1.3.0' }).Count | Should -Be 1
        @($installs | Where-Object { $_.Spec -eq '@opencode-ai/plugin@1.18.21' }).Count | Should -Be 1
        @($installs | Where-Object { $_.Spec -eq 'is-odd@^3.0.0' }).Count | Should -Be 1
    }

    It 'dedups deps specs against manifest entries and among deps dirs (first wins)' {
        $root = Join-Path $script:neRoot 'deps-dedup'
        # is-odd is in the npm manifest; it should be skipped from deps.
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg-a' -DepsJson '{"is-odd":"^3.0.0","some-dep":"1.0.0"}'
        # some-dep also appears in a second deps dir - should be skipped as duplicate.
        $depsDirB = New-DepsManifestDir -Parent (Join-Path $root 'deps-b') -DirName 'cfg-b' -DepsJson '{"some-dep":"2.0.0","other-dep":"^0.5.0"}'
        $fx = New-LocalExportFixture -Name 'deps-dedup' -NpmLocalDirs @($depsDir, $depsDirB) -NpmListContent 'is-odd@3.0.1'

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        # is-odd was already in manifest - skipped-duplicate.
        # some-dep from cfg-a: warmed. some-dep from cfg-b: skipped-duplicate.
        # other-dep: warmed.
        $deps = @($report.local.deps)
        @($deps | Where-Object { $_.Status -eq 'warmed' }).Count | Should -Be 2
        @($deps | Where-Object { $_.Status -eq 'skipped-duplicate' }).Count | Should -Be 2
        @($deps | Where-Object { $_.Name -eq 'is-odd' -and $_.Status -eq 'skipped-duplicate' }).Count | Should -Be 1
        @($deps | Where-Object { $_.Name -eq 'some-dep' -and $_.Spec -eq 'some-dep@1.0.0' -and $_.Status -eq 'warmed' }).Count | Should -Be 1
        @($deps | Where-Object { $_.Name -eq 'some-dep' -and $_.Spec -eq 'some-dep@2.0.0' -and $_.Status -eq 'skipped-duplicate' }).Count | Should -Be 1
        @($deps | Where-Object { $_.Name -eq 'other-dep' -and $_.Status -eq 'warmed' }).Count | Should -Be 1

        # Only 2 deps specs were actually warmed (is-odd is skipped via manifest dedup,
        # some-dep@2.0.0 skipped via inter-dir dedup).
        $installs = @(InModuleScope OfflineSync { @($script:LocalInstallCalls) })
        @($installs | Where-Object { $_.Spec -like 'deps-warm-*' -or ($_.Prefix -and $_.Prefix -like '*deps-warm*') }).Count
        # Check that warm specs include some-dep@1.0.0 and other-dep@^0.5.0 but NOT is-odd@^3.0.0
        $warmSpecs = @($installs | ForEach-Object { $_.Spec })
        $warmSpecs | Should -Contain 'some-dep@1.0.0'
        $warmSpecs | Should -Contain 'other-dep@^0.5.0'
        $warmSpecs | Should -Not -Contain 'is-odd@^3.0.0'
    }

    It "skips deps specs containing ':' with skipped-invalid-spec status" {
        $root = Join-Path $script:neRoot 'deps-invalidspec'
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg' -DepsJson '{"pkg-a":"1.0.0","pkg-b":"file:../local-x","pkg-c":"npm:@scope/legacy"}'
        $fx = New-LocalExportFixture -Name 'deps-invalidspec' -NpmLocalDirs @($depsDir) -NpmListContent 'is-odd@3.0.1'

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $deps = @($report.local.deps)
        $deps.Count | Should -Be 3
        @($deps | Where-Object { $_.Status -eq 'warmed' }).Count | Should -Be 1  # pkg-a
        @($deps | Where-Object { $_.Status -eq 'skipped-invalid-spec' }).Count | Should -Be 2  # pkg-b, pkg-c
        @($deps | Where-Object { $_.Name -eq 'pkg-a' -and $_.Status -eq 'warmed' }).Count | Should -Be 1
        @($deps | Where-Object { $_.Name -eq 'pkg-b' -and $_.Status -eq 'skipped-invalid-spec' }).Count | Should -Be 1
        @($deps | Where-Object { $_.Name -eq 'pkg-c' -and $_.Status -eq 'skipped-invalid-spec' }).Count | Should -Be 1

        # Only pkg-a was warmed; file: and npm: specs skipped.
        $installs = @(InModuleScope OfflineSync { @($script:LocalInstallCalls) })
        @($installs | Where-Object { $_.Spec -eq 'pkg-a@1.0.0' }).Count | Should -Be 1
        @($installs | Where-Object { $_.Spec -eq 'pkg-b@file:../local-x' }).Count | Should -Be 0
        @($installs | Where-Object { $_.Spec -eq 'pkg-c@npm:@scope/legacy' }).Count | Should -Be 0
    }

    It 'delivers local-packages.txt with both # local: and # deps: lines when published + deps coexist' {
        $root = Join-Path $script:neRoot 'deps-coexist'
        $selfDir = New-LocalPkgDir -Parent (Join-Path $root 'src') -Name 'my-local-pkg' -Version '1.0.0'
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg' -DepsJson '{"@opencode-ai/plugin":"1.18.21"}'
        $fx = New-LocalExportFixture -Name 'deps-coexist' -NpmLocalDirs @($selfDir, $depsDir) -NpmListContent 'is-odd@3.0.1'
        New-LocalStorageMarker -StagingDir $fx.StagingDir -Names @('my-local-pkg')

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $listPath = Join-Path $fx.StagingDir 'npm\local-packages.txt'
        (Test-Path -LiteralPath $listPath) | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($listPath)
        # Published line with # local: marker
        $text | Should -Match 'my-local-pkg@1\.0\.0\s+# local: '
        # Deps line with # deps: marker
        $text | Should -Match '@opencode-ai/plugin@1\.18\.21\s+# deps: '

        $report.local.published.Count | Should -Be 1
        $report.local.published[0].Name | Should -Be 'my-local-pkg'
        @($report.local.deps | Where-Object { $_.Status -eq 'warmed' }).Count | Should -Be 1
    }

    It 'delivers local-packages.txt with # deps: lines even when no packages are published' {
        $root = Join-Path $script:neRoot 'deps-only-file'
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg' -DepsJson '{"some-dep":"1.0.0"}'
        $fx = New-LocalExportFixture -Name 'deps-only-file' -NpmLocalDirs @($depsDir) -NpmListContent 'is-odd@3.0.1'

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $listPath = Join-Path $fx.StagingDir 'npm\local-packages.txt'
        (Test-Path -LiteralPath $listPath) | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($listPath)
        $text | Should -Match 'some-dep@1\.0\.0\s+# deps: '
        $text | Should -Not -Match '# local: '

        $report.local.published.Count | Should -Be 0
        $report.local.listPath | Should -Be $listPath
    }

    It 'does NOT deliver local-packages.txt when nothing is published and no deps were warmed' {
        $root = Join-Path $script:neRoot 'deps-no-file'
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg' -DepsJson '{"bad-spec":"file:../x"}'
        $fx = New-LocalExportFixture -Name 'deps-no-file' -NpmLocalDirs @($depsDir) -NpmListContent 'is-odd@3.0.1'

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $listPath = Join-Path $fx.StagingDir 'npm\local-packages.txt'
        (Test-Path -LiteralPath $listPath) | Should -BeFalse
        $report.local.listPath | Should -BeNullOrEmpty
        @($report.local.deps | Where-Object { $_.Status -eq 'warmed' }).Count | Should -Be 0
    }

    It 'reports deps warm failures and appends them to localFailed' {
        $root = Join-Path $script:neRoot 'deps-warm-fail'
        $depsDir = New-DepsManifestDir -Parent (Join-Path $root 'deps') -DirName 'cfg' -DepsJson '{"will-fail":"1.0.0","will-ok":"2.0.0"}'
        $fx = New-LocalExportFixture -Name 'deps-warm-fail' -NpmLocalDirs @($depsDir) -NpmListContent 'is-odd@3.0.1'
        InModuleScope OfflineSync { $script:LocalInstallFailSpecs = @('will-fail@1.0.0') }

        $report = Export-OSyncNpm -Config $fx.Config -StagingDir $fx.StagingDir

        $deps = @($report.local.deps)
        @($deps | Where-Object { $_.Status -eq 'warmed' }).Count | Should -Be 1  # will-ok
        @($deps | Where-Object { $_.Status -eq 'failed' }).Count | Should -Be 1   # will-fail
        @($deps | Where-Object { $_.Name -eq 'will-fail' -and $_.Status -eq 'failed' }).Count | Should -Be 1

        # Deps warm failures also go to localFailed.
        @($report.local.failed | Where-Object { $_.Name -eq 'will-fail' }).Count | Should -Be 1
        @($report.local.failed | Where-Object { $_.Name -eq 'will-fail' -and $_.Error -like '*deps warm failed*' }).Count | Should -Be 1
    }
}

