#Requires -Version 5.1
<#
  Invoke-E2EPipNpm.ps1 - todo 21: E2E for the pip + npm apply chains (ab-one-way-sync).
  Windows PowerShell 5.1 compatible: no PS7-only syntax. UTF-8 WITH BOM.

  Drives the REAL production libs (Invoke-OSyncPipApply / Invoke-OSyncNpmApply
  from src\OfflineSync.psd1) plus the REAL per-category export functions
  (Export-OSyncPip / Export-OSyncNpm - the exact functions Export-OfflineRepo.ps1
  calls) against an ISOLATED test landing dir, simulating a full A export -> B
  apply cycle on the A machine:

  PIP chain (A-side venv sandbox, -PythonPath QA seam):
    1. requirements fixture copy set to six==1.16.0; round-1 export
       (pip + npm categories) -> files.json + index.json -> integrity OK ->
       mirror to the B-side work copy.
    2. python -m venv; Invoke-OSyncPipApply -> venv pip list shows six 1.16.0;
       state.pip records it.
    3. requirements copy bumped to six==1.17.0 (the NEW version); round-2 export
       (pip category) -> mirror -> re-apply WITH --upgrade (config
       pip.upgradeOnApply=true) -> venv pip list shows six 1.17.0; the JSONL log
       proves the --upgrade flag reached the pip command line.

  NPM chain (portable Verdaccio + real scheduled-task stop->copy->start path):
    4. Temporary QA task 'PakageSync-Verdaccio-QA' runs the portable Verdaccio
       (from the export's .verdaccio-a install) against the apply-refreshed
       local copy <stateDir>\verdaccio\verdaccio-b.yml (storage ./storage,
       NO uplinks - proven by the ghost fast-fail).
    5. Invoke-OSyncNpmApply -VerdaccioTaskName 'PakageSync-Verdaccio-QA':
       npm view is-odd@3.0.1 hit, ghost fails fast (<30 s), new-process
       `npm config get registry` == local, npmrc rewrite + .osyncbak backup.
    6. Second apply with the task Running: strict stop->copy->start order,
       idempotent npmrc (single registry line), backup never overwritten.
    7. `npm install is-odd@3.0.1` WITHOUT --registry and WITHOUT --offline ->
       the machine's ONLY registry is the local one (builtin npmrc + machine
       NPM_CONFIG_REGISTRY) -> install hits the snapshot (is-odd 3.0.1 +
       is-number dep), proving no external-network dependency.
    8. FAILURE: occupy the QA verdaccio port -> Invoke-OSyncNpmApply throws an
       error that clearly names the port.

  NOTE (documented deviation): the full orchestrator (Export-OfflineRepo.ps1)
  ALWAYS re-runs the runtime category, which re-downloads the Python/Node
  payloads (plus VC_redist) into a FRESH staging dir every run. The
  runtime payload is a bootstrap artifact that the pip/npm apply chains never
  consume, and aka.ms was observed flaky during QA (HTTP 503 + connection
  reset on consecutive runs). The E2E therefore publishes only the categories
  under test through the module's own export functions + the trust-root
  (files.json + index.json) - the exact contract the B-side apply consumes.
  The runtime category is covered by todos 10/12/17/20.

  SAFETY / HYGIENE (plan MUST):
    - Cloned config uses verdaccioPort NON-4873 (free-probed; parallel todo-23
      squats 4873 / todo-20 runs concurrently), aVerdaccioPort and httpPort
      also non-default and free-probed.
    - A's built-in npmrc is restored from its pre-run bytes and the machine
      NPM_CONFIG_REGISTRY is removed at the end (try/finally, even on failure).
    - All QA scheduled tasks are temp-named and unregistered in the same run.
    - Landing dir removed with the MAX_PATH-safe '\\?\' delete pattern.
    - NO git commands; no src/ or config/ edits; no permanent scheduled tasks.

  All output goes to the evidence file; nothing meaningful to stdout (the
  parent launches this and polls the done file; full E2E ~45-60 min).

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\tests\e2e\Invoke-E2EPipNpm.ps1
        [-LandingRoot <dir>] [-EvidencePath <file>] [-DoneFile <file>]
        [-KeepArtifacts] [-SkipPesterFinal]
#>

[CmdletBinding()]
param(
    [string]$LandingRoot,
    [string]$EvidencePath,
    [string]$DoneFile,
    [switch]$KeepArtifacts,
    # Dev aid: skip the final full-suite Pester run (both shells) at the end.
    [switch]$SkipPesterFinal
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
$script:RepoRoot = ''
$script:StagingRoot = ''
$script:StateDir = ''
$script:WorkCopy = ''
$script:ConfigOut = ''
$script:ExportScript = ''
$script:RunsDir = ''
$script:QaVerdaccioPort = 0
$script:QaVerdaccioUrl = ''
$script:QaTaskName = 'PakageSync-Verdaccio-QA'
$script:NodeExe = ''
$script:MachinePy = 'C:\Program Files\Python312\python.exe'
$script:VenvPy = ''
$script:DummyPid = $null

# ---------------------------------------------------------------------------
# evidence + assertion helpers (same shape as todo 18)
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
# port + process helpers
# ---------------------------------------------------------------------------
function Test-PortFree {
    param([Parameter(Mandatory = $true)][int]$Port)
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    try { $l.Start(); return $true }
    catch { return $false }
    finally { $l.Stop() }
}

function Get-EFreePort {
    param([Parameter(Mandatory = $true)][int]$Start)
    foreach ($p in $Start..($Start + 30)) {
        if (Test-PortFree -Port $p) { return $p }
    }
    return $Start
}

function Wait-E2EPortFree {
    param([Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutSeconds = 20)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-PortFree -Port $Port) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (Test-PortFree -Port $Port)
}

function Wait-E2EPortListening {
    param([Parameter(Mandatory = $true)][int]$Port, [int]$TimeoutSeconds = 30)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (-not (Test-PortFree -Port $Port)) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return (-not (Test-PortFree -Port $Port))
}

function Get-E2EListenerPids {
    param([Parameter(Mandatory = $true)][int]$Port)
    $pids = @()
    try {
        $conns = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        foreach ($c in $conns) {
            if ($c.OwningProcess -gt 0 -and $pids -notcontains $c.OwningProcess) { $pids += $c.OwningProcess }
        }
    }
    catch { }
    return @($pids)
}

function Stop-E2EListener {
    param([Parameter(Mandatory = $true)][int]$Port)
    # NOTE: $pid is a READ-ONLY automatic variable in PowerShell - using it as
    # a foreach loop variable throws SessionStateUnauthorizedAccessException
    # (bit us in QA: the cleanup finally died mid-restore). Use $procId.
    foreach ($procId in @(Get-E2EListenerPids -Port $Port)) {
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch { }
        Write-Evidence "  stopped listener pid $procId on port $Port"
    }
}

# MAX_PATH-safe tree delete (verified pattern, todo-8): clear read-only flags
# first (Directory.Delete(,true) fails on readonly files), then the '\\?\' long
# path, then cmd rd as a fallback.
function Remove-E2ETree {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $_.IsReadOnly } | ForEach-Object { $_.IsReadOnly = $false }
    }
    catch { }
    try {
        $longPath = '\\?\' + (Resolve-Path -LiteralPath $Path).Path
        [System.IO.Directory]::Delete($longPath, $true)
        return
    }
    catch {
        Write-Evidence "  Remove-E2ETree \\?\ fallback note: $($_.Exception.Message)"
    }
    cmd.exe /c rd /s /q "`"$Path`"" | Out-Null
}

# ---------------------------------------------------------------------------
# npm / pip command helpers (native calls, EAP=Continue scoping - PS 5.1)
# ---------------------------------------------------------------------------
function Invoke-ENpm {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$WorkingDirectory = ''
    )
    $argText = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/d /s /c ""' + $script:NpmCmd + '" ' + $argText + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) { $psi.WorkingDirectory = $WorkingDirectory }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit(120000)
    if (-not $exited) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $null = & taskkill.exe /PID $proc.Id /T /F 2>&1 } catch { }
        finally { $ErrorActionPreference = $oldEap }
        return [pscustomobject]@{ ExitCode = -1; Output = 'TIMEOUT'; TimedOut = $true }
    }
    $lines = @()
    $lines += ($outTask.Result -split "`r?`n")
    $lines += ($errTask.Result -split "`r?`n")
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = ($lines -join "`n"); TimedOut = $false }
}

function Invoke-EPython {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PythonPath @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    if ($null -eq $exitCode) { $exitCode = -1 }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = [string]$output }
}

function Get-E2EPipPackageVersion {
    param([Parameter(Mandatory = $true)][string]$Package)
    $r = Invoke-EPython -PythonPath $script:VenvPy -Arguments @('-m', 'pip', 'list', '--format=json')
    $jsonLine = ($r.Output -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('[') } | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        throw "pip list produced no JSON line: $($r.Output)"
    }
    $pkgs = $jsonLine | ConvertFrom-Json
    $found = @($pkgs | Where-Object { $_.name -eq $Package })
    if ($found.Count -eq 0) { return $null }
    return ([string]$found[0].version)
}

function Get-E2EFreshNpmRegistry {
    # A genuinely NEW process (cmd -> npm.cmd) so the builtin npmrc is read
    # fresh; the driver's own env has no NPM_CONFIG_REGISTRY.
    $outFile = Join-Path $script:RunsDir 'npm-registry-get.txt'
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/d /s /c "npm config get registry"' `
        -Wait -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + '.err')
    if (Test-Path -LiteralPath $outFile) {
        return ((Get-Content -LiteralPath $outFile -Raw) -replace "`r?`n", '').Trim()
    }
    return ''
}

# ---------------------------------------------------------------------------
# export / mirror helpers
# ---------------------------------------------------------------------------
# Publishes the given categories through the module's OWN export functions
# (the exact functions Export-OfflineRepo.ps1 calls) into a fresh staging
# generation, then writes files.json + index.json and publishes to the repo
# root - the same trust-root contract the B-side apply consumes.
#
# NOTE (documented deviation): the full orchestrator ALWAYS re-runs the
# runtime category, which re-downloads the Python/Node payloads (plus
# VC_redist) into a FRESH staging dir every run (download-if-missing is
# per-staging-dir). The runtime payload is a bootstrap artifact that todo-21's
# pip/npm apply chains never consume, and aka.ms was observed flaky during QA
# (HTTP 503 + connection reset on consecutive runs). The E2E therefore
# publishes only the categories under test; the runtime category is covered by
# todos 10/12/17/20.
function Publish-E2ECategories {
    param(
        [Parameter(Mandatory = $true)][string[]]$Categories,
        [Parameter(Mandatory = $true)][string]$Tag
    )
    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $staging = Join-Path $script:StagingRoot $stamp
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    foreach ($cat in $Categories) {
        switch ($cat) {
            'pip' {
                $rep = Export-OSyncPip -Config $c -StagingDir $staging
                Write-Evidence "  $Tag pip export: status=$($rep.status) ok=$($rep.ok.Count) failed=$($rep.failed.Count)"
                Assert-E2EFatal ($rep.status -eq 'ok') "$Tag pip export ok" "(got '$($rep.status)')"
                Assert-E2EFatal ($rep.failed.Count -eq 0) "$Tag pip export has no failed requirements" "(got $($rep.failed.Count))"
            }
            'npm' {
                # A-side npm warm-up + the verdaccio install hit the real npm
                # registry (todo-11 documented workaround for the operator's
                # no-uplink user npmrc).
                $env:NPM_CONFIG_REGISTRY = 'https://registry.npmjs.org/'
                try {
                    $rep = Export-OSyncNpm -Config $c -StagingDir $staging -ConfigPath $script:ConfigOut
                }
                finally {
                    Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue
                }
                Write-Evidence "  $Tag npm export: warmed=$($rep.warmed.Count) failed=$($rep.failed.Count) tarballs=$($rep.tarballCount) aPort=$($rep.aPort)"
                Assert-E2EFatal ($rep.failed.Count -eq 0) "$Tag npm export has no failed packages" "(got $($rep.failed.Count))"
            }
        }
        $null = New-OSyncFilesManifest -Dir (Join-Path $staging $cat)
    }
    $index = Publish-OSyncIndex -StagingDir $staging
    foreach ($cat in $Categories) {
        $null = Invoke-OSyncRobocopy -Source (Join-Path $staging $cat) -Destination (Join-Path $script:RepoRoot $cat) -ExtraArgs @('/MIR')
    }
    Copy-Item -LiteralPath $index.FullName -Destination (Join-Path $script:RepoRoot 'index.json') -Force
    Write-Evidence "  $Tag published: $($Categories -join ',') + index.json (staging $staging)"
}

function Invoke-E2EMirrorRepo {
    # B-side work copy = a mirror of the validated repo (the orchestrator's
    # 'copy to work copy + verify' step, simplified to the apply-facing parts).
    $null = Invoke-OSyncRobocopy -Source $script:RepoRoot -Destination $script:WorkCopy -ExtraArgs @('/MIR')
    Write-Evidence "  work copy mirrored: $($script:RepoRoot) -> $($script:WorkCopy)"
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:WorkCopy 'pip\requirements.txt') -PathType Leaf) 'work copy has pip requirements.txt'
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:WorkCopy 'npm\verdaccio-b.yml') -PathType Leaf) 'work copy has npm verdaccio-b.yml'
}

function Format-E2EIntegrity {
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

function Assert-E2EIntegrityOk {
    param([Parameter(Mandatory = $true)][string]$Tag)
    $integrity = Test-OSyncRepoIntegrity -RepoRoot $script:RepoRoot
    Write-Evidence "--- integrity after $Tag ---"
    Write-Evidence (Format-E2EIntegrity -R $integrity)
    Assert-E2EFatal ($integrity.Overall -eq 'OK') "integrity Overall = OK after $Tag" "(got '$($integrity.Overall)')"
    $allOk = $true
    foreach ($e in $integrity.Categories.GetEnumerator()) { if ($e.Value.Status -ne 'OK') { $allOk = $false } }
    Assert-E2EFatal $allOk "all integrity categories OK after $Tag"
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
    $LandingRoot = Join-Path $env:TEMP ("osync-e2e-21-" + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss'))
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repo '.omo\evidence\task-21-ab-one-way-sync.log'
}
if ([string]::IsNullOrWhiteSpace($DoneFile)) {
    $DoneFile = Join-Path $env:TEMP 'osync-e2e-21.done'
}

$script:LandingRoot = $LandingRoot
$script:EvidencePath = $EvidencePath
$script:RepoRoot = Join-Path $LandingRoot 'repo'
$script:StagingRoot = Join-Path $LandingRoot 'staging'
$script:StateDir = Join-Path $LandingRoot 'state-b'
$script:WorkCopy = Join-Path $LandingRoot 'workcopy'
$script:ConfigOut = Join-Path $LandingRoot 'config\packagesync.json'
$script:ExportScript = Join-Path $repo 'src\Export-OfflineRepo.ps1'
$script:RunsDir = Join-Path $LandingRoot 'runs'
$venvDir = Join-Path $LandingRoot 'venv'
$script:VenvPy = Join-Path $venvDir 'Scripts\python.exe'
$wrapperPath = Join-Path $LandingRoot 'verdaccio-wrapper.cmd'
$hitDir = Join-Path $LandingRoot 'npm-install-hit'

# RunsDir must exist before the baseline snapshot (Get-E2EFreshNpmRegistry
# redirects a child's output into it).
New-Item -ItemType Directory -Path (Join-Path $LandingRoot 'runs') -Force | Out-Null
$script:RunsDir = (Get-Item -LiteralPath (Join-Path $LandingRoot 'runs')).FullName

# --- baseline snapshot of A's machine npm state (restore target) ---
$npmrcPath = Join-Path $env:ProgramFiles 'nodejs\node_modules\npm\npmrc'
$baselineNpmrcBytes = [System.IO.File]::ReadAllBytes($npmrcPath)
$baselineBakPresent = Test-Path -LiteralPath ($npmrcPath + '.osyncbak') -PathType Leaf
$baselineRegistry = Get-E2EFreshNpmRegistry
$baselineMachineEnv = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')

Write-Evidence "===== todo 21 E2E pip + npm chain start: $([datetime]::UtcNow.ToString('o')) ====="
Write-Evidence "repo root (module source): $repo"
Write-Evidence "landing root: $LandingRoot"
Write-Evidence "evidence: $EvidencePath"
Write-Evidence "elevated: $isAdmin"
Write-Evidence "baseline builtin npmrc: '$npmrcPath' bytes=$($baselineNpmrcBytes.Length) content=[$([System.Text.Encoding]::UTF8.GetString($baselineNpmrcBytes).Replace("`r`n", ' / ').Replace("`n", ' / '))]"
Write-Evidence "baseline .osyncbak present: $baselineBakPresent"
Write-Evidence "baseline fresh 'npm config get registry' = '$baselineRegistry'"
Write-Evidence "baseline machine NPM_CONFIG_REGISTRY = '$baselineMachineEnv'"
Write-Evidence "node: $(& node --version 2>&1 | Out-String) npm: $(& npm --version 2>&1 | Out-String) machinePy exists: $(Test-Path -LiteralPath $script:MachinePy -PathType Leaf)"
Write-Evidence "port 4873 currently free: $(Test-PortFree -Port 4873) (todo-23 may squat it - QA uses a non-4873 port)"
Write-Evidence "production 'PakageSync-Verdaccio' task present (must stay untouched): $($null -ne (Get-ScheduledTask -TaskName 'PakageSync-Verdaccio' -ErrorAction SilentlyContinue))"

$restoreDone = $false
$failed = $false
try {
    # --- dirs ---
    foreach ($d in @('config', 'repo', 'staging', 'state-b', 'workcopy', 'runs', 'venv')) {
        New-Item -ItemType Directory -Path (Join-Path $LandingRoot $d) -Force | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $script:StateDir 'verdaccio') -Force | Out-Null

    # --- normalize to LONG path form (8.3 short-form gotcha, todo-18) ---
    $script:LandingRoot = (Get-Item -LiteralPath $script:LandingRoot).FullName
    $script:RepoRoot = (Get-Item -LiteralPath $script:RepoRoot).FullName
    $script:StagingRoot = (Get-Item -LiteralPath $script:StagingRoot).FullName
    $script:StateDir = (Get-Item -LiteralPath $script:StateDir).FullName
    $script:WorkCopy = (Get-Item -LiteralPath $script:WorkCopy).FullName
    $script:ConfigOut = Join-Path $script:LandingRoot 'config\packagesync.json'
    $script:RunsDir = (Get-Item -LiteralPath $script:RunsDir).FullName
    $venvDir = (Get-Item -LiteralPath $venvDir).FullName
    $script:VenvPy = Join-Path $venvDir 'Scripts\python.exe'
    $wrapperPath = Join-Path $script:LandingRoot 'verdaccio-wrapper.cmd'
    $hitDir = Join-Path $script:LandingRoot 'npm-install-hit'
    Write-Evidence "normalized landing root: $script:LandingRoot"

    # --- tool paths ---
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $nodeCmd) { throw 'node.exe not found on PATH' }
    $script:NodeExe = $nodeCmd.Source
    $script:NpmCmd = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
    if ([string]::IsNullOrWhiteSpace($script:NpmCmd)) {
        $script:NpmCmd = (Get-Command npm.exe -ErrorAction SilentlyContinue).Source
    }
    if ([string]::IsNullOrWhiteSpace($script:NpmCmd)) { throw 'npm.cmd not found on PATH' }
    Write-Evidence "node.exe=$($script:NodeExe) npm.cmd=$($script:NpmCmd)"

    # --- clone + retarget the config (never edits the real config) ---
    $srcConfig = Join-Path $repo 'config\packagesync.json'
    $cfgText = [System.IO.File]::ReadAllText($srcConfig)
    $cfg = $cfgText | ConvertFrom-Json
    $script:QaVerdaccioPort = Get-EFreePort -Start 4896   # NON-4873 (Momus r6-2; todo-23 squats 4873)
    $qaAVerdaccioPort = Get-EFreePort -Start 4910          # one-shot warm-up port must be free
    $qaHttpPort = Get-EFreePort -Start 8792                # unused (no winget category) but non-default
    $cfg.repoRoot = $script:RepoRoot
    $cfg.stagingRoot = $script:StagingRoot
    $cfg.stateDir = $script:StateDir
    $cfg.httpPort = $qaHttpPort
    $cfg.verdaccioPort = $script:QaVerdaccioPort
    $cfg.npm.aVerdaccioPort = $qaAVerdaccioPort
    $newJson = $cfg | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:ConfigOut, $newJson, $script:Utf8Bom)
    $script:QaVerdaccioUrl = "http://127.0.0.1:$($script:QaVerdaccioPort)"
    Write-Evidence "cloned config: $script:ConfigOut"
    Write-Evidence "  repoRoot=$script:RepoRoot stagingRoot=$script:StagingRoot stateDir=$script:StateDir"
    Write-Evidence "  httpPort=$qaHttpPort verdaccioPort=$($script:QaVerdaccioPort) (QA, non-4873) npm.aVerdaccioPort=$qaAVerdaccioPort"

    # --- import the module for integrity/apply checks ---
    Import-Module (Join-Path $repo 'src\OfflineSync.psd1') -Force

    # --- config guards ---
    $c = Get-OSyncConfig -Path $script:ConfigOut
    Assert-E2EFatal ($c.role -eq 'A') 'cloned config role is A' "(got '$($c.role)')"
    Assert-E2EFatal ($c.verdaccioPort -ne 4873) 'cloned config verdaccioPort is NOT 4873' "(got $($c.verdaccioPort))"
    Assert-E2EFatal ($c.repoRoot.StartsWith($script:LandingRoot, [StringComparison]::OrdinalIgnoreCase)) 'cloned config repoRoot lives under the landing dir' "($($c.repoRoot))"
    Assert-E2EFatal (Test-Path -LiteralPath $script:ExportScript -PathType Leaf) 'Export-OfflineRepo.ps1 present'

    # --- place the fixture manifests under the test TOOL root (config.paths.*
    # are tool-root-relative INPUT manifests - never config.repoRoot) ---
    Copy-Item -LiteralPath (Join-Path $repo 'manifests') -Destination (Join-Path $script:LandingRoot 'manifests') -Recurse -Force
    $reqCopy = Join-Path $script:LandingRoot 'manifests\requirements.txt'
    Assert-E2EFatal (Test-Path -LiteralPath $reqCopy -PathType Leaf) 'fixture requirements staged under the test tool root'
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:LandingRoot 'manifests\npm-packages.txt') -PathType Leaf) 'fixture npm list staged under the test tool root'
    Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $script:LandingRoot 'manifests\runtime-winget.txt') -PathType Leaf) 'fixture runtime whitelist staged (npm engines cross-assertion)'

    # =====================================================================
    # PIP CHAIN
    # =====================================================================
    Write-Evidence ""
    Write-Evidence "========== PIP CHAIN =========="

    # Round-1 requirements: six==1.16.0 (older) so the round-2 bump to
    # six==1.17.0 is a genuine NEW version in the upgrade direction.
    $reqRound1 = 'six==1.16.0'
    $reqRound2 = 'six==1.17.0'
    $t0 = Get-Date
    $reqText1 = [System.IO.File]::ReadAllText($reqCopy)
    $newText1 = [regex]::Replace($reqText1, '(?m)^six==\d+\.\d+\.\d+$', $reqRound1)
    if ($newText1 -ceq $reqText1) { throw "requirements edit failed - no 'six==x.y.z' line found in '$reqCopy'." }
    [System.IO.File]::WriteAllText($reqCopy, $newText1, $script:Utf8NoBom)
    Write-Evidence "requirements (round 1): set to $reqRound1"
    Assert-E2E ((Get-Content -LiteralPath $reqCopy -Raw) -match $reqRound1) 'round-1 requirements contains six==1.16.0'

    Write-Evidence ""
    Write-Evidence "=== ROUND 1 EXPORT (pip + npm) -> publish ==="
    $t0 = Get-Date
    Publish-E2ECategories -Categories @('pip', 'npm') -Tag 'round 1'
    $el1 = (Get-Date) - $t0
    Write-Evidence "round 1 export elapsed: $([int]$el1.TotalMinutes) min $($el1.Seconds) s"

    Assert-E2EIntegrityOk -Tag 'round 1 export'
    Invoke-E2EMirrorRepo

    # --- venv sandbox (QA seam: -PythonPath points at the venv, never the
    # machine-wide interpreter) ---
    Write-Evidence ""
    Write-Evidence "=== venv sandbox creation ==="
    $rVenv = Invoke-EPython -PythonPath $script:MachinePy -Arguments @('-m', 'venv', $venvDir)
    Write-Evidence "python -m venv exit: $($rVenv.ExitCode)"
    Assert-E2EFatal ($rVenv.ExitCode -eq 0) 'venv creation exits 0' "(got $($rVenv.ExitCode))"
    Assert-E2EFatal (Test-Path -LiteralPath $script:VenvPy -PathType Leaf) "venv python present at $script:VenvPy"
    Assert-E2EFatal (Test-OSyncPythonInterpreter -PythonPath $script:VenvPy) 'venv python passes the interpreter probe'

    # --- pip apply #1 (fresh install of the round-1 requirements) ---
    Write-Evidence ""
    Write-Evidence "=== PIP APPLY #1 (fresh venv, six==1.16.0) ==="
    $rPip1 = Invoke-OSyncPipApply -WorkDir $script:WorkCopy -Config $c -PythonPath $script:VenvPy
    Write-Evidence "pip apply #1 result: status=$($rPip1.status) python=$($rPip1.pythonPath) packages=$($rPip1.packages)"
    Assert-E2EFatal ($rPip1.status -eq 'ok') 'pip apply #1 status ok' "(got '$($rPip1.status)')"
    $sixV1 = Get-E2EPipPackageVersion -Package 'six'
    Write-Evidence "venv pip list: six = '$sixV1'"
    Assert-E2EFatal ($sixV1 -eq '1.16.0') "pip list shows six 1.16.0 after apply #1" "(got '$sixV1')"
    $state1 = Get-OSyncState -Category 'pip' -Config $c
    $stateSix1 = $state1['pip']['six']
    $stateSixV1 = if ($null -ne $stateSix1) { [string]$stateSix1['version'] } else { $null }
    Write-Evidence "state.pip six version after apply #1: '$stateSixV1'"
    Assert-E2EFatal ($stateSixV1 -eq '1.16.0') 'state.pip records six 1.16.0 after apply #1' "(got '$stateSixV1')"

    # --- requirements bump: a NEW version of one package (the upgrade flow) ---
    Write-Evidence ""
    Write-Evidence "=== REQUIREMENTS BUMP: $reqRound1 -> $reqRound2 (new version) ==="
    $reqText2 = [System.IO.File]::ReadAllText($reqCopy)
    $newText2 = [regex]::Replace($reqText2, '(?m)^six==\d+\.\d+\.\d+$', $reqRound2)
    if ($newText2 -ceq $reqText2) { throw "requirements bump failed - no 'six==x.y.z' line found in '$reqCopy'." }
    [System.IO.File]::WriteAllText($reqCopy, $newText2, $script:Utf8NoBom)
    Assert-E2E ((Get-Content -LiteralPath $reqCopy -Raw) -match $reqRound2) 'round-2 requirements contains six==1.17.0'

    Write-Evidence ""
    Write-Evidence "=== ROUND 2 EXPORT (pip category re-export) -> publish ==="
    $t0 = Get-Date
    Publish-E2ECategories -Categories @('pip') -Tag 'round 2'
    $el2 = (Get-Date) - $t0
    Write-Evidence "round 2 export elapsed: $([int]$el2.TotalMinutes) min $($el2.Seconds) s"

    Assert-E2EIntegrityOk -Tag 'round 2 export'
    Invoke-E2EMirrorRepo

    # --- pip apply #2 (--upgrade; config pip.upgradeOnApply=true) ---
    Write-Evidence ""
    Write-Evidence "=== PIP APPLY #2 (--upgrade, six==1.17.0) ==="
    $rPip2 = Invoke-OSyncPipApply -WorkDir $script:WorkCopy -Config $c -PythonPath $script:VenvPy
    Write-Evidence "pip apply #2 result: status=$($rPip2.status) python=$($rPip2.pythonPath) packages=$($rPip2.packages)"
    Assert-E2EFatal ($rPip2.status -eq 'ok') 'pip apply #2 status ok' "(got '$($rPip2.status)')"

    # Prove the --upgrade flag reached pip: the apply logs its install args
    # (role A config -> <repoRoot>\logs JSONL).
    $logsDir = Join-Path $script:RepoRoot 'logs'
    $jsonl = @(Get-ChildItem -LiteralPath $logsDir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)
    $upgradeSeen = $false
    foreach ($lf in $jsonl) {
        $text = [System.IO.File]::ReadAllText($lf.FullName)
        if ($text -match 'pip install args:.*--upgrade') { $upgradeSeen = $true; break }
    }
    Write-Evidence "JSONL logs show 'pip install args: ... --upgrade': $upgradeSeen"
    Assert-E2EFatal $upgradeSeen '--upgrade flag present in the pip install args log'

    $sixV2 = Get-E2EPipPackageVersion -Package 'six'
    Write-Evidence "venv pip list: six = '$sixV2'"
    Assert-E2EFatal ($sixV2 -eq '1.17.0') "pip list shows six 1.17.0 after apply #2 (upgrade applied)" "(got '$sixV2')"
    $state2 = Get-OSyncState -Category 'pip' -Config $c
    $stateSix2 = $state2['pip']['six']
    $stateSixV2 = if ($null -ne $stateSix2) { [string]$stateSix2['version'] } else { $null }
    Write-Evidence "state.pip six version after apply #2: '$stateSixV2'"
    Assert-E2EFatal ($stateSixV2 -eq '1.17.0') 'state.pip records six 1.17.0 after apply #2' "(got '$stateSixV2')"

    # =====================================================================
    # NPM CHAIN
    # =====================================================================
    Write-Evidence ""
    Write-Evidence "========== NPM CHAIN =========="
    Write-Evidence "QA verdaccio port: $($script:QaVerdaccioPort) (URL $script:QaVerdaccioUrl)"

    # portable Verdaccio comes from the round-1 export's A-side tool dir
    # (<stagingRoot>\.verdaccio-a - installed by Export-OSyncNpm, pinned 6.10.2)
    $verdaccioBin = Join-Path $script:StagingRoot '.verdaccio-a\node_modules\verdaccio\bin\verdaccio'
    Assert-E2EFatal (Test-Path -LiteralPath $verdaccioBin -PathType Leaf) 'portable Verdaccio payload present (.verdaccio-a)' "($verdaccioBin)"
    $bYamlWork = Join-Path $script:WorkCopy 'npm\verdaccio-b.yml'
    $bYamlText = [System.IO.File]::ReadAllText($bYamlWork)
    Assert-E2EFatal (Test-OSyncVerdaccioBYaml -Content $bYamlText) 'verdaccio-b.yml passes the no-uplinks assertion (export contract)'

    # QA scheduled task: the wrapper starts the portable Verdaccio against the
    # apply-refreshed local copy <stateDir>\verdaccio\verdaccio-b.yml.
    $wrapperBody = "@echo off`r`n`"$($script:NodeExe)`" `"$verdaccioBin`" --config `"$($script:StateDir)\verdaccio\verdaccio-b.yml`" >> `"$($script:LandingRoot)\verdaccio-task.out.log`" 2>> `"$($script:LandingRoot)\verdaccio-task.err.log`"`r`n"
    [System.IO.File]::WriteAllText($wrapperPath, $wrapperBody, $script:Utf8NoBom)
    Write-Evidence "QA verdaccio wrapper written: $wrapperPath"

    $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "{0}"' -f $wrapperPath) -WorkingDirectory (Join-Path $script:StateDir 'verdaccio')
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date '2035-01-01T02:00:00')
    # SYSTEM / ServiceAccount - the PRODUCTION shape (Bootstrap.ps1 step 4).
    # Empirically REQUIRED on this machine: with an S4U user principal,
    # `schtasks /End` sets the task State to Ready but does NOT kill the
    # child process tree (verified with ping -t and node verdaccio), so the
    # apply's strict stop->copy->start would fail at the port pre-check.
    # With SYSTEM, /End terminates the tree and releases the port.
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
    try {
        Register-ScheduledTask -TaskName $script:QaTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        $qaTask = Get-ScheduledTask -TaskName $script:QaTaskName
        Write-Evidence "registered $($script:QaTaskName): State=$($qaTask.State) Principal=$($qaTask.Principal.UserId)/$($qaTask.Principal.LogonType)/$($qaTask.Principal.RunLevel)"
        Write-Evidence "  Action: $($qaTask.Actions[0].Execute) $($qaTask.Actions[0].Arguments)  WorkingDirectory=$($qaTask.Actions[0].WorkingDirectory)"
        Assert-E2EFatal ($qaTask.State -eq 'Ready') 'QA verdaccio task registered and Ready'

        # --- npm apply #1 (fresh: task Ready -> /MIR -> /Run -> verify) ---
        Write-Evidence ""
        Write-Evidence "=== NPM APPLY #1 (task Ready -> /MIR -> /Run -> verify) ==="
        $rNpm1 = Invoke-OSyncNpmApply -WorkDir $script:WorkCopy -Config $c -VerdaccioTaskName $script:QaTaskName
        Write-Evidence "npm apply #1: registryOk=$($rNpm1.registryOk) viewSpec=$($rNpm1.viewSpec) npmrcChanged=$($rNpm1.npmrcChanged)"
        Write-Evidence "npm apply #1: ghost=$($rNpm1.ghostName) failed fast in $($rNpm1.ghostElapsedSec) s"
        Write-Evidence "npm apply #1: configGetRegistry=$($rNpm1.configGetRegistry) nodeInstallDir=$($rNpm1.nodeInstallDir) at=$($rNpm1.at)"
        Assert-E2EFatal ($rNpm1.registryOk -eq $true) 'npm apply #1 registryOk' "(got $($rNpm1.registryOk))"
        Assert-E2EFatal ($rNpm1.ghostElapsedSec -lt 30) 'npm apply #1 ghost failed fast (<30 s)' "(got $($rNpm1.ghostElapsedSec) s)"
        Assert-E2EFatal ($rNpm1.configGetRegistry -eq ($script:QaVerdaccioUrl + '/')) 'npm apply #1 new-process registry == local' "(got '$($rNpm1.configGetRegistry)')"
        Assert-E2EFatal ($rNpm1.npmrcChanged -eq $true) 'npm apply #1 modified the builtin npmrc (first time)' "(got $($rNpm1.npmrcChanged))"

        # --- npmrc rewrite + backup assertions ---
        Write-Evidence ""
        Write-Evidence "=== npmrc rewrite + backup assertions ==="
        $preContent = [System.Text.Encoding]::UTF8.GetString($baselineNpmrcBytes)
        $afterContent = [System.IO.File]::ReadAllText($npmrcPath)
        $bakPath = $npmrcPath + '.osyncbak'
        $bakExists = Test-Path -LiteralPath $bakPath -PathType Leaf
        Write-Evidence "npmrc after apply #1: [$($afterContent.Replace("`r`n", ' / ').Replace("`n", ' / '))]"
        Write-Evidence ".osyncbak exists after apply #1: $bakExists"
        $registryLines = @([regex]::Matches($afterContent, '(?im)^registry\s*=.*$') | ForEach-Object { $_.Value })
        Write-Evidence "registry line(s) in npmrc: $($registryLines -join ' | ')"
        Assert-E2EFatal $bakExists '.osyncbak backup created'
        Assert-E2EFatal ($afterContent.Contains("registry=http://127.0.0.1:$($script:QaVerdaccioPort)/")) 'npmrc contains the local registry line' "(port $($script:QaVerdaccioPort))"
        Assert-E2EFatal ($registryLines.Count -eq 1) 'npmrc has exactly ONE registry line' "(got $($registryLines.Count))"
        Assert-E2EFatal ($afterContent.Contains('prefix=${APPDATA}\npm')) 'npmrc preserved the original prefix line'
        if ($bakExists) {
            $bakContent = [System.IO.File]::ReadAllText($bakPath)
            Assert-E2EFatal ($bakContent -ceq $preContent) 'osyncbak content == pre-apply npmrc (the original)' '(byte-compare text)'
        }

        # --- npm apply #2 (task Running -> strict stop->copy->start; idempotent npmrc) ---
        Write-Evidence ""
        Write-Evidence "=== NPM APPLY #2 (task Running -> stop -> /MIR -> /Run; idempotent npmrc) ==="
        $rNpm2 = Invoke-OSyncNpmApply -WorkDir $script:WorkCopy -Config $c -VerdaccioTaskName $script:QaTaskName
        Write-Evidence "npm apply #2: registryOk=$($rNpm2.registryOk) npmrcChanged=$($rNpm2.npmrcChanged) ghost=$($rNpm2.ghostName) in $($rNpm2.ghostElapsedSec) s"
        Write-Evidence "npm apply #2: configGetRegistry=$($rNpm2.configGetRegistry)"
        Assert-E2EFatal ($rNpm2.registryOk -eq $true) 'npm apply #2 registryOk (strict order stop->copy->start)' "(got $($rNpm2.registryOk))"
        Assert-E2EFatal ($rNpm2.ghostElapsedSec -lt 30) 'npm apply #2 ghost failed fast' "(got $($rNpm2.ghostElapsedSec) s)"
        Assert-E2EFatal ($rNpm2.configGetRegistry -eq ($script:QaVerdaccioUrl + '/')) 'npm apply #2 new-process registry == local' "(got '$($rNpm2.configGetRegistry)')"
        Assert-E2EFatal ($rNpm2.npmrcChanged -eq $false) 'npm apply #2 npmrc idempotent (no duplicate line)' "(got $($rNpm2.npmrcChanged))"
        $after2 = [System.IO.File]::ReadAllText($npmrcPath)
        Assert-E2EFatal ($after2 -ceq $afterContent) 'npmrc unchanged by apply #2 (single registry line preserved)'
        if (Test-Path -LiteralPath $bakPath -PathType Leaf) {
            Assert-E2EFatal (([System.IO.File]::ReadAllText($bakPath)) -ceq $preContent) 'osyncbak NOT overwritten by apply #2'
        }

        # --- npm install HIT: no --registry, no --offline; the machine's ONLY
        # registry is the local one (builtin npmrc + machine env) -> proves no
        # external-network dependency (verdaccio-b.yml has no uplinks). ---
        Write-Evidence ""
        Write-Evidence "=== npm install is-odd@3.0.1 (NO --registry, NO --offline) -> local registry only ==="
        $rInst = Invoke-ENpm -Arguments @('install', 'is-odd@3.0.1', '--prefix', $hitDir, '--no-audit', '--no-fund', '--ignore-scripts', '--loglevel', 'error')
        Write-Evidence "npm install exit: $($rInst.ExitCode)"
        Write-Evidence "npm install output: $($rInst.Output.Trim())"
        Assert-E2EFatal ($rInst.ExitCode -eq 0) 'npm install (local registry only) exits 0' "(got $($rInst.ExitCode))"
        $isOddPkg = Join-Path $hitDir 'node_modules\is-odd\package.json'
        Assert-E2EFatal (Test-Path -LiteralPath $isOddPkg -PathType Leaf) 'node_modules\is-odd installed'
        $isOddVer = (Get-Content -LiteralPath $isOddPkg -Raw | ConvertFrom-Json).version
        Write-Evidence "is-odd version installed: $isOddVer"
        Assert-E2EFatal ($isOddVer -eq '3.0.1') 'is-odd@3.0.1 installed (dependency is-number resolved from the snapshot)' "(got '$isOddVer')"
        Assert-E2EFatal (Test-Path -LiteralPath (Join-Path $hitDir 'node_modules\is-number\package.json') -PathType Leaf) 'is-number dependency present (full offline tree)'

        # fresh-process registry (npmrc carrier) + machine env var presence
        $freshReg = Get-E2EFreshNpmRegistry
        Write-Evidence "fresh 'npm config get registry' (new process) = '$freshReg'"
        Assert-E2EFatal ($freshReg -eq ($script:QaVerdaccioUrl + '/')) 'fresh npm config get registry == local (config fallback in effect)' "(got '$freshReg')"
        $machineEnvNow = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')
        Write-Evidence "machine NPM_CONFIG_REGISTRY now = '$machineEnvNow'"
        Assert-E2EFatal ($machineEnvNow -eq ($script:QaVerdaccioUrl + '/')) 'machine NPM_CONFIG_REGISTRY points at the local registry' "(got '$machineEnvNow')"

        # --- direct ghost fast-fail (independent of the apply's own check) ---
        Write-Evidence ""
        Write-Evidence "=== direct npm view of a nonexistent package (fast-fail, no uplink) ==="
        $ghost = 'osync-nonexistent-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rGhost = Invoke-ENpm -Arguments @('view', $ghost, '--registry', $script:QaVerdaccioUrl, '--no-audit', '--no-fund')
        $sw.Stop()
        Write-Evidence "npm view $ghost exit=$($rGhost.ExitCode) elapsed=$([Math]::Round($sw.Elapsed.TotalSeconds, 2)) s"
        Write-Evidence "npm view ghost output tail: $(($rGhost.Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3) -join ' | ')"
        Assert-E2EFatal ($rGhost.ExitCode -ne 0) 'direct ghost npm view fails (non-zero exit)' "(got $($rGhost.ExitCode))"
        Assert-E2EFatal ($sw.Elapsed.TotalSeconds -lt 30) 'direct ghost fast-fails within 30 s (no uplink hang)' "(got $([Math]::Round($sw.Elapsed.TotalSeconds, 2)) s)"

        # =====================================================================
        # FAILURE SCENARIO: occupy the QA verdaccio port -> apply errors naming it
        # =====================================================================
        Write-Evidence ""
        Write-Evidence "=== FAILURE: occupy QA port $($script:QaVerdaccioPort) -> npm apply errors naming the port ==="
        # stop our task's Verdaccio first (task State must be Ready for the
        # apply's pre-check to reach the port-occupied error)
        $null = & schtasks.exe /End /TN $script:QaTaskName 2>&1
        if (-not (Wait-E2EPortFree -Port $script:QaVerdaccioPort -TimeoutSeconds 25)) {
            Stop-E2EListener -Port $script:QaVerdaccioPort
        }
        Write-Evidence "QA verdaccio stopped; port $($script:QaVerdaccioPort) free: $(Test-PortFree -Port $script:QaVerdaccioPort)"

        $script:DummyPid = Start-Process -FilePath $script:MachinePy `
            -ArgumentList @('-m', 'http.server', [string]$script:QaVerdaccioPort, '--bind', '127.0.0.1') `
            -PassThru -WindowStyle Hidden
        Write-Evidence "dummy HTTP 404 responder started on $($script:QaVerdaccioPort) (pid $($script:DummyPid.Id))"
        Assert-E2EFatal (Wait-E2EPortListening -Port $script:QaVerdaccioPort -TimeoutSeconds 15) 'dummy occupies the QA port'

        $caught = $null
        try {
            $rNpm3 = Invoke-OSyncNpmApply -WorkDir $script:WorkCopy -Config $c -VerdaccioTaskName $script:QaTaskName
            Write-Evidence "UNEXPECTED: npm apply #3 succeeded: registryOk=$($rNpm3.registryOk)"
        }
        catch {
            $caught = $_.Exception.Message
            Write-Evidence "npm apply #3 threw as expected: $caught"
        }
        Assert-E2EFatal ($null -ne $caught) 'npm apply with occupied port throws'
        Assert-E2EFatal ($caught -match [regex]::Escape([string]$script:QaVerdaccioPort)) 'the error clearly names the QA port' "($script:QaVerdaccioPort)"

        # npmrc/env must be untouched by the failed run (the pre-check fires
        # before the registry-config step).
        $afterFail = [System.IO.File]::ReadAllText($npmrcPath)
        Assert-E2E ($afterFail -ceq $afterContent) 'npmrc untouched by the failed apply (pre-check fires before config)'

        # release the dummy
        if ($null -ne $script:DummyPid) {
            try { Stop-Process -Id $script:DummyPid.Id -Force -ErrorAction SilentlyContinue } catch { }
            $script:DummyPid = $null
        }
        Stop-E2EListener -Port $script:QaVerdaccioPort
        Assert-E2EFatal (Wait-E2EPortFree -Port $script:QaVerdaccioPort -TimeoutSeconds 20) 'QA port released after failure cleanup'
    }
    finally {
        # QA task ALWAYS unregistered (also on failure)
        if (Get-ScheduledTask -TaskName $script:QaTaskName -ErrorAction SilentlyContinue) {
            $null = & schtasks.exe /End /TN $script:QaTaskName 2>&1
            Start-Sleep -Milliseconds 1500
            Unregister-ScheduledTask -TaskName $script:QaTaskName -Confirm:$false
            Write-Evidence "unregistered $($script:QaTaskName)"
        }
        # belt and braces: kill any straggler the task left on the QA port
        Stop-E2EListener -Port $script:QaVerdaccioPort
        Assert-E2E ($null -eq (Get-ScheduledTask -TaskName $script:QaTaskName -ErrorAction SilentlyContinue)) 'QA verdaccio task unregistered'
    }

    # =====================================================================
    # FINAL FULL-SUITE PESTER (both shells)
    # =====================================================================
    if (-not $SkipPesterFinal) {
        Write-Evidence ""
        Write-Evidence "========== FULL PESTER SUITE (both shells) =========="
        # NOTE: with Start-Process -RedirectStandardOutput, Pester 5.9.1 does
        # NOT emit the 'Tests Passed: X, Failed: Y' console summary into the
        # redirected stdout (only the -PassThru object dump appears). The
        # runner therefore writes a machine-readable result line to a file.
        $ps51Result = Join-Path $script:RunsDir 'pester-ps51.result'
        $pwshResult = Join-Path $script:RunsDir 'pester-pwsh.result'
        $runner51 = Join-Path $script:RunsDir 'run-pester-ps51.ps1'
        $runnerPwsh = Join-Path $script:RunsDir 'run-pester-pwsh.ps1'
        $runnerBody = @"
`$r = Invoke-Pester 'tests\' -PassThru
[System.IO.File]::WriteAllText('__RESULT__', "Passed=`$(`$r.PassedCount) Failed=`$(`$r.FailedCount)`r`n", (New-Object System.Text.UTF8Encoding(`$false)))
"@
        [System.IO.File]::WriteAllText($runner51, $runnerBody.Replace('__RESULT__', $ps51Result), $script:Utf8NoBom)
        [System.IO.File]::WriteAllText($runnerPwsh, $runnerBody.Replace('__RESULT__', $pwshResult), $script:Utf8NoBom)

        $ps51Out = Join-Path $script:RunsDir 'pester-ps51.log'
        $t0 = Get-Date
        $p51 = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner51) `
            -Wait -PassThru -WindowStyle Hidden -WorkingDirectory $repo `
            -RedirectStandardOutput $ps51Out -RedirectStandardError ($ps51Out + '.err')
        $el = (Get-Date) - $t0
        Write-Evidence "powershell.exe 5.1 full suite exit: $($p51.ExitCode) (elapsed $([int]$el.TotalMinutes) min $($el.Seconds) s)"

        $pwshOut = Join-Path $script:RunsDir 'pester-pwsh.log'
        $t0 = Get-Date
        $pw = Start-Process -FilePath 'pwsh.exe' `
            -ArgumentList @('-NoProfile', '-File', $runnerPwsh) `
            -Wait -PassThru -WindowStyle Hidden -WorkingDirectory $repo `
            -RedirectStandardOutput $pwshOut -RedirectStandardError ($pwshOut + '.err')
        $el = (Get-Date) - $t0
        Write-Evidence "pwsh 7 full suite exit: $($pw.ExitCode) (elapsed $([int]$el.TotalMinutes) min $($el.Seconds) s)"

        foreach ($pair in @(@('powershell.exe 5.1', $ps51Result, $p51.ExitCode), @('pwsh 7', $pwshResult, $pw.ExitCode))) {
            $shellName = $pair[0]; $resultPath = $pair[1]; $shellExit = $pair[2]
            Assert-E2E ($shellExit -eq 0) "$shellName full suite process exits 0" "(got $shellExit)"
            if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                Assert-E2E $false "$shellName Pester result file produced"
                continue
            }
            $text = Get-Content -LiteralPath $resultPath -Raw
            $m = [regex]::Match($text, 'Passed=(\d+) Failed=(\d+)')
            if (-not $m.Success) {
                Assert-E2E $false "$shellName Pester result line parseable" "(raw: $text)"
                continue
            }
            $passed = [int]$m.Groups[1].Value
            $failed = [int]$m.Groups[2].Value
            Write-Evidence "$shellName full suite: Tests Passed=$passed Failed=$failed"
            Assert-E2E ($failed -eq 0) "$shellName full Pester suite green (0 failed)" "(pass=$passed fail=$failed)"
            Assert-E2E ($passed -gt 0) "$shellName full suite actually ran tests" "(pass=$passed)"
        }
    }
    else {
        Write-Evidence "SKIP: final full Pester suite (-SkipPesterFinal)"
    }
}
catch {
    $failed = $true
    $err = $_.Exception.Message
    Write-Evidence "E2E FATAL: $err"
    Write-Evidence ($_.ScriptStackTrace)
}
finally {
    # =====================================================================
    # RESTORE A's machine npm state + cleanup (ALWAYS, even on failure)
    # =====================================================================
    Write-Evidence ""
    Write-Evidence "========== CLEANUP / RESTORE =========="

    # 1. stop + delete the QA verdaccio task (idempotent)
    if (Get-ScheduledTask -TaskName $script:QaTaskName -ErrorAction SilentlyContinue) {
        $null = & schtasks.exe /End /TN $script:QaTaskName 2>&1
        Start-Sleep -Milliseconds 1500
        Unregister-ScheduledTask -TaskName $script:QaTaskName -Confirm:$false
        Write-Evidence "QA task $($script:QaTaskName) unregistered"
    }
    # 2. kill any straggler on the QA port (verdaccio / dummy)
    Stop-E2EListener -Port $script:QaVerdaccioPort
    if ($null -ne $script:DummyPid) {
        try { Stop-Process -Id $script:DummyPid.Id -Force -ErrorAction SilentlyContinue } catch { }
        $script:DummyPid = $null
    }

    # 3. restore the builtin npmrc from its pre-run bytes (exact) and remove
    #    the .osyncbak IF we created it (baseline had none)
    try {
        [System.IO.File]::WriteAllBytes($npmrcPath, $baselineNpmrcBytes)
        if (-not $baselineBakPresent -and (Test-Path -LiteralPath ($npmrcPath + '.osyncbak') -PathType Leaf)) {
            Remove-Item -LiteralPath ($npmrcPath + '.osyncbak') -Force -ErrorAction SilentlyContinue
        }
        Write-Evidence "builtin npmrc restored to baseline bytes ($($baselineNpmrcBytes.Length) bytes); .osyncbak handled"
        $restoredText = [System.IO.File]::ReadAllText($npmrcPath)
        $restoredOk = ($restoredText -ceq [System.Text.Encoding]::UTF8.GetString($baselineNpmrcBytes))
        Write-Evidence "npmrc restored content match: $restoredOk  content=[$($restoredText.Replace("`r`n", ' / ').Replace("`n", ' / '))]"
        Assert-E2E $restoredOk 'builtin npmrc byte-restored to the pre-run state'
    }
    catch {
        Write-Evidence "npmrc restore failed: $($_.Exception.Message)"
        Assert-E2E $false 'builtin npmrc byte-restored to the pre-run state'
    }

    # 4. machine env var: restore the baseline value (baseline was empty -> remove)
    try {
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', $baselineMachineEnv, 'Machine')
        $envNow = [Environment]::GetEnvironmentVariable('NPM_CONFIG_REGISTRY', 'Machine')
        Write-Evidence "machine NPM_CONFIG_REGISTRY after restore = '$envNow' (baseline '$baselineMachineEnv')"
        Assert-E2E ($envNow -ceq $baselineMachineEnv) 'machine NPM_CONFIG_REGISTRY restored to baseline'
    }
    catch {
        Write-Evidence "machine env restore failed: $($_.Exception.Message)"
        Assert-E2E $false 'machine NPM_CONFIG_REGISTRY restored to baseline'
    }

    # 5. driver-process env var must be clear
    Remove-Item Env:NPM_CONFIG_REGISTRY -ErrorAction SilentlyContinue

    # 6. fresh-process registry back to baseline
    $finalReg = Get-E2EFreshNpmRegistry
    Write-Evidence "fresh 'npm config get registry' after restore = '$finalReg' (baseline '$baselineRegistry')"
    Assert-E2E ($finalReg -ceq $baselineRegistry) 'fresh npm config get registry == baseline after restore'

    # 7. remove the landing dir (MAX_PATH-safe)
    if (-not $KeepArtifacts) {
        Write-Evidence "self-cleanup: removing landing dir $LandingRoot"
        Remove-E2ETree -Path $LandingRoot
        Write-Evidence "landing dir removed: $(-not (Test-Path -LiteralPath $LandingRoot))"
    }
    else {
        Write-Evidence "KeepArtifacts set - landing dir retained: $LandingRoot"
    }

    $restoreDone = $true
}

# ---------------------------------------------------------------------------
# wrap-up
# ---------------------------------------------------------------------------
$overall = ($script:FailCount -eq 0) -and (-not $failed)
Write-Evidence ""
Write-Evidence "===== E2E RESULT: $(if ($overall) { 'PASS' } else { 'FAIL' }) (pass=$($script:PassCount) fail=$($script:FailCount)) ====="
Write-Evidence "restore completed: $restoreDone"

try {
    [System.IO.File]::WriteAllText($DoneFile, "EXIT=$(if ($overall) { 0 } else { 1 })`r`n", $script:Utf8NoBom)
}
catch { }

exit $(if ($overall) { 0 } else { 1 })
