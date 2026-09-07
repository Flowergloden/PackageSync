#Requires -Version 5.1
<#
  Invoke-E2EFailureMatrix.ps1 - todo 23: failure matrix + full regression (ab-one-way-sync).
  Windows PowerShell 5.1 compatible: no PS7-only syntax. UTF-8 WITH BOM.

  Executes the SIX failure scenarios of plan todo 23 against SYNTHETIC fixture
  repositories built on TEMP DIR COPIES (never the real D:\OfflineRepo /
  C:\OfflineRepo / C:\ProgramData\PakageSync / C:\PakageSync landing):

    S1  transport corruption : flip ONE byte in a pip wheel in the LANDING repo
                               BEFORE any work-copy creation -> integrity marks
                               pip Incomplete (CorruptFiles), the apply round
                               skips pip (not-available) and logs it, while the
                               healthy winget category still applies + stamps.
    S2  partial sync         : DELETE one wheel from the pip category -> pip
                               Incomplete (MissingFiles) + skipped + logged, all
                               other healthy categories proceed normally.
    S3  stale index          : roll exportedAtUtc BACK below every seeded
                               lastApplied -> BOTH the packages round and the
                               dotfiles round skip ("nothing pending" /
                               "already at generation"), state byte-unchanged.
    S4  -WhatIf              : run the REAL entry with -WhatIf; the stateDir +
                               repoRoot file-tree snapshots (logs dir excluded,
                               an operational artifact - todo-12 learning) and
                               the state file bytes are identical before/after.
    S5  port occupation      : occupy 8788 -> winget apply fails EXPLICITLY with
                               the port in the error BEFORE any install (server
                               start precedes the install loop); occupy 4873 ->
                               npm apply fails EXPLICITLY at the port-hygiene
                               pre-check naming 4873 BEFORE any npmrc/env write.
    S6  state corruption     : write garbage into user-state.json -> the dotfiles
                               round survives: .bak quarantine + empty-state
                               rebuild + Warning + clean skip.

  SCENARIO DRIVING (documented design decision):
    - Rounds that BUILD a work-copy generation (S1/S2/S5) are driven through the
      LIB function Invoke-OSyncApply with -LandingRoot pointing at a NON-EXISTENT
      temp path, so the packages round's self-refresh (Momus r7-MAJOR-1) is
      skipped ("landing failed the owner/ACL re-verification") and the REAL
      C:\PakageSync tool landing is NEVER touched. The entry script hardcodes
      C:\PakageSync and would swap the real product tool copy with the fixture
      payload (dangerous; the QA seam exists exactly for this).
    - Rounds that produce NO generation (S3 stale-index, S4 -WhatIf, S6
      state-corruption) are driven through the REAL entry
      src\Invoke-OfflineApply.ps1 - the same binary the B-side tasks run.

  PORT OWNERSHIP: this E2E owns the DEFAULT ports 8788 (http) and 4873
  (verdaccio) - the parallel wave-5 workers (todos 20/21/22) use non-default
  ports. The fixture configs keep the defaults so the port-occupation errors
  carry exactly the plan-specified values.

  PORTS ARE PROBED FIRST: if 8788 or 4873 is already occupied before this run
  starts, the driver aborts with a clear message instead of producing a false
  scenario result.

  UNIFIED TEARDOWN (runs in finally, also on failure):
    1. unregister ALL temporary/QA scheduled tasks (never the production
       'PakageSync-Export' task - the A-side export task is left untouched and
       NEVER triggered),
    2. delete the temp dirs,
    3. restore A's built-in npmrc (<nodeInstallDir>\node_modules\npm\npmrc) and
       the machine-level NPM_CONFIG_REGISTRY env var to the pre-run baseline.

  FULL REGRESSION: `Invoke-Pester tests\ -PassThru` runs LAST in a child
  powershell.exe 5.1 (-ExecutionPolicy Bypass); the pass/fail markers are
  parsed and the full output is appended to the evidence file.

  Requires elevation. When launched without an admin token the script
  self-relaunches via Start-Process -Verb RunAs (this machine auto-elevates
  without a UAC prompt: ConsentPromptBehaviorAdmin=0).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\tests\e2e\Invoke-E2EFailureMatrix.ps1
        [-LandingRoot <dir>] [-EvidencePath <file>] [-DoneFile <file>]
        [-KeepArtifacts] [-SkipPester]
#>

[CmdletBinding()]
param(
    # Isolated test area (all scenario fixture repos + configs + state). Defaults
    # to $env:TEMP\osync-e2e-23-<UTC stamp>.
    [string]$LandingRoot,

    # Evidence log path. Defaults to <repo>\.omo\evidence\task-23-ab-one-way-sync.log.
    [string]$EvidencePath,

    # Completion marker written at the very end (polled by the parent).
    [string]$DoneFile,

    # Keep all temp artifacts (default: the landing dir is deleted at the end).
    [switch]$KeepArtifacts,

    # Dev aid: skip the final Invoke-Pester tests\ full regression.
    [switch]$SkipPester
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# shared script-scope state
# ---------------------------------------------------------------------------
$script:PassCount = 0
$script:FailCount = 0
$script:EvidencePath = ''
$script:EvidenceSeeded = $false
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:LandingRoot = ''
$script:VerdaccioQaTask = 'PakageSync-Verdaccio-QA23'
$script:ApplyLib = ''

# A-side env baseline recorded at start for the unified teardown restore.
$script:NpmrcPath = ''
$script:NpmrcBaselineBytes = $null
$script:EnvVarBaseline = $null

# ---------------------------------------------------------------------------
# evidence + assertion helpers
# ---------------------------------------------------------------------------
function Write-Evidence {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Msg
    )
    if (-not $script:EvidenceSeeded) {
        $dir = Split-Path -Parent $script:EvidencePath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Seed with BOM (PS 5.1 misreads BOM-less UTF-8 as ANSI).
        [System.IO.File]::WriteAllText($script:EvidencePath, '', $script:Utf8Bom)
        $script:EvidenceSeeded = $true
    }
    [System.IO.File]::AppendAllText($script:EvidencePath, $Msg + [Environment]::NewLine, $script:Utf8NoBom)
}

function Assert-E2E {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:PassCount++
        Write-Evidence ("PASS: {0} {1}" -f $Name, $Detail)
    }
    else {
        $script:FailCount++
        Write-Evidence ("FAIL: {0} {1}" -f $Name, $Detail)
    }
}

function Assert-E2EFatal {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Detail = ''
    )
    Assert-E2E -Condition $Condition -Name $Name -Detail $Detail
    if (-not $Condition) { throw "FATAL: $Name" }
}

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
function Set-E2EText {
    # Writes a text file UTF-8 WITHOUT BOM (payload content is ASCII).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
}

function Set-E2EBinary {
    # Writes a deterministic pseudo-random binary blob of the given size.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Size,
        [Parameter(Mandatory = $true)][int]$Seed
    )
    $rng = New-Object System.Random($Seed)
    $bytes = New-Object byte[] $Size
    $rng.NextBytes($bytes)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-IndexExportedAtUtc {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $idxPath = Join-Path $RepoRoot 'index.json'
    $idx = Get-Content -LiteralPath $idxPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return [string]$idx.exportedAtUtc
}

function Get-E2ETreeHash {
    # Recursive sha256 map of every file under <Root>, keyed by relative path,
    # serialised deterministically (sorted). Entries under the excluded relative
    # prefixes are skipped. Returns '' for a missing/nonexistent root.
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$ExcludeRel = @()
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { return '' }
    $map = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\')
        $skip = $false
        foreach ($ex in $ExcludeRel) {
            if ($rel.StartsWith($ex + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
        }
        if ($skip) { continue }
        $map[$rel] = (Get-OSyncFileSha256 -Path $f.FullName)
    }
    $parts = @()
    foreach ($k in ($map.Keys | Sort-Object)) {
        $parts += ("{0}={1}" -f $k, $map[$k])
    }
    return ($parts -join '|')
}

function Get-E2ELogText {
    # Concatenates all human-readable osync-*.log lines under <stateDir>\run\logs.
    param([Parameter(Mandatory = $true)][string]$StateDir)
    $logDir = Join-Path $StateDir 'run\logs'
    $lines = @()
    if (Test-Path -LiteralPath $logDir -PathType Container) {
        foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue)) {
            $lines += @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
        }
    }
    return ($lines -join "`n")
}

function Get-E2ELogTail {
    param([Parameter(Mandatory = $true)][string]$StateDir, [int]$Lines = 40)
    $all = @(Get-E2ELogText -StateDir $StateDir -ErrorAction SilentlyContinue)
    $split = @()
    foreach ($entry in $all) { $split += @($entry -split "`r?`n") }
    if ($split.Count -eq 0) { return @() }
    return @($split | Select-Object -Last $Lines)
}

function Format-Integrity {
    param($R)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("integrity.Overall: $($R.Overall)")
    foreach ($e in $R.Categories.GetEnumerator()) {
        $s = $e.Value
        $lines.Add(("  category {0}: {1}" -f $e.Key, $s.Status))
        if ($s.Reason) { $lines.Add(("    reason: {0}" -f $s.Reason)) }
        if ($s.MissingFiles.Count -gt 0) { $lines.Add(("    missing: {0}" -f ($s.MissingFiles -join ', '))) }
        if ($s.CorruptFiles.Count -gt 0) { $lines.Add(("    corrupt: {0}" -f ($s.CorruptFiles -join ', '))) }
    }
    return ($lines -join [Environment]::NewLine)
}

function Format-ApplyResult {
    param($R)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("outcome=$($R.outcome) mode=$($R.mode) whatIf=$($R.whatIf) bootstrapped=$($R.bootstrapped)")
    if ($R.skipReason) { $lines.Add("skipReason=$($R.skipReason)") }
    if ($R.error) { $lines.Add("error=$($R.error)") }
    $lines.Add("exportedAtUtc=$($R.exportedAtUtc) pending=$($R.pendingCategories -join ',')")
    if ($R.mode -eq 'packages') {
        $lines.Add("generation=$($R.generation) verified=$($R.verified) refreshed=$($R.refreshed)")
        if ($R.refreshSkippedReason) { $lines.Add("refreshSkippedReason=$($R.refreshSkippedReason)") }
    }
    foreach ($k in $R.categories.Keys) {
        $c = $R.categories[$k]
        $lines.Add(("  [{0}] {1}: {2}" -f $c.category, $c.status, $c.message))
    }
    return ($lines -join [Environment]::NewLine)
}

function New-E2EPortOccupier {
    # Holds a TCP port so the server-start / port-hygiene paths fail.
    param([Parameter(Mandatory = $true)][int]$Port)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $l.Start()
    return $l
}

function Stop-E2EPortOccupier {
    # Releases a TcpListener (Stop() is the only release API; the underlying
    # Server socket is closed by Stop). Idempotent + never throws.
    param($Handle)
    if ($null -eq $Handle) { return }
    try { $Handle.Stop() } catch { }
}

function Test-PortFree {
    param([Parameter(Mandatory = $true)][int]$Port)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try { $l.Start(); return $true }
    catch { return $false }
    finally { $l.Stop() }
}

# ---------------------------------------------------------------------------
# scenario scaffolding
# ---------------------------------------------------------------------------
function Initialize-E2EScenario {
    # Creates the per-scenario sub-tree and normalises to LONG path form
    # (todo-18 learning: $env:TEMP is 8.3 short form; Get-Item returns long form).
    param([Parameter(Mandatory = $true)][string]$Name)
    $scen = Join-Path $script:LandingRoot $Name
    New-Item -ItemType Directory -Path $scen -Force | Out-Null
    $scen = (Get-Item -LiteralPath $scen).FullName
    $repo = Join-Path $scen 'repo'
    $state = Join-Path $scen 'state'
    $landing = Join-Path $scen 'landing'
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    $repo = (Get-Item -LiteralPath $repo).FullName
    return [pscustomobject]@{ Root = $scen; Repo = $repo; State = $state; Landing = $landing }
}

function New-E2EFixtureRepo {
    # Builds a synthetic full repo (winget/pip/npm/dotfiles/runtime + files.json
    # + index.json) using the REAL RepoContract functions. Returns the index
    # exportedAtUtc. All content is synthetic - the apply never installs any of
    # it. -WingetPackages lets a scenario write a NON-EMPTY whitelist BEFORE the
    # files.json is generated (writing it after would corrupt the winget
    # category's integrity - the S5a gotcha).
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string]$WingetPackages = '# fixture: empty whitelist - winget apply is a no-op'
    )

    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'winget') -Force | Out-Null
    Set-E2EText -Path (Join-Path $RepoRoot 'winget\packages.txt') -Text $WingetPackages

    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'pip') -Force | Out-Null
    Set-E2EBinary -Path (Join-Path $RepoRoot 'pip\six-1.17.0-py2.py3-none-any.whl') -Size 2048 -Seed 1001
    Set-E2EBinary -Path (Join-Path $RepoRoot 'pip\isodate-0.7.2-py2.py3-none-any.whl') -Size 1024 -Seed 1002

    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'npm') -Force | Out-Null
    Set-E2EText -Path (Join-Path $RepoRoot 'npm\verdaccio-b.yml') -Text (New-OSyncVerdaccioBYaml -Port 4873)
    Set-E2EText -Path (Join-Path $RepoRoot 'npm\packages.txt') -Text 'fixture-pkg@1.0.0'

    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'dotfiles\source') -Force | Out-Null
    Set-E2EText -Path (Join-Path $RepoRoot 'dotfiles\chezmoi.toml') -Text "[data]`n  name = `"e2e-fixture`"`n"
    Set-E2EText -Path (Join-Path $RepoRoot 'dotfiles\source\.plain.txt') -Text 'e2e fixture dotfile'

    New-Item -ItemType Directory -Path (Join-Path $RepoRoot 'runtime') -Force | Out-Null
    Set-E2EText -Path (Join-Path $RepoRoot 'runtime\runtime-winget.txt') -Text '# fixture runtime - no entries'

    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
        New-OSyncFilesManifest -Dir (Join-Path $RepoRoot $cat) | Out-Null
    }
    Publish-OSyncIndex -StagingDir $RepoRoot | Out-Null
    return (Get-IndexExportedAtUtc -RepoRoot $RepoRoot)
}

function New-E2EConfig {
    # Clones config\packagesync.b.json (role B) and retargets repoRoot/stateDir/
    # stagingRoot/ports + category flags. Returns the validated config object.
    param(
        [Parameter(Mandatory = $true)]$Scenario,
        [Parameter(Mandatory = $false)][bool]$Winget = $true,
        [Parameter(Mandatory = $true)][bool]$Pip,
        [Parameter(Mandatory = $true)][bool]$Npm,
        [Parameter(Mandatory = $true)][bool]$Dotfiles,
        [Parameter(Mandatory = $false)][int]$HttpPort = 8788,
        [Parameter(Mandatory = $false)][int]$VerdaccioPort = 4873
    )
    $cfgDir = Join-Path $Scenario.Root 'config'
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $cfgPath = Join-Path $cfgDir 'packagesync.json'
    $src = Get-Content -LiteralPath (Join-Path $repo 'config\packagesync.b.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $src.repoRoot = $Scenario.Repo
    $src.stateDir = $Scenario.State
    $src.stagingRoot = Join-Path $Scenario.Root 'staging'
    $src.httpPort = $HttpPort
    $src.verdaccioPort = $VerdaccioPort
    $src.categories.winget = $Winget
    $src.categories.pip = $Pip
    $src.categories.npm = $Npm
    $src.categories.dotfiles = $Dotfiles
    [System.IO.File]::WriteAllText($cfgPath, ($src | ConvertTo-Json -Depth 10), $script:Utf8Bom)
    $cfg = Get-OSyncConfig -Path $cfgPath
    Assert-E2EFatal ($cfg.role -eq 'B') 'cloned config role is B'
    Assert-E2EFatal (-not ($cfg.repoRoot -eq 'D:\OfflineRepo' -or $cfg.repoRoot -eq 'C:\OfflineRepo')) 'fixture repoRoot never points at a real landing dir' "($($cfg.repoRoot))"
    return $cfg
}

function Set-E2ESeededState {
    # Seeds a "bootstrapped, no drift" system state so the packages round skips
    # the bootstrap self-heal path (hashes match the freshly built fixture).
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    $st = Get-OSyncState -Category 'winget' -Config $Config
    $st.bootstrapped = $true
    $st.runtimeWingetHash = Get-OSyncFileSha256 -Path (Join-Path $RepoRoot 'runtime\runtime-winget.txt')
    $st.runtimeFilesHash = Get-OSyncFileSha256 -Path (Join-Path $RepoRoot 'runtime\files.json')
    Save-OSyncState -Category 'winget' -State $st -Config $Config | Out-Null
}

function Invoke-E2EModuleRound {
    # Drives ONE apply round through the LIB (Invoke-OSyncApply) with a
    # NON-EXISTENT temp -LandingRoot so the packages round's self-refresh of the
    # real C:\PakageSync is skipped (the QA seam, ApplyOrchestrator header).
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $false)][string[]]$Category = @(),
        [Parameter(Mandatory = $false)][string]$LandingRoot,
        [Parameter(Mandatory = $false)][string]$VerdaccioTaskName
    )
    return (Invoke-OSyncApply -Config $Config -Category $Category `
        -VerdaccioTaskName $VerdaccioTaskName -LandingRoot $LandingRoot)
}

function Invoke-E2EEntryRound {
    # Drives the REAL src\Invoke-OfflineApply.ps1 entry in a child powershell.exe
    # 5.1. Returns { ExitCode, OutText, ErrText }.
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $false)][string]$Category,
        [Parameter(Mandatory = $false)][switch]$WhatIf,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $out = Join-Path $env:TEMP ("osync-e2e23-{0}-{1}.out.log" -f $Name, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $err = Join-Path $env:TEMP ("osync-e2e23-{0}-{1}.err.log" -f $Name, ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $args = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f (Join-Path $repo 'src\Invoke-OfflineApply.ps1')),
        '-ConfigPath', ('"{0}"' -f $ConfigPath)
    )
    if (-not [string]::IsNullOrWhiteSpace($Category)) {
        $args += '-Category'; $args += ('"{0}"' -f $Category)
    }
    if ($WhatIf) { $args += '-WhatIf' }
    Write-Evidence "  entry command: powershell.exe $($args -join ' ')"
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList $args -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $outText = if (Test-Path -LiteralPath $out -PathType Leaf) { Get-Content -LiteralPath $out -Raw -Encoding UTF8 } else { '' }
    $errText = if (Test-Path -LiteralPath $err -PathType Leaf) { Get-Content -LiteralPath $err -Raw -Encoding UTF8 } else { '' }
    Write-Evidence "  entry exit code: $($p.ExitCode)"
    if (-not [string]::IsNullOrWhiteSpace($outText)) { Write-Evidence "  entry stdout:"; foreach ($l in @($outText -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($l)) { Write-Evidence "    $l" } } }
    if (-not [string]::IsNullOrWhiteSpace($errText)) { Write-Evidence "  entry stderr:"; foreach ($l in @($errText -split "`r?`n")) { if (-not [string]::IsNullOrWhiteSpace($l)) { Write-Evidence "    $l" } } }
    Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ ExitCode = $p.ExitCode; OutText = $outText; ErrText = $errText }
}

# ---------------------------------------------------------------------------
# unified teardown (runs in finally, also on failure)
# ---------------------------------------------------------------------------
function Invoke-E2ETeardown {
    Write-Evidence ""
    Write-Evidence "===== UNIFIED TEARDOWN ====="

    # 1. unregister ALL temporary/QA scheduled tasks (never the production
    #    'PakageSync-Export' or the B-role task names - only QA-marked ones).
    $qaPattern = '^PakageSync-.*(?i:qa)'
    $candidates = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
            $_.TaskName -match $qaPattern -and $_.TaskName -ne 'PakageSync-Export' })
    foreach ($t in $candidates) {
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -Confirm:$false -ErrorAction Stop
            Write-Evidence "unregistered QA scheduled task: $($t.TaskName)"
        }
        catch {
            Write-Evidence "WARN: could not unregister $($t.TaskName): $($_.Exception.Message)"
        }
    }
    if ($candidates.Count -eq 0) { Write-Evidence "no QA/temporary scheduled tasks to unregister" }

    # 2. restore A's built-in npmrc + machine-level NPM_CONFIG_REGISTRY to the
    #    pre-run baseline (the apply failure paths never reached the write, but
    #    a defensive restore is mandated by the plan's unified teardown).
    if (-not [string]::IsNullOrWhiteSpace($script:NpmrcPath) -and (Test-Path -LiteralPath $script:NpmrcPath -PathType Leaf)) {
        $currentBytes = [System.IO.File]::ReadAllBytes($script:NpmrcPath)
        if ($null -eq $script:NpmrcBaselineBytes -or -not ([System.Linq.Enumerable]::SequenceEqual($currentBytes, $script:NpmrcBaselineBytes))) {
            try {
                [System.IO.File]::WriteAllBytes($script:NpmrcPath, $script:NpmrcBaselineBytes)
                Write-Evidence "restored built-in npmrc to the pre-run baseline: $script:NpmrcPath"
            }
            catch {
                Write-Evidence "WARN: npmrc restore failed: $($_.Exception.Message)"
            }
        }
        else {
            Write-Evidence "built-in npmrc unchanged from the pre-run baseline (no restore needed)"
        }
        $bak = $script:NpmrcPath + '.osyncbak'
        if (Test-Path -LiteralPath $bak -PathType Leaf) {
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue
            Write-Evidence "removed npmrc .osyncbak backup"
        }
    }
    $currentEnv = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')
    if ($currentEnv -ne $script:EnvVarBaseline) {
        try {
            [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', $script:EnvVarBaseline, 'Machine')
            Write-Evidence "restored machine NPM_CONFIG_REGISTRY to [$($script:EnvVarBaseline)]"
        }
        catch {
            Write-Evidence "WARN: machine env restore failed: $($_.Exception.Message)"
        }
    }
    else {
        Write-Evidence "machine NPM_CONFIG_REGISTRY unchanged from the pre-run baseline ([$currentEnv])"
    }

    # 3. delete the temp dirs.
    if (-not $KeepArtifacts) {
        Write-Evidence "self-cleanup: removing landing dir $script:LandingRoot"
        Remove-Item -LiteralPath $script:LandingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Evidence "KeepArtifacts set - landing dir retained: $script:LandingRoot"
    }
}

# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------
function Test-E2EScenario1 {
    # S1 transport corruption: flip ONE byte in a pip wheel in the LANDING repo
    # BEFORE any work-copy creation -> pip Incomplete (CorruptFiles), the round
    # skips pip (not-available) + logs it, healthy winget still applies + stamps.
    Write-Evidence ""
    Write-Evidence "===== S1: transport corruption (flip one byte in a pip wheel) ====="
    $s = Initialize-E2EScenario 's1-transport-corruption'
    $ts = New-E2EFixtureRepo -RepoRoot $s.Repo

    # flip one byte BEFORE any work-copy creation (bit-flip, same length)
    $whl = Join-Path $s.Repo 'pip\six-1.17.0-py2.py3-none-any.whl'
    $bytes = [System.IO.File]::ReadAllBytes($whl)
    $bytes[0] = $bytes[0] -bxor 0xFF
    [System.IO.File]::WriteAllBytes($whl, $bytes)
    Write-Evidence "flipped one byte in '$whl' (landing repo, pre-work-copy)."

    $cfg = New-E2EConfig -Scenario $s -Pip $true -Npm $false -Dotfiles $true
    $cfgPath = Join-Path $s.Root 'config\packagesync.json'
    Set-E2ESeededState -Config $cfg -RepoRoot $s.Repo

    $integrity = Test-OSyncRepoIntegrity -RepoRoot $s.Repo
    Write-Evidence "--- S1 integrity (corrupted landing) ---"
    Write-Evidence (Format-Integrity -R $integrity)
    Assert-E2EFatal ($integrity.Overall -eq 'Incomplete') 'S1 integrity Overall = Incomplete' "(got '$($integrity.Overall)')"
    Assert-E2E ($integrity.Categories['pip'].Status -eq 'Incomplete') 'S1 pip category = Incomplete' "(got '$($integrity.Categories['pip'].Status)')"
    Assert-E2E ($integrity.Categories['pip'].CorruptFiles -contains 'six-1.17.0-py2.py3-none-any.whl') 'S1 corrupt file named' ("$($integrity.Categories['pip'].CorruptFiles -join ',')")

    $result = Invoke-E2EModuleRound -Config $cfg -Category @('winget', 'pip') -LandingRoot $s.Landing -VerdaccioTaskName $script:VerdaccioQaTask
    Write-Evidence "--- S1 apply round result ---"
    Write-Evidence (Format-ApplyResult -R $result)

    Assert-E2EFatal ($result.outcome -eq 'ok') 'S1 round outcome = ok' "(got '$($result.outcome)')"
    Assert-E2E ($result.categories['winget'].status -eq 'ok') 'S1 winget applied (healthy category proceeds)' "(got '$($result.categories['winget'].status)')"
    Assert-E2E ($result.categories['pip'].status -eq 'not-available') 'S1 pip skipped (not-available)' "(got '$($result.categories['pip'].status)')"
    Assert-E2E ($result.categories['pip'].message -match 'Incomplete') 'S1 pip skip message names Incomplete' "($($result.categories['pip'].message))"
    Assert-E2E ($result.categories['dotfiles'].status -eq 'not-requested') 'S1 dotfiles not requested (packages round)'

    $st = Get-OSyncState -Category 'winget' -Config $cfg
    Assert-E2E ($st.lastApplied.winget -eq $ts) 'S1 lastApplied.winget stamped' "(got '$($st.lastApplied.winget)', want '$ts')"
    Assert-E2E ($null -eq $st.lastApplied.pip) 'S1 lastApplied.pip untouched (retry next round)'

    $gen = $result.generation
    Assert-E2EFatal (-not [string]::IsNullOrWhiteSpace($gen)) 'S1 a work-copy generation was created'
    Assert-E2E (Test-Path -LiteralPath (Join-Path $gen '.verified') -PathType Leaf) 'S1 generation carries the .verified marker'
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $gen 'pip') -PathType Container)) 'S1 corrupted pip category NOT copied into the work copy'

    $log = Get-E2ELogText -StateDir $s.State
    Assert-E2E ($log -match 'pip') 'S1 apply log mentions pip'
    Assert-E2E ($log -match 'skipped \(integrity not OK\)') 'S1 apply log records the skip warning' "($(($log -split "`n") | Where-Object { $_ -match 'pip' } | Select-Object -Last 3))"
    Write-Evidence "--- S1 apply log (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

function Test-E2EScenario2 {
    # S2 partial sync: DELETE one wheel -> pip Incomplete (MissingFiles) +
    # skipped + logged; the other healthy categories proceed normally.
    Write-Evidence ""
    Write-Evidence "===== S2: partial sync (delete one wheel) ====="
    $s = Initialize-E2EScenario 's2-partial-sync'
    $ts = New-E2EFixtureRepo -RepoRoot $s.Repo

    $whl = Join-Path $s.Repo 'pip\isodate-0.7.2-py2.py3-none-any.whl'
    Remove-Item -LiteralPath $whl -Force
    Write-Evidence "deleted '$whl' from the landing repo (partial sync)."

    $cfg = New-E2EConfig -Scenario $s -Pip $true -Npm $false -Dotfiles $true
    Set-E2ESeededState -Config $cfg -RepoRoot $s.Repo

    $integrity = Test-OSyncRepoIntegrity -RepoRoot $s.Repo
    Write-Evidence "--- S2 integrity (partial landing) ---"
    Write-Evidence (Format-Integrity -R $integrity)
    Assert-E2EFatal ($integrity.Overall -eq 'Incomplete') 'S2 integrity Overall = Incomplete' "(got '$($integrity.Overall)')"
    Assert-E2E ($integrity.Categories['pip'].Status -eq 'Incomplete') 'S2 pip category = Incomplete' "(got '$($integrity.Categories['pip'].Status)')"
    Assert-E2E ($integrity.Categories['pip'].MissingFiles -contains 'isodate-0.7.2-py2.py3-none-any.whl') 'S2 deleted wheel named as missing' ("$($integrity.Categories['pip'].MissingFiles -join ',')")

    $result = Invoke-E2EModuleRound -Config $cfg -Category @('winget', 'pip') -LandingRoot $s.Landing -VerdaccioTaskName $script:VerdaccioQaTask
    Write-Evidence "--- S2 apply round result ---"
    Write-Evidence (Format-ApplyResult -R $result)

    Assert-E2EFatal ($result.outcome -eq 'ok') 'S2 round outcome = ok' "(got '$($result.outcome)')"
    Assert-E2E ($result.categories['winget'].status -eq 'ok') 'S2 winget applied (other category proceeds)' "(got '$($result.categories['winget'].status)')"
    Assert-E2E ($result.categories['pip'].status -eq 'not-available') 'S2 pip skipped (not-available)' "(got '$($result.categories['pip'].status)')"
    Assert-E2E ($result.categories['dotfiles'].status -eq 'not-requested') 'S2 dotfiles not requested (packages round)'

    $st = Get-OSyncState -Category 'winget' -Config $cfg
    Assert-E2E ($st.lastApplied.winget -eq $ts) 'S2 lastApplied.winget stamped' "(got '$($st.lastApplied.winget)', want '$ts')"
    Assert-E2E ($null -eq $st.lastApplied.pip) 'S2 lastApplied.pip untouched'

    $gen = $result.generation
    Assert-E2EFatal (-not [string]::IsNullOrWhiteSpace($gen)) 'S2 a work-copy generation was created'
    Assert-E2E (Test-Path -LiteralPath (Join-Path $gen '.verified') -PathType Leaf) 'S2 generation carries the .verified marker'
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $gen 'pip') -PathType Container)) 'S2 incomplete pip category NOT copied into the work copy'

    $log = Get-E2ELogText -StateDir $s.State
    Assert-E2E ($log -match 'pip') 'S2 apply log mentions pip'
    Assert-E2E ($log -match 'skipped \(integrity not OK\)') 'S2 apply log records the skip warning'
    Write-Evidence "--- S2 apply log (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

function Test-E2EScenario3 {
    # S3 stale index: roll exportedAtUtc BACK below every seeded lastApplied ->
    # ALL categories skipped (packages round: nothing pending; dotfiles round:
    # already at generation), state byte-unchanged.
    Write-Evidence ""
    Write-Evidence "===== S3: stale index (roll back exportedAtUtc -> all skipped) ====="
    $s = Initialize-E2EScenario 's3-stale-index'
    $ts = New-E2EFixtureRepo -RepoRoot $s.Repo
    $cfg = New-E2EConfig -Scenario $s -Pip $true -Npm $true -Dotfiles $true
    $cfgPath = Join-Path $s.Root 'config\packagesync.json'
    Set-E2ESeededState -Config $cfg -RepoRoot $s.Repo

    # stamp every category at the CURRENT index ts
    foreach ($c in @('winget', 'pip', 'npm', 'dotfiles')) {
        Set-OSyncLastApplied -Category $c -ExportedAtUtc $ts -Config $cfg | Out-Null
    }
    Write-Evidence "seeded lastApplied.{winget,pip,npm,dotfiles} = $ts"

    # roll the index BACK (a stale sync delivered an older index over a newer one)
    $idxPath = Join-Path $s.Repo 'index.json'
    $idx = Get-Content -LiteralPath $idxPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $idx.exportedAtUtc = '20200101T000000Z'
    [System.IO.File]::WriteAllText($idxPath, ($idx | ConvertTo-Json -Depth 10), $script:Utf8Bom)
    Write-Evidence "rolled index exportedAtUtc back: $ts -> 20200101T000000Z"

    $sysPath = Join-Path $s.State 'state\system-state.json'
    $usrPath = Join-Path $s.State 'run\user-state.json'
    $sysBefore = Get-OSyncFileSha256 -Path $sysPath
    $usrBefore = Get-OSyncFileSha256 -Path $usrPath

    # packages round (real entry): nothing pending -> skip
    $r1 = Invoke-E2EEntryRound -ConfigPath $cfgPath -Category 'winget,pip,npm' -Name 's3pkg'
    Assert-E2EFatal ($r1.ExitCode -eq 0) 'S3 packages round exits 0' "(got $($r1.ExitCode))"
    Assert-E2E ($r1.OutText -match 'outcome=skipped') 'S3 packages round outcome = skipped' "($($r1.OutText))"
    Assert-E2E ($r1.OutText -match 'nothing pending') 'S3 packages round skip reason = nothing pending'

    # dotfiles round (real entry): not newer -> skip
    $r2 = Invoke-E2EEntryRound -ConfigPath $cfgPath -Category 'dotfiles' -Name 's3dot'
    Assert-E2EFatal ($r2.ExitCode -eq 0) 'S3 dotfiles round exits 0' "(got $($r2.ExitCode))"
    Assert-E2E ($r2.OutText -match 'outcome=skipped') 'S3 dotfiles round outcome = skipped' "($($r2.OutText))"
    Assert-E2E ($r2.OutText -match 'already at generation') 'S3 dotfiles round skip reason = already at generation'

    # state byte-unchanged (no stamp, no rebuild)
    $sysAfter = Get-OSyncFileSha256 -Path $sysPath
    $usrAfter = Get-OSyncFileSha256 -Path $usrPath
    Assert-E2E ($sysAfter -eq $sysBefore) 'S3 system-state.json bytes unchanged' "($sysBefore / $sysAfter)"
    Assert-E2E ($usrAfter -eq $usrBefore) 'S3 user-state.json bytes unchanged' "($usrBefore / $usrAfter)"
    $st = Get-OSyncState -Category 'winget' -Config $cfg
    Assert-E2E ($st.lastApplied.winget -eq $ts) 'S3 lastApplied.winget preserved' "(got '$($st.lastApplied.winget)')"
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $s.State 'work') -PathType Container)) 'S3 no work-copy generation created'
    Write-Evidence "--- S3 logs (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

function Test-E2EScenario4 {
    # S4 -WhatIf: state.json bytes + filesystem tree snapshots identical
    # before/after, zero changes. The real entry runs with -WhatIf.
    # NOTE: the run\logs directory is an OPERATIONAL artifact of Write-OSyncLog
    # (todo-12 learning) and is excluded from the snapshot.
    Write-Evidence ""
    Write-Evidence "===== S4: -WhatIf (zero changes) ====="
    $s = Initialize-E2EScenario 's4-whatif'
    $ts = New-E2EFixtureRepo -RepoRoot $s.Repo
    $cfg = New-E2EConfig -Scenario $s -Pip $true -Npm $true -Dotfiles $true
    $cfgPath = Join-Path $s.Root 'config\packagesync.json'
    # fresh (unseeded) state - the WhatIf round reads, never writes

    $stateBefore = Get-E2ETreeHash -Root $s.State -ExcludeRel @('run\logs')
    $repoBefore = Get-E2ETreeHash -Root $s.Repo
    Write-Evidence "pre-WhatIf stateDir tree hash (logs excluded): $stateBefore"
    Write-Evidence "pre-WhatIf repoRoot tree hash: $repoBefore"

    $r = Invoke-E2EEntryRound -ConfigPath $cfgPath -WhatIf -Name 's4'
    Assert-E2EFatal ($r.ExitCode -eq 0) 'S4 WhatIf round exits 0' "(got $($r.ExitCode))"
    Assert-E2E ($r.OutText -match 'outcome=ok') 'S4 WhatIf round outcome = ok' "($($r.OutText))"
    Assert-E2E ($r.OutText -match 'WhatIf') 'S4 WhatIf mode reported'

    $stateAfter = Get-E2ETreeHash -Root $s.State -ExcludeRel @('run\logs')
    $repoAfter = Get-E2ETreeHash -Root $s.Repo
    Assert-E2E ($stateAfter -eq $stateBefore) 'S4 stateDir tree identical (logs excluded)'
    Assert-E2E ($repoAfter -eq $repoBefore) 'S4 repoRoot tree identical'
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $s.State 'state\system-state.json') -PathType Leaf)) 'S4 no system-state.json written'
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $s.State 'run\user-state.json') -PathType Leaf)) 'S4 no user-state.json written'
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $s.State 'work') -PathType Container)) 'S4 no work-copy generation created'
    Write-Evidence "--- S4 WhatIf logs (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

function Test-E2EScenario5 {
    # S5 port occupation. We OWN the default ports 8788/4873.
    #   5a: occupy 8788 -> winget apply fails EXPLICITLY (server start precedes
    #       the install loop -> zero installs attempted) with the port in the error.
    #   5b: occupy 4873 -> npm apply fails EXPLICITLY at the port-hygiene
    #       pre-check naming 4873 BEFORE any npmrc/env write (the local copy
    #       /MIR refresh already ran - strict order stop->copy->start).
    Write-Evidence ""
    Write-Evidence "===== S5a: port occupation 8788 -> winget apply errors explicitly ====="
    $s = Initialize-E2EScenario 's5-port-occupation'
    # a NON-EMPTY whitelist forces the apply down the server-start path; it is
    # written BEFORE the files.json generation so the winget category stays OK
    $ts = New-E2EFixtureRepo -RepoRoot $s.Repo -WingetPackages 'Fixture.Noop'
    $cfg = New-E2EConfig -Scenario $s -Pip $false -Npm $false -Dotfiles $true
    Set-E2ESeededState -Config $cfg -RepoRoot $s.Repo

    $occ = New-E2EPortOccupier -Port 8788
    Write-Evidence "occupied port 8788 with a TcpListener."
    try {
        $result = Invoke-E2EModuleRound -Config $cfg -Category @('winget') -LandingRoot $s.Landing -VerdaccioTaskName $script:VerdaccioQaTask
    }
    finally {
        Stop-E2EPortOccupier -Handle $occ
        Write-Evidence "released port 8788."
    }
    Write-Evidence "--- S5a apply round result ---"
    Write-Evidence (Format-ApplyResult -R $result)

    Assert-E2EFatal ($result.outcome -eq 'ok') 'S5a round outcome = ok (category-level failure)' "(got '$($result.outcome)')"
    Assert-E2E ($result.categories['winget'].status -eq 'failed') 'S5a winget apply FAILED' "(got '$($result.categories['winget'].status)')"
    Assert-E2E ($result.categories['winget'].message -match '8788') 'S5a error message names port 8788' "($($result.categories['winget'].message))"
    $st = Get-OSyncState -Category 'winget' -Config $cfg
    Assert-E2E ($null -eq $st.lastApplied.winget) 'S5a lastApplied.winget untouched (no install happened)'
    $log = Get-E2ELogText -StateDir $s.State
    Assert-E2E ($log -match 'FAILED') 'S5a log records the winget failure'
    Assert-E2E ($log -match '8788') 'S5a log carries the port number'
    Write-Evidence "--- S5a apply log (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }

    # ------------------------------------------------------------------
    Write-Evidence ""
    Write-Evidence "===== S5b: port occupation 4873 -> npm apply errors explicitly ====="
    $s2 = Initialize-E2EScenario 's5b-npm-port'
    $ts2 = New-E2EFixtureRepo -RepoRoot $s2.Repo
    $cfg2 = New-E2EConfig -Scenario $s2 -Pip $false -Npm $true -Dotfiles $true
    Set-E2ESeededState -Config $cfg2 -RepoRoot $s2.Repo

    # register the temp Verdaccio task the npm apply queries (harmless action;
    # the apply fails at the port pre-check BEFORE it would ever /Run it).
    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/d /c exit 0'
    $trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date '2035-01-01T02:00:00')
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $script:VerdaccioQaTask -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Write-Evidence "registered temp scheduled task '$script:VerdaccioQaTask' (harmless action)."

    # snapshot the A-side registry wiring BEFORE the apply
    $npmrcBytesBefore = [System.IO.File]::ReadAllBytes($script:NpmrcPath)
    $envBefore = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')

    $occ2 = New-E2EPortOccupier -Port 4873
    Write-Evidence "occupied port 4873 with a TcpListener."
    try {
        $result2 = Invoke-E2EModuleRound -Config $cfg2 -Category @('winget', 'npm') -LandingRoot $s2.Landing -VerdaccioTaskName $script:VerdaccioQaTask
    }
    finally {
        Stop-E2EPortOccupier -Handle $occ2
        Write-Evidence "released port 4873."
    }
    Write-Evidence "--- S5b apply round result ---"
    Write-Evidence (Format-ApplyResult -R $result2)

    Assert-E2EFatal ($result2.outcome -eq 'ok') 'S5b round outcome = ok (category-level failure)' "(got '$($result2.outcome)')"
    Assert-E2E ($result2.categories['winget'].status -eq 'ok') 'S5b winget still proceeds (empty list no-op)' "(got '$($result2.categories['winget'].status)')"
    Assert-E2E ($result2.categories['npm'].status -eq 'failed') 'S5b npm apply FAILED' "(got '$($result2.categories['npm'].status)')"
    Assert-E2E ($result2.categories['npm'].message -match '4873') 'S5b error message names port 4873' "($($result2.categories['npm'].message))"

    # strict order evidence: the /MIR refresh already ran BEFORE the pre-check
    Assert-E2E (Test-Path -LiteralPath (Join-Path $s2.State 'verdaccio\verdaccio-b.yml') -PathType Leaf) 'S5b local copy refreshed before the port pre-check (strict order stop->copy->start)'

    # registry wiring UNTOUCHED (failure happened before step 3)
    $npmrcBytesAfter = [System.IO.File]::ReadAllBytes($script:NpmrcPath)
    $envAfter = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')
    Assert-E2E ([System.Linq.Enumerable]::SequenceEqual($npmrcBytesAfter, $npmrcBytesBefore)) 'S5b built-in npmrc bytes unchanged (no registry write)'
    Assert-E2E ($envAfter -eq $envBefore) 'S5b machine NPM_CONFIG_REGISTRY unchanged' "([$envBefore] -> [$envAfter])"
    $st2 = Get-OSyncState -Category 'npm' -Config $cfg2
    Assert-E2E ($null -eq $st2.lastApplied.npm) 'S5b lastApplied.npm untouched'
    $log2 = Get-E2ELogText -StateDir $s2.State
    Assert-E2E ($log2 -match '4873') 'S5b log carries the port number'
    Write-Evidence "--- S5b apply log (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s2.State)) { Write-Evidence "  $l" }

    # teardown the temp task now (also covered by the unified teardown)
    if (Get-ScheduledTask -TaskName $script:VerdaccioQaTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:VerdaccioQaTask -Confirm:$false
        Write-Evidence "unregistered '$script:VerdaccioQaTask'."
    }
}

function Test-E2EScenario6 {
    # S6 state corruption: write garbage into user-state.json -> the dotfiles
    # round survives: .bak quarantine + empty-state rebuild + Warning + clean skip.
    Write-Evidence ""
    Write-Evidence "===== S6: state corruption (garbage user-state.json) ====="
    $s = Initialize-E2EScenario 's6-state-corruption'
    $ts = New-E2EFixtureRepo -RepoRoot $s.Repo
    $cfg = New-E2EConfig -Scenario $s -Pip $true -Npm $true -Dotfiles $true
    $cfgPath = Join-Path $s.Root 'config\packagesync.json'
    Set-E2ESeededState -Config $cfg -RepoRoot $s.Repo

    $usr = Join-Path $s.State 'run\user-state.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $usr) -Force | Out-Null
    [System.IO.File]::WriteAllText($usr, 'this is not json {{{', $script:Utf8NoBom)
    Write-Evidence "wrote garbage into '$usr'."

    # dotfiles round via the REAL entry - the corruption is recovered inside the
    # apply process (Read-OStateFile quarantine -> .bak + empty rebuild + Warning).
    $r = Invoke-E2EEntryRound -ConfigPath $cfgPath -Category 'dotfiles' -Name 's6'
    Assert-E2EFatal ($r.ExitCode -eq 0) 'S6 dotfiles round survives the corruption (exit 0)' "(got $($r.ExitCode))"
    Assert-E2E ($r.OutText -match 'outcome=skipped') 'S6 dotfiles round outcome = skipped' "($($r.OutText))"
    Assert-E2E (Test-Path -LiteralPath ($usr + '.bak') -PathType Leaf) 'S6 corrupted user-state quarantined to .bak'
    Assert-E2E (($r.ErrText + ' ' + $r.OutText) -match 'renamed') 'S6 Warning surfaced (renamed to .bak)' "($(($r.ErrText + ' ' + $r.OutText)))"
    # after the round the store is either absent (in-memory rebuild not yet
    # persisted) or a valid empty schema - NEVER the garbage
    if (Test-Path -LiteralPath $usr -PathType Leaf) {
        $rebuilt = Get-Content -LiteralPath $usr -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-E2E ($rebuilt.schemaVersion -eq 1) 'S6 rebuilt user-state has schemaVersion 1'
        Assert-E2E ($null -eq $rebuilt.lastApplied.dotfiles) 'S6 rebuilt user-state lastApplied.dotfiles = null'
    }
    else {
        Assert-E2E $true 'S6 user-state file absent after quarantine (in-memory rebuild not yet persisted)'
    }

    # lib-level probe on a SECOND store proves the exact rebuild contract
    # (.bak + empty-state rebuild + Warning) with the tree shape asserted.
    $p = Initialize-E2EScenario 's6-probe'
    New-Item -ItemType Directory -Path (Join-Path $p.Root 'config') -Force | Out-Null
    $probeCfg = New-E2EConfig -Scenario $p -Pip $false -Npm $false -Dotfiles $true
    $pUsr = Join-Path $p.State 'run\user-state.json'
    New-Item -ItemType Directory -Path (Split-Path -Parent $pUsr) -Force | Out-Null
    [System.IO.File]::WriteAllText($pUsr, 'garbage {{{', $script:Utf8NoBom)
    $w = $null
    $probeState = Get-OSyncState -Category 'dotfiles' -Config $probeCfg -WarningVariable w
    Assert-E2E (($w -join ' ') -match 'renamed') 'S6 lib probe Warning names the .bak rename' "($($w -join ' '))"
    Assert-E2E (Test-Path -LiteralPath ($pUsr + '.bak') -PathType Leaf) 'S6 lib probe quarantined to .bak'
    Assert-E2E ($probeState.schemaVersion -eq 1) 'S6 lib probe rebuilt empty state schemaVersion 1'
    Assert-E2E ($null -eq $probeState.lastApplied.dotfiles) 'S6 lib probe rebuilt empty state lastApplied.dotfiles = null'
    Write-Evidence "--- S6 logs (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

# ---------------------------------------------------------------------------
# full regression
# ---------------------------------------------------------------------------
function Invoke-E2EPesterRegression {
    Write-Evidence ""
    Write-Evidence "===== FULL REGRESSION: Invoke-Pester tests\ -PassThru (powershell.exe 5.1) ====="
    $runner = Join-Path $script:LandingRoot 'pester-run.ps1'
    $runnerBody = @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$r = Invoke-Pester -Path '$repo\tests' -PassThru -Output Normal
Write-Output ''
Write-Output ("PESTER_PASSED=`$(`$r.PassedCount)")
Write-Output ("PESTER_FAILED=`$(`$r.FailedCount)")
Write-Output ("PESTER_SKIPPED=`$(`$r.SkippedCount)")
Write-Output ("PESTER_TOTAL=`$(`$r.TotalCount)")
if (`$r.FailedCount -gt 0) { exit 1 } else { exit 0 }
"@
    [System.IO.File]::WriteAllText($runner, $runnerBody, $script:Utf8Bom)
    $out = Join-Path $env:TEMP 'osync-e2e23-pester.out.log'
    $err = Join-Path $env:TEMP 'osync-e2e23-pester.err.log'
    $t0 = Get-Date
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runner)) `
        -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $el = (Get-Date) - $t0
    Write-Evidence "Pester child exit code: $($p.ExitCode) (elapsed $([int]$el.TotalMinutes) min $($el.Seconds) s)"
    if (Test-Path -LiteralPath $out -PathType Leaf) {
        Write-Evidence "--- Pester full output ---"
        foreach ($l in @(Get-Content -LiteralPath $out -Encoding UTF8)) { Write-Evidence "  $l" }
    }
    if (Test-Path -LiteralPath $err -PathType Leaf) {
        $errText = Get-Content -LiteralPath $err -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($errText)) {
            Write-Evidence "--- Pester stderr ---"
            foreach ($l in @($errText -split "`r?`n")) { Write-Evidence "  $l" }
        }
    }
    $outText = if (Test-Path -LiteralPath $out -PathType Leaf) { Get-Content -LiteralPath $out -Raw -Encoding UTF8 } else { '' }
    $passed = 0; $failed = -1; $total = 0
    if ($outText -match 'PESTER_PASSED=(\d+)') { $passed = [int]$Matches[1] }
    if ($outText -match 'PESTER_FAILED=(\d+)') { $failed = [int]$Matches[1] }
    if ($outText -match 'PESTER_TOTAL=(\d+)') { $total = [int]$Matches[1] }
    Assert-E2E ($failed -eq 0) 'Pester regression: 0 failed' "(passed=$passed failed=$failed total=$total)"
    Assert-E2E ($total -gt 0) 'Pester regression: suite actually ran' "(total=$total)"
    Assert-E2E ($p.ExitCode -eq 0) 'Pester regression: child exit 0' "(got $($p.ExitCode))"
    Remove-Item -LiteralPath $out, $err, $runner -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# main flow
# ---------------------------------------------------------------------------

# --- detect repo root: <repo>\tests\e2e\<this> -> <repo> ---
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- self-elevation ---
$isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argStr = ''
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v) { $argStr += " -$k" } }
        else { $argStr += " -$k `"$($v -replace '"', '\"')`"" }
    }
    $relaunch = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $MyInvocation.MyCommand.Path, $argStr) `
        -Verb RunAs -Wait -PassThru
    exit [int]$relaunch.ExitCode
}

# --- defaults ---
if ([string]::IsNullOrWhiteSpace($LandingRoot)) {
    $LandingRoot = Join-Path $env:TEMP ("osync-e2e-23-" + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss'))
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repo '.omo\evidence\task-23-ab-one-way-sync.log'
}
if ([string]::IsNullOrWhiteSpace($DoneFile)) {
    $DoneFile = Join-Path $env:TEMP 'osync-e2e-23.done'
}

$script:LandingRoot = $LandingRoot
$script:EvidencePath = $EvidencePath

# record the A-side env baseline BEFORE anything runs (unified teardown restores)
$script:NpmrcPath = Join-Path 'C:\Program Files\nodejs\node_modules\npm' 'npmrc'
if (Test-Path -LiteralPath $script:NpmrcPath -PathType Leaf) {
    $script:NpmrcBaselineBytes = [System.IO.File]::ReadAllBytes($script:NpmrcPath)
}
else {
    $script:NpmrcBaselineBytes = [byte[]]@()
}
$script:EnvVarBaseline = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')

Write-Evidence "===== todo 23 E2E failure matrix + regression start: $([datetime]::UtcNow.ToString('o')) ====="
Write-Evidence "repo root (module source): $repo"
Write-Evidence "landing root: $LandingRoot"
Write-Evidence "evidence: $EvidencePath"
Write-Evidence "elevated: $isAdmin"
Write-Evidence "D:\OfflineRepo exists (must stay untouched): $(Test-Path -LiteralPath 'D:\OfflineRepo')"
Write-Evidence "C:\OfflineRepo exists (must stay untouched): $(Test-Path -LiteralPath 'C:\OfflineRepo')"
Write-Evidence "C:\ProgramData\PakageSync exists (must stay untouched): $(Test-Path -LiteralPath 'C:\ProgramData\PakageSync')"
Write-Evidence "C:\PakageSync exists (self-refresh target - must stay untouched): $(Test-Path -LiteralPath 'C:\PakageSync')"
Write-Evidence "production task 'PakageSync-Export' exists (must stay untriggered): $($null -ne (Get-ScheduledTask -TaskName 'PakageSync-Export' -ErrorAction SilentlyContinue))"
Write-Evidence "port 8788 free (owned by this E2E): $(Test-PortFree -Port 8788)"
Write-Evidence "port 4873 free (owned by this E2E): $(Test-PortFree -Port 4873)"
Write-Evidence "machine NPM_CONFIG_REGISTRY baseline: [$($script:EnvVarBaseline)]"
Write-Evidence "built-in npmrc baseline: $script:NpmrcPath ($($script:NpmrcBaselineBytes.Length) bytes)"

try {
    New-Item -ItemType Directory -Path $script:LandingRoot -Force | Out-Null
    $script:LandingRoot = (Get-Item -LiteralPath $script:LandingRoot).FullName

    # hard abort if a default port is already taken (a false scenario result)
    Assert-E2EFatal (Test-PortFree -Port 8788) 'port 8788 free before the run (we own the default)'
    Assert-E2EFatal (Test-PortFree -Port 4873) 'port 4873 free before the run (we own the default)'

    # import the module once (read + orchestration functions, side-effect free)
    Import-Module (Join-Path $repo 'src\OfflineSync.psd1') -Force
    Write-Evidence "module imported: $(Join-Path $repo 'src\OfflineSync.psd1')"

    Test-E2EScenario1
    Test-E2EScenario2
    Test-E2EScenario3
    Test-E2EScenario4
    Test-E2EScenario5
    Test-E2EScenario6

    if (-not $SkipPester) {
        Invoke-E2EPesterRegression
    }
    else {
        Write-Evidence "SKIP: full Pester regression (-SkipPester)"
    }

    $overall = ($script:FailCount -eq 0)
    Write-Evidence ""
    Write-Evidence "===== E2E RESULT: $(if ($overall) { 'PASS' } else { 'FAIL' }) (pass=$script:PassCount fail=$script:FailCount) ====="

    [System.IO.File]::WriteAllText($DoneFile, "EXIT=$(if ($overall) { 0 } else { 1 })`r`n", $script:Utf8NoBom)
    exit $(if ($overall) { 0 } else { 1 })
}
catch {
    $err = $_.Exception.Message
    Write-Evidence "E2E FATAL: $err"
    try {
        [System.IO.File]::WriteAllText($DoneFile, "EXIT=1`r`n", $script:Utf8NoBom)
    }
    catch { }
    exit 1
}
finally {
    Invoke-E2ETeardown
}
