#Requires -Version 5.1
<#
  Invoke-E2EDotfiles.ps1 - todo 22: dotfiles chain + conflict scenarios (ab-one-way-sync).
  Windows PowerShell 5.1 compatible: no PS7-only syntax. UTF-8 WITH BOM.

  Drives the REAL dotfiles apply chain (Invoke-OSyncDotfilesApply, the same
  lib the B-side user task runs) against a FIXTURE chezmoi source state with
  the -Destination seam redirected to a TEMP directory (never $HOME). All
  state (user store + chezmoi persistent bolt DB) lives under the temp
  landing root - the real C:\ProgramData\PakageSync is never touched.

  SCENARIOS (plan todo 22 + QA scenarios):

    S1 happy chain:
      1. fixture source contains a run_once script -> assert it executes
         EXACTLY ONCE across two applies (marker file line count; the
         idempotency lives in the chezmoi persistent-state bolt DB),
      2. first apply -> `chezmoi status` zero diff (exit 0, empty output),
      3. MODIFY a source file + regenerate files.json -> apply again ->
         the update LANDS in the destination (anti false-green: a
         "everything skipped" bug would leave the old content),
      4. locally modify one target file -> apply again -> the file is
         PRESERVED, the other files still apply, the file is recorded in
         report.skipped and NOT in state.dotfiles.files (retry next round),
      5. template variable rendering: chezmoi.toml [data] name = "e2e-user"
         renders into the destination file ({{ .name }} -> e2e-user).

    S2 all-files-conflicted FIRST run (Oracle M-2): fresh state (no
      baseline), destination pre-populated with content differing from the
      source -> EVERY managed file is locally modified -> the safe set is
      EMPTY -> the chezmoi apply call is NOT made (report.exitCode stays
      $null - the apply branch always sets it from the process) and the
      destination files are byte-identical before/after (zero overwrite).

    S3 broken template error capture: a source template with a syntax error
      -> `chezmoi cat` fails -> the target is recorded in report.failed with
      the template error text, excluded from the apply, NOT materialized in
      the destination, while the healthy target still applies (--keep-going
      semantics).

  CHEZMOI PAYLOAD: the real pinned chezmoi v2.72.0 exe. The script locates a
  cached chezmoi.zip under %TEMP% whose sha256 matches config\packagesync.json
  pins.chezmoi.sha256 (the todo-9/11/16 QA artifacts), else downloads from the
  pinned URL; the zip hash is ALWAYS verified against the pin before
  extraction, and `--version` must report the pinned version.

  FULL REGRESSION: `Invoke-Pester tests\ -PassThru` runs LAST under BOTH
  powershell.exe 5.1 AND pwsh (the plan's "green both shells" requirement);
  the pass/fail markers are parsed and the full output is appended to the
  evidence file.

  TEARDOWN: this E2E touches NOTHING global - no scheduled tasks, no npmrc,
  no machine env vars, no ports, no real landing dirs (the dotfiles apply is
  a pure user-context temp-dir operation). The landing dir is deleted unless
  -KeepArtifacts is set.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\tests\e2e\Invoke-E2EDotfiles.ps1
        [-LandingRoot <dir>] [-EvidencePath <file>] [-DoneFile <file>]
        [-KeepArtifacts] [-SkipPester]
#>

[CmdletBinding()]
param(
    # Isolated test area (fixture work dirs + state + destinations). Defaults
    # to $env:TEMP\osync-e2e-22-<UTC stamp>.
    [string]$LandingRoot,

    # Evidence log path. Defaults to <repo>\.omo\evidence\task-22-ab-one-way-sync.log.
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
$script:ChezmoiExe = ''

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
    # Writes a text file UTF-8 WITHOUT BOM (fixture payload content is ASCII).
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, $script:Utf8NoBom)
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

function Format-DotfilesReport {
    param($R)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("category=$($R.category) status=$($R.status) sourceHash=$($R.sourceHash) dryRun=$($R.dryRun) exitCode=$($R.exitCode) timedOut=$($R.timedOut)")
    $lines.Add("  applied: $($R.applied -join ', ')")
    $lines.Add("  skipped: $($R.skipped -join ', ')")
    foreach ($f in @($R.failed)) { $lines.Add("  failed: $($f.target) -> $($f.error)") }
    $lines.Add("  files recorded: $($R.files.Count)")
    return ($lines -join [Environment]::NewLine)
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
    $work = Join-Path $scen 'work'
    $state = Join-Path $scen 'state'
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $work = (Get-Item -LiteralPath $work).FullName
    return [pscustomobject]@{ Root = $scen; Work = $work; State = $state }
}

function New-E2EConfig {
    # Clones config\packagesync.b.json (role B) and retargets repoRoot/stateDir/
    # stagingRoot to the scenario temp dirs. Returns the validated config object.
    param([Parameter(Mandatory = $true)]$Scenario)
    $cfgDir = Join-Path $Scenario.Root 'config'
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    $cfgPath = Join-Path $cfgDir 'packagesync.json'
    $src = Get-Content -LiteralPath (Join-Path $repo 'config\packagesync.b.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $src.repoRoot = Join-Path $Scenario.Root 'repo'
    $src.stateDir = $Scenario.State
    $src.stagingRoot = Join-Path $Scenario.Root 'staging'
    [System.IO.File]::WriteAllText($cfgPath, ($src | ConvertTo-Json -Depth 10), $script:Utf8Bom)
    $cfg = Get-OSyncConfig -Path $cfgPath
    Assert-E2EFatal ($cfg.role -eq 'B') 'cloned config role is B'
    Assert-E2EFatal (-not ($cfg.repoRoot -eq 'D:\OfflineRepo' -or $cfg.repoRoot -eq 'C:\OfflineRepo')) 'fixture repoRoot never points at a real landing dir' "($($cfg.repoRoot))"
    return $cfg
}

function New-E2EFixtureWorkDir {
    # Builds a fixture work copy: dotfiles\source + dotfiles\chezmoi.toml +
    # dotfiles\files.json (REAL New-OSyncFilesManifest) + runtime\chezmoi\
    # chezmoi.exe (the pinned real exe). Returns the work dir path.
    param(
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][hashtable]$SourceFiles,
        [Parameter(Mandatory = $true)][string]$TomlText
    )
    $src = Join-Path $WorkDir 'dotfiles\source'
    New-Item -ItemType Directory -Path $src -Force | Out-Null
    foreach ($name in $SourceFiles.Keys) {
        Set-E2EText -Path (Join-Path $src $name) -Text $SourceFiles[$name]
    }
    Set-E2EText -Path (Join-Path $WorkDir 'dotfiles\chezmoi.toml') -Text $TomlText
    New-OSyncFilesManifest -Dir (Join-Path $WorkDir 'dotfiles') | Out-Null
    $exeDir = Join-Path $WorkDir 'runtime\chezmoi'
    New-Item -ItemType Directory -Path $exeDir -Force | Out-Null
    Copy-Item -LiteralPath $script:ChezmoiExe -Destination (Join-Path $exeDir 'chezmoi.exe') -Force
    return $src
}

function Invoke-E2EChezmoiStatus {
    # Runs `chezmoi status` with the same common args the apply uses.
    # Returns { ExitCode, Stdout, Stderr }.
    param(
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StateDir
    )
    $common = Get-OSyncChezmoiCommonArgs `
        -SourceDir (Join-Path $WorkDir 'dotfiles\source') `
        -ConfigFile (Join-Path $WorkDir 'dotfiles\chezmoi.toml') `
        -PersistentState (Join-Path (Join-Path $StateDir 'run') 'chezmoistate.boltdb') `
        -Destination $Destination
    return (Invoke-OSyncChezmoiTextCommand -ChezmoiExe $script:ChezmoiExe -Arguments ($common + @('status')))
}

function Resolve-E2EChezmoiExe {
    # Locates the pinned chezmoi.exe: a cached chezmoi.zip under %TEMP% whose
    # sha256 matches config\packagesync.json pins.chezmoi.sha256, else a fresh
    # download from the pinned URL. The zip hash is ALWAYS verified against the
    # pin before extraction; `--version` must report the pinned version.
    $pin = Get-Content -LiteralPath (Join-Path $repo 'config\packagesync.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $url = [string]$pin.pins.chezmoi.url
    $expected = [string]$pin.pins.chezmoi.sha256
    $version = [string]$pin.pins.chezmoi.version
    Assert-E2EFatal ($expected -ne 'PIN-ME') 'chezmoi sha256 pinned in config\packagesync.json' "(got '$expected')"

    # 1. cached zip search (fast): osync-qa* dirs under %TEMP% + WinGet cache
    $zipPath = $null
    $candidates = @()
    foreach ($d in @(Get-ChildItem -Path $env:TEMP -Directory -Filter 'osync-qa*' -ErrorAction SilentlyContinue)) {
        $candidates += @(Get-ChildItem -LiteralPath $d.FullName -Recurse -Filter 'chezmoi*.zip' -File -ErrorAction SilentlyContinue)
    }
    $wg = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\WinGet'
    if (Test-Path -LiteralPath $wg -PathType Container) {
        $candidates += @(Get-ChildItem -LiteralPath $wg -Recurse -Filter 'chezmoi*.zip' -File -ErrorAction SilentlyContinue)
    }
    foreach ($c in $candidates) {
        $h = Get-OSyncFileSha256 -Path $c.FullName
        if ($h -eq $expected) { $zipPath = $c.FullName; break }
    }

    if ($null -eq $zipPath) {
        # 2. fresh download from the pinned URL
        $zipPath = Join-Path $script:LandingRoot 'chezmoi.zip'
        Write-Evidence "no cached chezmoi.zip matched the pin - downloading from $url"
        $null = Invoke-OSyncDownload -Uri $url -OutFile $zipPath
        $h = Get-OSyncFileSha256 -Path $zipPath
        Assert-E2EFatal ($h -eq $expected) 'downloaded chezmoi.zip matches the pinned sha256' "(got '$h')"
    }
    else {
        Write-Evidence "cached chezmoi.zip matched the pin: $zipPath"
    }

    $exeDir = Join-Path $script:LandingRoot 'chezmoi'
    $exe = Expand-OSyncChezmoiZip -ZipPath $zipPath -Destination $exeDir
    $verOut = (& $exe --version 2>&1 | Out-String).Trim()
    Assert-E2EFatal ($LASTEXITCODE -eq 0) 'chezmoi.exe runs' "($verOut)"
    Assert-E2EFatal ($verOut -match [regex]::Escape($version)) "chezmoi.exe reports pinned version $version" "($verOut)"
    Write-Evidence "chezmoi: $verOut"
    return $exe
}

# ---------------------------------------------------------------------------
# scenarios
# ---------------------------------------------------------------------------
function Test-E2EScenarioHappy {
    # S1 happy chain: run_once exactly once + status zero diff + source update
    # lands (anti false-green) + local conflict preserved/skipped + template
    # [data] rendering.
    Write-Evidence ""
    Write-Evidence "===== S1: happy chain (run_once + no-op + source update + local conflict + template) ====="
    $s = Initialize-E2EScenario 's1-happy-chain'

    # --- fixture source state ---
    # dot_ prefix -> target gets a leading dot (.plain.txt); hello.txt.tmpl ->
    # rendered hello.txt; run_once_hello.ps1 -> script target hello.ps1.
    $marker = Join-Path $s.Root 'runonce-marker.txt'
    $src = New-E2EFixtureWorkDir -WorkDir $s.Work -TomlText "[data]`n  name = `"e2e-user`"`n" -SourceFiles @{
        'dot_plain.txt'       = 'plain fixture content v1'
        'hello.txt.tmpl'      = 'Hello {{ .name }} from chezmoi'
        'run_once_hello.ps1'  = ("Add-Content -LiteralPath '{0}' -Value 'ran' -Encoding UTF8" -f $marker)
    }
    $cfg = New-E2EConfig -Scenario $s
    $dest = Join-Path $s.Root 'dest'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $dest = (Get-Item -LiteralPath $dest).FullName
    Write-Evidence "fixture source: dot_plain.txt + hello.txt.tmpl (template) + run_once_hello.ps1; marker=$marker"

    # --- apply 1: initial apply ---
    $r1 = Invoke-OSyncDotfilesApply -WorkDir $s.Work -Config $cfg -Destination $dest
    Write-Evidence "--- apply 1 report ---"
    Write-Evidence (Format-DotfilesReport -R $r1)
    Assert-E2EFatal ($r1.status -eq 'ok') 'S1 apply1 status ok' "(got '$($r1.status)')"
    Assert-E2E ($r1.applied -contains (Join-Path $dest '.plain.txt')) 'S1 apply1 applied .plain.txt'
    Assert-E2E ($r1.applied -contains (Join-Path $dest 'hello.txt')) 'S1 apply1 applied hello.txt (template target)'
    Assert-E2E ($r1.applied -contains (Join-Path $dest 'hello.ps1')) 'S1 apply1 applied run_once script target'

    # byte-identical + template rendering
    $srcPlainHash = Get-OSyncFileSha256 -Path (Join-Path $src 'dot_plain.txt')
    $destPlainHash = Get-OSyncFileSha256 -Path (Join-Path $dest '.plain.txt')
    Assert-E2E ($destPlainHash -eq $srcPlainHash) 'S1 dest .plain.txt byte-identical to source' "($srcPlainHash / $destPlainHash)"
    $helloText = [System.IO.File]::ReadAllText((Join-Path $dest 'hello.txt'))
    Assert-E2E ($helloText -eq 'Hello e2e-user from chezmoi') 'S1 template rendered with [data] name' "($helloText)"

    # run_once executed exactly once
    Assert-E2EFatal (Test-Path -LiteralPath $marker -PathType Leaf) 'S1 run_once marker created (script executed)'
    $markerLines1 = @(Get-Content -LiteralPath $marker).Count
    Assert-E2E ($markerLines1 -eq 1) 'S1 run_once executed exactly once (apply1)' "(lines=$markerLines1)"

    # state recorded
    $st = Get-OSyncState -Category 'dotfiles' -Config $cfg
    Assert-E2E ($null -ne $st.dotfiles.files['.plain.txt']) 'S1 state.files records .plain.txt'
    Assert-E2E ($null -ne $st.dotfiles.files['hello.txt']) 'S1 state.files records hello.txt'

    # --- chezmoi status: zero diff ---
    $status1 = Invoke-E2EChezmoiStatus -WorkDir $s.Work -Destination $dest -StateDir $s.State
    Write-Evidence "--- chezmoi status after apply1 (exit $($status1.ExitCode)) ---"
    Write-Evidence "  [$($status1.Stdout)]"
    Assert-E2EFatal ($status1.ExitCode -eq 0) 'S1 chezmoi status exit 0'
    Assert-E2E ([string]::IsNullOrWhiteSpace($status1.Stdout)) 'S1 chezmoi status zero diff (empty output)'

    # --- apply 2: no-op (source unchanged) ---
    $r2 = Invoke-OSyncDotfilesApply -WorkDir $s.Work -Config $cfg -Destination $dest
    Write-Evidence "--- apply 2 report ---"
    Write-Evidence (Format-DotfilesReport -R $r2)
    Assert-E2EFatal ($r2.status -eq 'skipped') 'S1 apply2 skipped (source hash gate)' "(got '$($r2.status)')"
    $markerLines2 = @(Get-Content -LiteralPath $marker).Count
    Assert-E2E ($markerLines2 -eq 1) 'S1 run_once still exactly once after apply2' "(lines=$markerLines2)"

    # --- modify a source file, apply again (anti false-green) ---
    Set-E2EText -Path (Join-Path $src 'dot_plain.txt') -Text 'plain fixture content v2'
    New-OSyncFilesManifest -Dir (Join-Path $s.Work 'dotfiles') | Out-Null
    Write-Evidence "modified source dot_plain.txt -> v2, files.json regenerated."
    $r3 = Invoke-OSyncDotfilesApply -WorkDir $s.Work -Config $cfg -Destination $dest
    Write-Evidence "--- apply 3 report ---"
    Write-Evidence (Format-DotfilesReport -R $r3)
    Assert-E2EFatal ($r3.status -eq 'ok') 'S1 apply3 status ok (source changed)' "(got '$($r3.status)')"
    $destPlainText = [System.IO.File]::ReadAllText((Join-Path $dest '.plain.txt'))
    Assert-E2E ($destPlainText -eq 'plain fixture content v2') 'S1 source update landed in dest (anti false-green)' "($destPlainText)"
    $markerLines3 = @(Get-Content -LiteralPath $marker).Count
    Assert-E2E ($markerLines3 -eq 1) 'S1 run_once NOT re-run after source change (bolt DB idempotency)' "(lines=$markerLines3)"

    # --- locally modify one target + change the source, apply again ---
    # The source hash gate would skip a round with an UNCHANGED source, so the
    # round carries a source change (v3) too: the locally-modified file must be
    # PRESERVED + recorded in skipped while the other files still apply.
    $helloPath = Join-Path $dest 'hello.txt'
    [System.IO.File]::WriteAllText($helloPath, 'Hello e2e-user from chezmoiLOCAL', $script:Utf8NoBom)
    Set-E2EText -Path (Join-Path $src 'dot_plain.txt') -Text 'plain fixture content v3'
    New-OSyncFilesManifest -Dir (Join-Path $s.Work 'dotfiles') | Out-Null
    Write-Evidence "locally modified dest hello.txt (appended LOCAL) + source dot_plain.txt -> v3, files.json regenerated."
    $r4 = Invoke-OSyncDotfilesApply -WorkDir $s.Work -Config $cfg -Destination $dest
    Write-Evidence "--- apply 4 report ---"
    Write-Evidence (Format-DotfilesReport -R $r4)
    Assert-E2EFatal ($r4.status -eq 'ok') 'S1 apply4 status ok' "(got '$($r4.status)')"
    $helloAfter = [System.IO.File]::ReadAllText($helloPath)
    Assert-E2E ($helloAfter -eq 'Hello e2e-user from chezmoiLOCAL') 'S1 locally modified file PRESERVED (not overwritten)' "($helloAfter)"
    Assert-E2E ($r4.skipped -contains 'hello.txt') 'S1 skipped records hello.txt' "($($r4.skipped -join ','))"
    Assert-E2E ($r4.applied -contains (Join-Path $dest '.plain.txt')) 'S1 other files still applied'
    $destPlainText4 = [System.IO.File]::ReadAllText((Join-Path $dest '.plain.txt'))
    Assert-E2E ($destPlainText4 -eq 'plain fixture content v3') 'S1 source v3 landed alongside the conflict' "($destPlainText4)"
    $st4 = Get-OSyncState -Category 'dotfiles' -Config $cfg
    Assert-E2E ($null -eq $st4.dotfiles.files['hello.txt']) 'S1 skipped file NOT recorded in state.files (retry next round)'

    # --- chezmoi status now surfaces the local modification ---
    $status2 = Invoke-E2EChezmoiStatus -WorkDir $s.Work -Destination $dest -StateDir $s.State
    Write-Evidence "--- chezmoi status after apply4 (exit $($status2.ExitCode)) ---"
    Write-Evidence "  [$($status2.Stdout)]"
    Assert-E2E ($status2.Stdout -match 'hello\.txt') 'S1 chezmoi status surfaces the local modification' "($($status2.Stdout))"

    Write-Evidence "--- S1 logs (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

function Test-E2EScenarioAllConflicted {
    # S2 all-files-conflicted FIRST run (Oracle M-2): fresh state (no
    # baseline), destination pre-populated with DIFFERENT content -> safe set
    # EMPTY -> apply call NOT made (exitCode stays $null), zero overwrite.
    Write-Evidence ""
    Write-Evidence "===== S2: all-files-conflicted FIRST run (safe set empty -> apply NOT called, zero overwrite) ====="
    $s = Initialize-E2EScenario 's2-all-conflicted'
    $null = New-E2EFixtureWorkDir -WorkDir $s.Work -TomlText "[data]`n  name = `"e2e-user`"`n" -SourceFiles @{
        'dot_plain.txt'  = 'plain fixture content v1'
        'hello.txt.tmpl' = 'Hello {{ .name }} from chezmoi'
    }
    $cfg = New-E2EConfig -Scenario $s
    $dest = Join-Path $s.Root 'dest'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $dest = (Get-Item -LiteralPath $dest).FullName

    # pre-populate the destination with DIFFERENT content (first run, no baseline)
    Set-E2EText -Path (Join-Path $dest '.plain.txt') -Text 'LOCAL DIFFERENT CONTENT'
    Set-E2EText -Path (Join-Path $dest 'hello.txt') -Text 'LOCAL DIFFERENT'
    $plainBefore = Get-OSyncFileSha256 -Path (Join-Path $dest '.plain.txt')
    $helloBefore = Get-OSyncFileSha256 -Path (Join-Path $dest 'hello.txt')
    Write-Evidence "pre-populated dest with locally-different files (first run, no baseline)."

    $r = Invoke-OSyncDotfilesApply -WorkDir $s.Work -Config $cfg -Destination $dest
    Write-Evidence "--- S2 apply report ---"
    Write-Evidence (Format-DotfilesReport -R $r)
    Assert-E2EFatal ($r.status -eq 'ok') 'S2 status ok (safe-set-empty branch)' "(got '$($r.status)')"
    Assert-E2E ($r.applied.Count -eq 0) 'S2 applied EMPTY (apply call never made)'
    Assert-E2E ($r.skipped -contains '.plain.txt') 'S2 skipped contains .plain.txt' "($($r.skipped -join ','))"
    Assert-E2E ($r.skipped -contains 'hello.txt') 'S2 skipped contains hello.txt' "($($r.skipped -join ','))"
    Assert-E2E ($null -eq $r.exitCode) 'S2 exitCode null (chezmoi apply NOT invoked)' "(got '$($r.exitCode)')"
    $plainAfter = Get-OSyncFileSha256 -Path (Join-Path $dest '.plain.txt')
    $helloAfter = Get-OSyncFileSha256 -Path (Join-Path $dest 'hello.txt')
    Assert-E2E ($plainAfter -eq $plainBefore) 'S2 dest .plain.txt byte-identical (zero overwrite)' "($plainBefore / $plainAfter)"
    Assert-E2E ($helloAfter -eq $helloBefore) 'S2 dest hello.txt byte-identical (zero overwrite)' "($helloBefore / $helloAfter)"
    $log = Get-E2ELogText -StateDir $s.State
    Assert-E2E ($log -match 'safe set is EMPTY') 'S2 log records the safe-set-empty skip'
    $st = Get-OSyncState -Category 'dotfiles' -Config $cfg
    Assert-E2E ($st.dotfiles.files.Count -eq 0) 'S2 state.files empty (nothing applied)'
    Write-Evidence "--- S2 logs (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

function Test-E2EScenarioBrokenTemplate {
    # S3 broken template error capture: `chezmoi cat` fails on the broken
    # target -> recorded in failed with the template error, excluded from the
    # apply, NOT materialized; the healthy target still applies (keep-going).
    Write-Evidence ""
    Write-Evidence "===== S3: broken template error capture ====="
    $s = Initialize-E2EScenario 's3-broken-template'
    $null = New-E2EFixtureWorkDir -WorkDir $s.Work -TomlText "[data]`n  name = `"e2e-user`"`n" -SourceFiles @{
        'dot_plain.txt'       = 'plain fixture content v1'
        'dot_broken.txt.tmpl' = '{{ if }}'
    }
    $cfg = New-E2EConfig -Scenario $s
    $dest = Join-Path $s.Root 'dest'
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $dest = (Get-Item -LiteralPath $dest).FullName

    $r = Invoke-OSyncDotfilesApply -WorkDir $s.Work -Config $cfg -Destination $dest
    Write-Evidence "--- S3 apply report ---"
    Write-Evidence (Format-DotfilesReport -R $r)
    Assert-E2EFatal ($r.status -eq 'ok') 'S3 status ok (keep-going: other targets applied)' "(got '$($r.status)')"
    $brokenFailed = @($r.failed | Where-Object { $_.target -eq '.broken.txt' })
    Assert-E2E ($brokenFailed.Count -eq 1) 'S3 failed records the broken target' "($(($r.failed | ForEach-Object { $_.target }) -join ','))"
    Assert-E2E ($brokenFailed[0].error -match 'template') 'S3 failed error names the template problem' "($($brokenFailed[0].error))"
    Assert-E2E (-not (Test-Path -LiteralPath (Join-Path $dest '.broken.txt') -PathType Leaf)) 'S3 broken target NOT materialized in dest'
    Assert-E2E (Test-Path -LiteralPath (Join-Path $dest '.plain.txt') -PathType Leaf) 'S3 healthy target still applied'
    $st = Get-OSyncState -Category 'dotfiles' -Config $cfg
    Assert-E2E ($null -ne $st.dotfiles.files['.plain.txt']) 'S3 state.files records the healthy target'
    Assert-E2E ($null -eq $st.dotfiles.files['.broken.txt']) 'S3 state.files does NOT record the broken target'
    Write-Evidence "--- S3 logs (tail) ---"
    foreach ($l in (Get-E2ELogTail -StateDir $s.State)) { Write-Evidence "  $l" }
}

# ---------------------------------------------------------------------------
# full regression (both shells)
# ---------------------------------------------------------------------------
function Invoke-E2EPesterRegression {
    Write-Evidence ""
    Write-Evidence "===== FULL REGRESSION: Invoke-Pester tests\ -PassThru (BOTH shells) ====="
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

    $shells = @(
        @{ Name = 'powershell.exe 5.1'; Exe = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') },
        @{ Name = 'pwsh'; Exe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    )
    foreach ($sh in $shells) {
        if ([string]::IsNullOrWhiteSpace($sh.Exe)) {
            Write-Evidence "SKIP: $($sh.Name) not found"
            continue
        }
        Write-Evidence "--- Pester under $($sh.Name) ---"
        $tag = $sh.Name.Replace(' ', '-').Replace('.', '')
        $out = Join-Path $env:TEMP ("osync-e2e22-pester-$tag.out.log")
        $err = Join-Path $env:TEMP ("osync-e2e22-pester-$tag.err.log")
        $t0 = Get-Date
        $p = Start-Process -FilePath $sh.Exe `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $runner)) `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $out -RedirectStandardError $err
        $el = (Get-Date) - $t0
        Write-Evidence "Pester child exit code: $($p.ExitCode) (elapsed $([int]$el.TotalMinutes) min $($el.Seconds) s)"
        if (Test-Path -LiteralPath $out -PathType Leaf) {
            Write-Evidence "--- Pester full output ($($sh.Name)) ---"
            foreach ($l in @(Get-Content -LiteralPath $out -Encoding UTF8)) { Write-Evidence "  $l" }
        }
        if (Test-Path -LiteralPath $err -PathType Leaf) {
            $errText = Get-Content -LiteralPath $err -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($errText)) {
                Write-Evidence "--- Pester stderr ($($sh.Name)) ---"
                foreach ($l in @($errText -split "`r?`n")) { Write-Evidence "  $l" }
            }
        }
        $outText = if (Test-Path -LiteralPath $out -PathType Leaf) { Get-Content -LiteralPath $out -Raw -Encoding UTF8 } else { '' }
        $passed = 0; $failed = -1; $total = 0
        if ($outText -match 'PESTER_PASSED=(\d+)') { $passed = [int]$Matches[1] }
        if ($outText -match 'PESTER_FAILED=(\d+)') { $failed = [int]$Matches[1] }
        if ($outText -match 'PESTER_TOTAL=(\d+)') { $total = [int]$Matches[1] }
        Assert-E2E ($failed -eq 0) "Pester regression ($($sh.Name)): 0 failed" "(passed=$passed failed=$failed total=$total)"
        Assert-E2E ($total -gt 0) "Pester regression ($($sh.Name)): suite actually ran" "(total=$total)"
        Assert-E2E ($p.ExitCode -eq 0) "Pester regression ($($sh.Name)): child exit 0" "(got $($p.ExitCode))"
        Remove-Item -LiteralPath $out, $err -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $runner -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------
function Invoke-E2ETeardown {
    Write-Evidence ""
    Write-Evidence "===== TEARDOWN ====="
    # This E2E touches NOTHING global: no scheduled tasks, no npmrc, no machine
    # env vars, no ports, no real landing dirs - the dotfiles apply is a pure
    # user-context temp-dir operation (destination + state + bolt DB all under
    # the landing root).
    if (-not $KeepArtifacts) {
        Write-Evidence "self-cleanup: removing landing dir $script:LandingRoot"
        Remove-Item -LiteralPath $script:LandingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Evidence "KeepArtifacts set - landing dir retained: $script:LandingRoot"
    }
}

# ---------------------------------------------------------------------------
# main flow
# ---------------------------------------------------------------------------

# --- detect repo root: <repo>\tests\e2e\<this> -> <repo> ---
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# --- defaults ---
if ([string]::IsNullOrWhiteSpace($LandingRoot)) {
    $LandingRoot = Join-Path $env:TEMP ("osync-e2e-22-" + [datetime]::UtcNow.ToString('yyyyMMddTHHmmss'))
}
if ([string]::IsNullOrWhiteSpace($EvidencePath)) {
    $EvidencePath = Join-Path $repo '.omo\evidence\task-22-ab-one-way-sync.log'
}
if ([string]::IsNullOrWhiteSpace($DoneFile)) {
    $DoneFile = Join-Path $env:TEMP 'osync-e2e-22.done'
}

$script:LandingRoot = $LandingRoot
$script:EvidencePath = $EvidencePath

Write-Evidence "===== todo 22 E2E dotfiles chain + conflict scenarios start: $([datetime]::UtcNow.ToString('o')) ====="
Write-Evidence "repo root (module source): $repo"
Write-Evidence "landing root: $LandingRoot"
Write-Evidence "evidence: $EvidencePath"
Write-Evidence "D:\OfflineRepo exists (must stay untouched): $(Test-Path -LiteralPath 'D:\OfflineRepo')"
Write-Evidence "C:\OfflineRepo exists (must stay untouched): $(Test-Path -LiteralPath 'C:\OfflineRepo')"
Write-Evidence "C:\ProgramData\PakageSync exists (must stay untouched): $(Test-Path -LiteralPath 'C:\ProgramData\PakageSync')"
Write-Evidence "C:\PakageSync exists (must stay untouched): $(Test-Path -LiteralPath 'C:\PakageSync')"

try {
    New-Item -ItemType Directory -Path $script:LandingRoot -Force | Out-Null
    $script:LandingRoot = (Get-Item -LiteralPath $script:LandingRoot).FullName

    # import the module once (read + apply functions, side-effect free)
    Import-Module (Join-Path $repo 'src\OfflineSync.psd1') -Force
    Write-Evidence "module imported: $(Join-Path $repo 'src\OfflineSync.psd1')"

    $script:ChezmoiExe = Resolve-E2EChezmoiExe

    Test-E2EScenarioHappy
    Test-E2EScenarioAllConflicted
    Test-E2EScenarioBrokenTemplate

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