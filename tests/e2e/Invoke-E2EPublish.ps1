#Requires -Version 5.1
<#
  Invoke-E2EPublish.ps1 - todo 18: A-side publish smoke E2E (ab-one-way-sync).
  Windows PowerShell 5.1 compatible: no PS7-only syntax. UTF-8 WITH BOM.

  Drives the REAL src\Export-OfflineRepo.ps1 against an ISOLATED test landing
  dir (cloned config) and asserts the full A-side publish contract:

    1. Full-category export -> publish (run 1); Test-OSyncRepoIntegrity all OK.
    2. Immediate repeat export -> publish (run 2): payload file sha256 maps
       unchanged (repeat-publish idempotency) and index exportedAtUtc strictly
       advanced. (Each run is a FRESH staging dir - nothing is reused - so
       run 2 is a genuine independent re-publish.) The comparison covers
       PAYLOAD files only; a small set of known non-deterministic OPERATIONAL
       files is excluded and reported (see Test-OSyncPayloadFile): category
       export-report.json (timestamps), npm storage .verdaccio-db.json (random
       secret), npm storage package.json metadata (_rev / presence varies).
       The npm .tgz payloads are byte-identical across runs (observed in QA).
    3. index.json is the newest-mtime file in repoRoot (the logs dir is
       excluded: role A writes <repoRoot>\logs AFTER the publish - todo-11
       learning).
    4. Registers a QA-variant scheduled task 'PakageSync-Export-QA' pointing at
       the cloned test config, triggers it for real via schtasks /Run (S4U +
       Highest context, as the production task uses), asserts success, then
       unregisters it. The PRODUCTION task 'PakageSync-Export' is NEVER
       triggered.
    5. Failure scenario: apply a DENY-write ACL to the landing dir via icacls
       (Oracle m7: a read-only attribute would NOT block writes - a real ACL
       deny does), assert the export fails explicitly with a non-zero exit,
       then REMOVE the ACL and verify the landing is writable again.

  SAFETY (plan MUST NOT):
    - NEVER touches D:\OfflineRepo. The cloned config repoRoot always lives
      under the landing dir; a hard assert rejects any config that points at
      D:\OfflineRepo (and logs whether that path even exists - it is never
      created or written).
    - NEVER triggers the production 'PakageSync-Export' task; only the QA
      variant is registered/run/unregistered (and it is unregistered in a
      finally-style cleanup even on failure).

  The QA task action runs a small wrapper (written into the landing dir) that
  sets NPM_CONFIG_REGISTRY=https://registry.npmjs.org/ and then invokes the
  REAL export script with the cloned config. The registry override is the
  documented todo-11 workaround: this machine's user npmrc points at the
  operator's local Verdaccio (no uplink) which would 404 the runtime export's
  'npm install verdaccio@...'. The S4U + Highest + schtasks /Run launch is
  genuine - the wrapper only fixes the npm registry the same way the nightly
  production task needs it (todo-11 learning: "the nightly task env needs the
  override").

  Requires elevation. When launched without an admin token the script
  self-relaunches via Start-Process -Verb RunAs (this machine auto-elevates
  without a UAC prompt: ConsentPromptBehaviorAdmin=0).

  All output goes to the evidence file and a done marker - nothing meaningful
  is written to stdout, because the parent launches this detached and polls
  the done file (full exports take ~25 min each; the whole E2E is ~90 min).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\tests\e2e\Invoke-E2EPublish.ps1
        [-LandingRoot <dir>] [-EvidencePath <file>] [-DoneFile <file>]
        [-KeepArtifacts] [-SkipScheduledTask] [-SkipFailureScenario]
#>

[CmdletBinding()]
param(
    # Isolated test area (cloned config + repo + staging + runs). Defaults to
    # $env:TEMP\osync-e2e-18-<UTC stamp>.
    [string]$LandingRoot,

    # Evidence log path. Defaults to <repo>\.omo\evidence\task-18-ab-one-way-sync.log.
    [string]$EvidencePath,

    # Completion marker written at the very end (polled by the parent).
    [string]$DoneFile,

    # Keep all temp artifacts (default: the landing dir is deleted at the end).
    [switch]$KeepArtifacts,

    # Dev aid: skip the scheduled-task QA phase (register/run/unregister).
    [switch]$SkipScheduledTask,

    # Dev aid: skip the icacls DENY-write failure scenario.
    [switch]$SkipFailureScenario
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
$script:ExportScript = ''
$script:ConfigOut = ''
$script:RepoRoot = ''
$script:StagingRoot = ''
$script:LandingRoot = ''

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
        [System.IO.File]::WriteAllText($script:EvidencePath, '', (New-Object System.Text.UTF8Encoding($true)))
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
# repo helpers
# ---------------------------------------------------------------------------
function ConvertFrom-E2EJson {
    param([Parameter(Mandatory = $true)][string]$Text)
    # NOTE: ConvertFrom-Json has NO -Depth parameter (that is ConvertTo-Json
    # only); PS 5.1's JavaScriptSerializer recursion limit (100) and 2 MB
    # MaxJsonLength cap are both far above the fixture repo's index/files.json
    # sizes, so a plain ConvertFrom-Json is safe and correct here.
    return ($Text | ConvertFrom-Json)
}

# Reads a category's files.json into a hashtable relPath -> sha256 (files.json
# is regenerated fresh by New-OSyncFilesManifest on every publish, so its
# sha256 values ARE the actual on-disk payload hashes).
function Get-CategoryShaMap {
    param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][string]$Category)
    $map = @{}
    $fj = Join-Path $RepoRoot "$Category\files.json"
    if (Test-Path -LiteralPath $fj -PathType Leaf) {
        $obj = ConvertFrom-E2EJson -Text ([System.IO.File]::ReadAllText($fj))
        foreach ($p in $obj.PSObject.Properties) {
            $map[$p.Name] = [string]$p.Value.sha256
        }
    }
    return $map
}

function Get-CategoryShaMaps {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $result = @{}
    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
        $result[$cat] = Get-CategoryShaMap -RepoRoot $RepoRoot -Category $cat
    }
    return $result
}

# Diff of two cat->map hashtables over PAYLOAD files only. Returns
# { Diff = @(); Excluded = @() } - Diff lists payload changes, Excluded lists
# the known non-deterministic OPERATIONAL files that were skipped (each is
# documented; they are not deliverable payload):
#   - <cat>/export-report.json        : per-category report embedding run
#                                       timestamps (startedAtUtc/finishedAtUtc)
#   - npm/storage/.verdaccio-db.json  : random 'secret' generated per Verdaccio
#                                       instance start (observed in QA)
#   - npm/storage/npm/package.json    : registry self-metadata; presence varies
#                                       between warm-up runs (observed in QA)
#   - npm/storage/<pkg>/package.json  : per-package metadata whose CouchDB
#                                       '_rev' is instance-specific (observed in
#                                       QA); the .tgz payload is byte-identical
function Test-OSyncPayloadFile {
    param([Parameter(Mandatory = $true)][string]$Category, [Parameter(Mandatory = $true)][string]$RelPath)
    if ($RelPath -eq 'export-report.json') { return $false }
    if ($Category -eq 'npm') {
        if ($RelPath -eq 'storage/.verdaccio-db.json') { return $false }
        if ($RelPath -eq 'storage/npm/package.json') { return $false }
        if ($RelPath -match '^storage/[^/]+/package\.json$') { return $false }
    }
    return $true
}

function Compare-ShaMaps {
    param($A, $B)
    $diff = @()
    $excluded = @()
    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
        if (-not $B.ContainsKey($cat)) { $diff += "category '$cat' has no files.json in run 2"; continue }
        $ma = $A[$cat]; $mb = $B[$cat]
        foreach ($k in $ma.Keys) {
            if (-not (Test-OSyncPayloadFile -Category $cat -RelPath $k)) {
                $excluded += "$cat/$k"
                continue
            }
            if (-not $mb.ContainsKey($k)) { $diff += "${cat}: file missing in run 2: $k" }
            elseif ($mb[$k] -ne $ma[$k]) { $diff += "${cat}: sha256 changed: $k ($($ma[$k]) -> $($mb[$k]))" }
        }
        foreach ($k in $mb.Keys) {
            if (-not (Test-OSyncPayloadFile -Category $cat -RelPath $k)) { continue }
            if (-not $ma.ContainsKey($k)) { $diff += "${cat}: unexpected extra file in run 2: $k" }
        }
    }
    return [pscustomobject]@{ Diff = @($diff); Excluded = @($excluded) }
}

function Format-Integrity {
    param($R)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("integrity.Overall: $($R.Overall)")
    foreach ($e in $R.Categories.GetEnumerator()) {
        $s = $e.Value
        $lines.Add(("  category {0}: {1}" -f $e.Key, $s.Status))
        if ($s.MissingFiles.Count -gt 0) { $lines.Add(("    missing: {0}" -f ($s.MissingFiles -join ', '))) }
        if ($s.CorruptFiles.Count -gt 0) { $lines.Add(("    corrupt: {0}" -f ($s.CorruptFiles -join ', '))) }
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-LatestExportReport {
    param([Parameter(Mandatory = $true)][string]$StagingRoot)
    $dir = Get-ChildItem -LiteralPath $StagingRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($null -eq $dir) { return $null }
    $rp = Join-Path $dir.FullName 'export-report.json'
    if (Test-Path -LiteralPath $rp -PathType Leaf) {
        return [System.IO.File]::ReadAllText($rp)
    }
    return $null
}

function Get-IndexExportedAtUtc {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $idxPath = Join-Path $RepoRoot 'index.json'
    if (-not (Test-Path -LiteralPath $idxPath -PathType Leaf)) { return $null }
    $idx = ConvertFrom-E2EJson -Text ([System.IO.File]::ReadAllText($idxPath))
    return [string]$idx.exportedAtUtc
}

function Test-PortFree {
    param([Parameter(Mandatory = $true)][int]$Port)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try { $l.Start(); return $true }
    catch { return $false }
    finally { $l.Stop() }
}

function Get-EFreePort {
    param([Parameter(Mandatory = $true)][int]$Start)
    foreach ($p in $Start..($Start + 25)) {
        if (Test-PortFree -Port $p) { return $p }
    }
    return $Start
}

# Launches the REAL Export-OfflineRepo.ps1 as a child powershell (the driver is
# already elevated, so the child inherits elevation - no RunAs here, which
# allows -RedirectStandardOutput). Returns the process exit code (Start-Process
# -Wait -PassThru populates ExitCode under PS 5.1 - todo-16 learning).
function Invoke-ExportRun {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$OutLog,
        [Parameter(Mandatory = $true)][string]$ErrLog
    )
    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $script:ExportScript),
        '-ConfigPath', ('"{0}"' -f $script:ConfigOut),
        '-Category', 'winget,pip,npm,dotfiles'
    )
    Write-Evidence "  command: powershell.exe $($argList -join ' ')"
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog
    return [int]$p.ExitCode
}

# Appends the tail of a run log (if present) to the evidence.
function Write-RunLogTail {
    param([Parameter(Mandatory = $true)][string]$Path, [int]$Lines = 30)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $all = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) { return }
    $tail = @($all | Select-Object -Last $Lines)
    Write-Evidence "  --- $([System.IO.Path]::GetFileName($Path)) tail (last $($tail.Count) of $($all.Count)) ---"
    foreach ($line in $tail) { Write-Evidence "    $line" }
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
    $LandingRoot = Join-Path $env:TEMP ("osync-e2e-18-" + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss'))
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repo '.omo\evidence\task-18-ab-one-way-sync.log'
}
if ([string]::IsNullOrWhiteSpace($DoneFile)) {
    $DoneFile = Join-Path $env:TEMP 'osync-e2e-18.done'
}

$script:LandingRoot = $LandingRoot
$script:EvidencePath = $EvidencePath
$script:RepoRoot = Join-Path $LandingRoot 'repo'
$script:StagingRoot = Join-Path $LandingRoot 'staging'
$script:ExportScript = Join-Path $repo 'src\Export-OfflineRepo.ps1'
$script:ConfigOut = Join-Path $LandingRoot 'config\packagesync.json'
$wrapperPath = Join-Path $LandingRoot 'wrapper\run-task.ps1'
$runsDir = Join-Path $LandingRoot 'runs'

Write-Evidence "===== todo 18 E2E publish smoke start: $([datetime]::UtcNow.ToString('o')) ====="
Write-Evidence "repo root (module source): $repo"
Write-Evidence "landing root: $LandingRoot"
Write-Evidence "evidence: $EvidencePath"
Write-Evidence "elevated: $isAdmin"
Write-Evidence "D:\OfflineRepo exists (must stay untouched): $(Test-Path -LiteralPath 'D:\OfflineRepo')"
$prodTaskPresent = $null -ne (Get-ScheduledTask -TaskName 'PakageSync-Export' -ErrorAction SilentlyContinue)
Write-Evidence "production task 'PakageSync-Export' exists (must stay untriggered): $prodTaskPresent"

try {
    # --- dirs ---
    foreach ($d in @('config', 'repo', 'staging', 'runs', 'wrapper')) {
        New-Item -ItemType Directory -Path (Join-Path $LandingRoot $d) -Force | Out-Null
    }

    # --- normalize to LONG path form ---
    # $env:TEMP resolves to the 8.3 short form (ADMINI~1) but Get-ChildItem /
    # Get-Item return long-form FullNames (Administrator); comparing the two
    # forms silently fails (observed in QA: the logs-dir exclusion and the
    # index.json newest-mtime comparison both missed). Normalize once here.
    $script:LandingRoot = (Get-Item -LiteralPath $script:LandingRoot).FullName
    $script:RepoRoot = (Get-Item -LiteralPath $script:RepoRoot).FullName
    $script:StagingRoot = (Get-Item -LiteralPath $script:StagingRoot).FullName
    $script:ConfigOut = Join-Path $script:LandingRoot 'config\packagesync.json'
    $wrapperPath = Join-Path $script:LandingRoot 'wrapper\run-task.ps1'
    $runsDir = Join-Path $script:LandingRoot 'runs'
    Write-Evidence "normalized landing root: $script:LandingRoot"

    # --- clone + retarget the config (never edits the real config) ---
    $srcConfig = Join-Path $repo 'config\packagesync.json'
    $cfg = Get-Content -LiteralPath $srcConfig -Raw -Encoding UTF8 | ConvertFrom-Json
    $httpPort = 8789               # non-default (parallel todo-17 QA may run concurrently)
    $verdaccioPort = 4897          # non-default, avoids 4873
    $aVerdaccioPort = Get-EFreePort -Start 4898   # one-shot warm-up port must be free
    $cfg.repoRoot = $script:RepoRoot
    $cfg.stagingRoot = $script:StagingRoot
    $cfg.stateDir = Join-Path $LandingRoot 'state'
    $cfg.httpPort = $httpPort
    $cfg.verdaccioPort = $verdaccioPort
    $cfg.npm.aVerdaccioPort = $aVerdaccioPort
    $newJson = $cfg | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:ConfigOut, $newJson, (New-Object System.Text.UTF8Encoding($true)))
    Write-Evidence "cloned config: $script:ConfigOut"
    Write-Evidence "  repoRoot=$script:RepoRoot stagingRoot=$script:StagingRoot stateDir=$($cfg.stateDir)"
    Write-Evidence "  httpPort=$httpPort verdaccioPort=$verdaccioPort npm.aVerdaccioPort=$aVerdaccioPort"

    # --- import the module for integrity checks (read-only, side-effect free) ---
    Import-Module (Join-Path $repo 'src\OfflineSync.psd1') -Force

    # --- config guards ---
    $c = Get-OSyncConfig -Path $script:ConfigOut
    Assert-E2EFatal ($c.role -eq 'A') 'cloned config role is A' "(got '$($c.role)')"
    Assert-E2EFatal ($c.repoRoot -ne 'D:\OfflineRepo') 'cloned config NEVER points at D:\OfflineRepo'
    Assert-E2EFatal ($c.repoRoot.StartsWith($script:LandingRoot, [StringComparison]::OrdinalIgnoreCase)) 'cloned config repoRoot lives under the landing dir' "($($c.repoRoot))"
    Assert-E2EFatal (Test-Path -LiteralPath $script:ExportScript -PathType Leaf) 'Export-OfflineRepo.ps1 present'

    # --- place the fixture manifests inside the test TOOL root ---
    # config.paths.* are tool-root-relative INPUT manifests: they resolve
    # against the parent of the config file's parent (<LandingRoot>, where the
    # cloned config lives at <LandingRoot>\config\packagesync.json) - NEVER
    # against config.repoRoot (the output landing dir <LandingRoot>\repo).
    # The manifests dir survives /MIR publishes because it is not a category
    # dir, and Test-OSyncRepoIntegrity ignores un-manifested extra dirs (out
    # of contract scope, RepoContract header).
    Copy-Item -LiteralPath (Join-Path $repo 'manifests') -Destination (Join-Path $script:LandingRoot 'manifests') -Recurse -Force
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:LandingRoot 'manifests\winget-packages.txt') -PathType Leaf) 'fixture winget whitelist staged under the test tool root'
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:LandingRoot 'manifests\requirements.txt') -PathType Leaf) 'fixture requirements staged under the test tool root'
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:LandingRoot 'manifests\dotfiles') -PathType Container) 'fixture dotfiles source staged under the test tool root'

    # --- env for the export children (inherited) ---
    # NPM_CONFIG_REGISTRY override = documented todo-11 workaround (user npmrc
    # points at the operator's no-uplink Verdaccio). WindowsApps is NOT stripped:
    # the todo-7 Resolve-OSyncPython fix probes multiple candidates.
    $env:NPM_CONFIG_REGISTRY = 'https://registry.npmjs.org/'

    # =====================================================================
    # RUN 1: full export -> publish
    # =====================================================================
    Write-Evidence ""
    Write-Evidence "=== RUN 1: full export -> publish (elevated child, cloned config) ==="
    $run1Out = Join-Path $runsDir 'run1.out.log'
    $run1Err = Join-Path $runsDir 'run1.err.log'
    $t0 = Get-Date
    $code1 = Invoke-ExportRun -Name run1 -OutLog $run1Out -ErrLog $run1Err
    $el1 = (Get-Date) - $t0
    Write-Evidence "run 1 exit code: $code1 (elapsed $([int]$el1.TotalMinutes) min $($el1.Seconds) s)"
    Write-RunLogTail -Path $run1Err
    Assert-E2EFatal ($code1 -eq 0) 'run 1 exits 0' "(got $code1)"

    $report1 = Get-LatestExportReport -StagingRoot $script:StagingRoot
    Assert-E2EFatal (-not [string]::IsNullOrWhiteSpace($report1)) 'run 1 export-report.json produced'
    if ($report1) {
        Write-Evidence "--- run 1 export-report.json ---"
        Write-Evidence $report1
    }

    $integrity1 = Test-OSyncRepoIntegrity -RepoRoot $script:RepoRoot
    Write-Evidence "--- run 1 integrity (published repo) ---"
    Write-Evidence (Format-Integrity -R $integrity1)
    Assert-E2EFatal ($integrity1.Overall -eq 'OK') 'run 1 integrity Overall = OK' "(got '$($integrity1.Overall)')"
    $allCatOk1 = $true
    foreach ($e in $integrity1.Categories.GetEnumerator()) { if ($e.Value.Status -ne 'OK') { $allCatOk1 = $false } }
    Assert-E2EFatal $allCatOk1 'run 1 all categories OK'

    $exported1 = Get-IndexExportedAtUtc -RepoRoot $script:RepoRoot
    Assert-E2EFatal ($exported1 -match '^\d{8}T\d{6}Z$') 'run 1 index exportedAtUtc format' "(got '$exported1')"
    Write-Evidence "run 1 index exportedAtUtc: $exported1"

    $maps1 = Get-CategoryShaMaps -RepoRoot $script:RepoRoot
    $counts1 = @()
    foreach ($cat in $maps1.Keys) { $counts1 += "$cat=$($maps1[$cat].Count)" }
    Write-Evidence "run 1 payload file counts: $($counts1 -join ' ')"

    # =====================================================================
    # RUN 2: immediate repeat export -> publish (fresh staging, idempotency)
    # =====================================================================
    Write-Evidence ""
    Write-Evidence "=== RUN 2: repeat export -> publish (fresh staging) ==="
    $run2Out = Join-Path $runsDir 'run2.out.log'
    $run2Err = Join-Path $runsDir 'run2.err.log'
    $t0 = Get-Date
    $code2 = Invoke-ExportRun -Name run2 -OutLog $run2Out -ErrLog $run2Err
    $el2 = (Get-Date) - $t0
    Write-Evidence "run 2 exit code: $code2 (elapsed $([int]$el2.TotalMinutes) min $($el2.Seconds) s)"
    Write-RunLogTail -Path $run2Err
    Assert-E2EFatal ($code2 -eq 0) 'run 2 exits 0' "(got $code2)"

    $report2 = Get-LatestExportReport -StagingRoot $script:StagingRoot
    Assert-E2EFatal (-not [string]::IsNullOrWhiteSpace($report2)) 'run 2 export-report.json produced'
    if ($report2) {
        Write-Evidence "--- run 2 export-report.json ---"
        Write-Evidence $report2
    }

    $integrity2 = Test-OSyncRepoIntegrity -RepoRoot $script:RepoRoot
    Write-Evidence "--- run 2 integrity (published repo) ---"
    Write-Evidence (Format-Integrity -R $integrity2)
    Assert-E2EFatal ($integrity2.Overall -eq 'OK') 'run 2 integrity Overall = OK' "(got '$($integrity2.Overall)')"
    $allCatOk2 = $true
    foreach ($e in $integrity2.Categories.GetEnumerator()) { if ($e.Value.Status -ne 'OK') { $allCatOk2 = $false } }
    Assert-E2EFatal $allCatOk2 'run 2 all categories OK'

    $exported2 = Get-IndexExportedAtUtc -RepoRoot $script:RepoRoot
    Assert-E2EFatal ($exported2 -match '^\d{8}T\d{6}Z$') 'run 2 index exportedAtUtc format' "(got '$exported2')"
    Write-Evidence "run 2 index exportedAtUtc: $exported2"

    # --- repeat-publish idempotency: payload sha256 maps unchanged ---
    $maps2 = Get-CategoryShaMaps -RepoRoot $script:RepoRoot
    $cmp = Compare-ShaMaps -A $maps1 -B $maps2
    $diff = @($cmp.Diff)
    Write-Evidence "--- repeat-publish idempotency ---"
    if ($cmp.Excluded.Count -gt 0) {
        Write-Evidence "excluded operational (non-payload) files from the comparison: $($cmp.Excluded -join ', ')"
    }
    if ($diff.Count -eq 0) {
        Write-Evidence "payload sha256 maps identical between run 1 and run 2 (all $($maps1.Keys.Count) categories)"
    }
    else {
        Write-Evidence "payload diff entries: $($diff.Count)"
        foreach ($d in $diff) { Write-Evidence "  DIFF: $d" }
    }
    Assert-E2E ($diff.Count -eq 0) 'repeat-publish idempotency: payload file sha256 unchanged' "(diff entries: $($diff.Count))"

    # --- index exportedAtUtc advanced (fixed-width zero-padded -> ordinal compare) ---
    Assert-E2E ($exported2 -gt $exported1) 'repeat-publish: index exportedAtUtc updated' "($exported1 -> $exported2)"

    # --- index.json is the newest-mtime file in repoRoot (logs excluded) ---
    $logsDir = Join-Path $script:RepoRoot 'logs'
    $repoFiles = @(Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -ne $logsDir -and
            -not $_.FullName.StartsWith($logsDir + '\', [StringComparison]::OrdinalIgnoreCase)
        })
    $newest = $repoFiles | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    $indexFile = (Join-Path $script:RepoRoot 'index.json')
    if ($null -ne $newest) {
        Write-Evidence "newest file in repoRoot (excl. logs): $($newest.FullName)  mtime=$($newest.LastWriteTimeUtc.ToString('o'))"
        Write-Evidence "index.json mtime: $((Get-Item -LiteralPath $indexFile).LastWriteTimeUtc.ToString('o'))"
        Assert-E2E ($newest.FullName -ieq $indexFile) 'index.json is the newest-mtime file in repoRoot (logs excluded)' "(newest: $($newest.Name))"
    }
    else {
        Assert-E2E $false 'index.json is the newest-mtime file in repoRoot' 'no files found in repoRoot'
    }

    # =====================================================================
    # SCHEDULED TASK QA: PakageSync-Export-QA (S4U context, real /Run)
    # =====================================================================
    if (-not $SkipScheduledTask) {
        Write-Evidence ""
        Write-Evidence "=== SCHEDULED TASK QA: PakageSync-Export-QA (S4U + Highest, real schtasks /Run) ==="

        # wrapper: registry override then the REAL export script (todo-11 workaround)
        $wrapperBody = @"
`$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
`$env:NPM_CONFIG_REGISTRY = 'https://registry.npmjs.org/'
& '$script:ExportScript' -ConfigPath '$script:ConfigOut' -Category 'winget,pip,npm,dotfiles'
"@
        [System.IO.File]::WriteAllText($wrapperPath, $wrapperBody, (New-Object System.Text.UTF8Encoding($true)))
        Write-Evidence "task wrapper written: $wrapperPath"

        # far-future trigger: the daily 02:00 StartBoundary can never fire during QA
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $wrapperPath)
        $trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date '2035-01-01T02:00:00')
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew

        try {
            Register-ScheduledTask -TaskName 'PakageSync-Export-QA' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
            $qaTask = Get-ScheduledTask -TaskName 'PakageSync-Export-QA'
            Write-Evidence "registered PakageSync-Export-QA: State=$($qaTask.State) Principal=$($qaTask.Principal.UserId)/$($qaTask.Principal.LogonType)/$($qaTask.Principal.RunLevel)"
            Write-Evidence "  Action: $($qaTask.Actions[0].Execute) $($qaTask.Actions[0].Arguments)"
            Assert-E2EFatal ($qaTask.State -eq 'Ready') 'QA task registered and Ready'

            $preInfo = Get-ScheduledTaskInfo -TaskName 'PakageSync-Export-QA'
            & schtasks.exe /Run /TN 'PakageSync-Export-QA' | Out-Null
            $schtasksExit = $LASTEXITCODE
            Assert-E2EFatal ($schtasksExit -eq 0) 'schtasks /Run PakageSync-Export-QA accepted' "(exit $schtasksExit)"

            # poll until the task actually started AND finished
            # Task Scheduler result codes: 267008 = SCHED_S_TASK_HAS_NOT_RUN,
            # 267009 = SCHED_S_TASK_RUNNING (0x41301), 0 = success, other =
            # failure. (QA hit: 267011 is SCHED_S_TASK_READY - the STATE, not a
            # result - polling on it broke out while the task was still running.)
            $deadline = (Get-Date).AddMinutes(80)
            $taskResult = $null
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 15
                $info = Get-ScheduledTaskInfo -TaskName 'PakageSync-Export-QA' -ErrorAction SilentlyContinue
                if ($null -eq $info) { continue }
                $started = ($info.LastRunTime -gt $preInfo.LastRunTime)
                $finished = ($info.LastTaskResult -notin @(267008, 267009))
                if ($started -and $finished) {
                    $taskResult = $info.LastTaskResult
                    break
                }
            }
            if ($null -ne $info) {
                Write-Evidence "QA task LastRunTime=$($info.LastRunTime.ToString('o')) LastTaskResult=$taskResult"
            }
            else {
                Write-Evidence "QA task info never became available; LastTaskResult=$taskResult"
            }
            Assert-E2EFatal ($null -ne $taskResult) 'QA task completed within 80 min' "(LastTaskResult=$taskResult)"
            Assert-E2EFatal ($taskResult -eq 0) 'QA task ran successfully (S4U context export + publish)' "(LastTaskResult=$taskResult)"

            # the task published into the SAME test repoRoot -> re-verify integrity + index advanced
            $integrityTask = Test-OSyncRepoIntegrity -RepoRoot $script:RepoRoot
            Write-Evidence "--- integrity after QA task run ---"
            Write-Evidence (Format-Integrity -R $integrityTask)
            Assert-E2EFatal ($integrityTask.Overall -eq 'OK') 'repo integrity OK after QA task publish' "(got '$($integrityTask.Overall)')"
            $exportedTask = Get-IndexExportedAtUtc -RepoRoot $script:RepoRoot
            Write-Evidence "index exportedAtUtc after QA task: $exportedTask"
            Assert-E2E ($exportedTask -gt $exported2) 'QA task publish advanced index exportedAtUtc' "($exported2 -> $exportedTask)"
        }
        finally {
            # ALWAYS unregister the QA variant (also on failure)
            if (Get-ScheduledTask -TaskName 'PakageSync-Export-QA' -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName 'PakageSync-Export-QA' -Confirm:$false
                Write-Evidence "unregistered PakageSync-Export-QA"
            }
        }
        Assert-E2EFatal ($null -eq (Get-ScheduledTask -TaskName 'PakageSync-Export-QA' -ErrorAction SilentlyContinue)) 'QA task unregistered'
    }
    else {
        Write-Evidence "SKIP: scheduled task QA (-SkipScheduledTask)"
    }

    # =====================================================================
    # FAILURE SCENARIO: DENY-write ACL on the landing dir (Oracle m7)
    # =====================================================================
    if (-not $SkipFailureScenario) {
        Write-Evidence ""
        Write-Evidence "=== FAILURE SCENARIO: icacls DENY-write on repoRoot -> export must fail explicitly ==="
        Write-Evidence "deny Everyone:(OI)(CI)(WD,AD,DC) on $script:RepoRoot"
        & icacls.exe $script:RepoRoot /deny "*S-1-1-0:(OI)(CI)(WD,AD,DC)" | Out-Null
        Assert-E2EFatal ($LASTEXITCODE -eq 0) 'icacls DENY-write applied' "(exit $LASTEXITCODE)"

        # prove the ACL really blocks writes (Oracle m7: a read-only attribute would NOT)
        $probe = Join-Path $script:RepoRoot 'e2e-probe.txt'
        $probeBlocked = $false
        try {
            [System.IO.File]::WriteAllText($probe, 'probe', (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            $probeBlocked = $true
        }
        Assert-E2E $probeBlocked 'DENY-write ACL blocks a real write to the landing dir (Oracle m7)' "(blocked=$probeBlocked)"

        # export against the write-denied landing -> explicit error + non-zero exit
        $run3Out = Join-Path $runsDir 'run3.out.log'
        $run3Err = Join-Path $runsDir 'run3.err.log'
        $t0 = Get-Date
        $code3 = Invoke-ExportRun -Name run3 -OutLog $run3Out -ErrLog $run3Err
        $el3 = (Get-Date) - $t0
        Write-Evidence "run 3 (write-denied landing) exit code: $code3 (elapsed $([int]$el3.TotalMinutes) min $($el3.Seconds) s)"
        Write-RunLogTail -Path $run3Out
        Write-RunLogTail -Path $run3Err
        Assert-E2E ($code3 -ne 0) 'export against write-denied landing exits non-zero' "(got $code3)"

        # REMOVE the ACL (must be removed before cleanup, and verified)
        & icacls.exe $script:RepoRoot /remove:d "*S-1-1-0" | Out-Null
        Assert-E2EFatal ($LASTEXITCODE -eq 0) 'icacls DENY removed' "(exit $LASTEXITCODE)"
        $restored = $false
        try {
            [System.IO.File]::WriteAllText($probe, 'probe', (New-Object System.Text.UTF8Encoding($false)))
            [System.IO.File]::Delete($probe)
            $restored = $true
        }
        catch {
            $restored = $false
        }
        Assert-E2E $restored 'landing dir writable again after ACL removal'
    }
    else {
        Write-Evidence "SKIP: failure scenario (-SkipFailureScenario)"
    }

    # =====================================================================
    # wrap-up
    # =====================================================================
    $overall = ($script:FailCount -eq 0)
    Write-Evidence ""
    Write-Evidence "===== E2E RESULT: $(if ($overall) { 'PASS' } else { 'FAIL' }) (pass=$script:PassCount fail=$script:FailCount) ====="

    [System.IO.File]::WriteAllText($DoneFile, "EXIT=$(if ($overall) { 0 } else { 1 })`r`n", (New-Object System.Text.UTF8Encoding($false)))

    if (-not $KeepArtifacts) {
        Write-Evidence "self-cleanup: removing landing dir $LandingRoot"
        Remove-Item -LiteralPath $LandingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Evidence "KeepArtifacts set - landing dir retained: $LandingRoot"
    }

    exit $(if ($overall) { 0 } else { 1 })
}
catch {
    $err = $_.Exception.Message
    Write-Evidence "E2E FATAL: $err"
    try {
        [System.IO.File]::WriteAllText($DoneFile, "EXIT=1`r`n", (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { }
    exit 1
}
