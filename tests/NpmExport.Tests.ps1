#Requires -Version 5.1
<#
  NpmExport.Tests.ps1 - Pester 5 tests for src\lib\NpmExport.ps1.

  Pure unit tests - none of them start a server and none of them touch the
  network: the verdaccio yml generators and the B-config leak assertion are
  exercised directly, and the npm-touching parts (PIN-ME resolution, engines
  cross-assertion, the pin-in-place write-back) run against a fake npm.cmd
  that is prepended to PATH for the duration of the suite. The real warm-up
  (real npm install through a real one-shot Verdaccio) is covered by the QA
  evidence log, not here.

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
    # absolute so Resolve-OPathForConfig uses them verbatim.
    function New-NeConfig {
        param(
            [string]$VerdaccioVersion,
            [string]$NpmListPath,
            [string]$RuntimeWhitelistPath,
            [string]$RepoRoot,
            [string]$StagingRoot
        )
        return [pscustomobject]@{
            schemaVersion  = 1
            role           = 'A'
            repoRoot       = $RepoRoot
            stagingRoot    = $StagingRoot
            verdaccioPort  = 4873
            npm            = [pscustomobject]@{ aVerdaccioPort = 4874 }
            paths          = [pscustomobject]@{
                npmList          = $NpmListPath
                runtimeWhitelist = $RuntimeWhitelistPath
            }
            pins           = [pscustomobject]@{
                npm = [pscustomobject]@{ verdaccioVersion = $VerdaccioVersion }
            }
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
