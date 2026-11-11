#Requires -Version 5.1
<#
  ApplyOrchestrator.ps1 - B-side apply orchestration (Invoke-OfflineApply).
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncApply -Config [-Category] [-WhatIf] [-SkipRuntime]
      Runs ONE B-side apply round. All the orchestration logic of plan
      todo 17 lives here; the entry script src\Invoke-OfflineApply.ps1 only
      acquires the apply.lock (the lock is taken ONLY by the entry scripts -
      todo 12 and todo 17 - never by lib flows, Momus r7-m3), calls this
      function and maps the result to an exit code.

  Mode selection (documented rule, Momus r5-m2):
      The apply semantics depend on WHO runs the round. The two scheduled
      tasks pin their -Category so the mode is derived from it:
        -Category contains ONLY 'dotfiles'  -> 'dotfiles' (USER context)
        anything else (incl. empty)         -> 'packages' (SYSTEM context)
      packages mode: bootstrap self-heal trigger, whole-repo snapshot work
      copy creation, applies winget/pip/npm (NEVER dotfiles - a SYSTEM-context
      dotfiles apply would hit the wrong user profile), self-refresh of the
      tool copy and work\ cleanup.
      dotfiles mode: never creates work copies (Users are read-only on
      work\, Momus M2), only consumes the newest .verified generation,
      applies dotfiles from it, never bootstraps/refreshes/cleans.

  Round flow (packages mode):
      [1] Trust root: Test-OSyncRepoIntegrity. Index invalid / unparseable ->
          whole round skipped (Metis B2). exportedAtUtc is the generation id.
      [2] Bootstrap self-heal: when state.bootstrapped != true (needs the
          runtime payload - chezmoi.exe/tools - Momus r4-M2) OR the runtime
          content hashes (runtimeWingetHash / runtimeFilesHash) drifted vs
          system-state (runtime version upgrades, Oracle r5-m1) -> run
          Invoke-OSyncBootstrap (idempotent upgrade path). -SkipRuntime
          suppresses ONLY the drift half of that trigger: the drifted
          runtime payload is not reinstalled and the round applies normally
          (Warning logged). A never-bootstrapped machine always bootstraps
          regardless of -SkipRuntime (no Python/Node/Verdaccio -> it could
          not apply anything). A failed bootstrap skips the whole round
          (retry next cycle). The SYSTEM auto path is a safety net only -
          QA does not cover the full chain (Momus m4). dotfiles mode:
          unbootstrapped -> skip + log (Oracle m11).
      [3] Content-aware work copy: each enabled category independently resolves
          its lastApplied verified baseline. Content-equivalent categories are
          skip; winget with a usable changed baseline is delta; other pending
          categories are full. Only pending categories + runtime enter
          <stateDir>\work\<exportedAtUtc>\ (runtime Incomplete -> whole round
          skipped). winget delta hard-links unchanged baseline files with copy
          fallbacks. RE-HASH every delivered file; verification failure deletes
          the generation. Write .verified only after the complete work copy
          passes, then apply the requested pending categories.
      [4] Per-category apply: success -> state.lastApplied.<cat> =
          exportedAtUtc; failure -> lastApplied untouched (retry next round);
          one category's failure never blocks the others (Metis m1). skip never
          advances lastApplied to a generation that does not contain that cat.
      [5] At orchestration end (regardless of per-category outcome; packages
          task only): self-refresh the tool copy (re-verify C:\PakageSync
          owner/ACL first - abnormal -> abandon + alert, Momus r7-MAJOR-1;
          /MIR /XD config to .new, delete old .old, rename current -> .old,
          .new -> current - exact order, Oracle m9; refresh failure logged
          only + retried next cycle, Oracle m5; next cycle takes effect,
          Momus B1) and clean <stateDir>\work\ (incl. work\bootstrap\
          subtree, keeping the newest 2 plus every verified lastApplied
          baseline referenced by system/user state).
      Refresh source: the VERIFIED generation built this round (never
      unverified/partially-synced repo content lands into the live tool
      copy). When the round built no generation (nothing pending), refresh
      is skipped - tool-only changes are covered by the bootstrap drift
      path (runtime\files.json includes runtime\tool\).
      -WhatIf (Metis m3): read-only index + state; per-category "would
      install/update" report; no services, no copies, no file changes, no
      self-refresh, no cleanup. The log dir is created as an operational
      artifact (same convention as the bootstrap, todo-12 learning).

  Round flow (dotfiles mode):
      [1] Trust root: index must parse (whole round skipped otherwise).
      [2] Unbootstrapped -> skip dotfiles + log (Oracle m11).
      [3] The shared category planner returns skip for an already-applied or
          content-equivalent dotfiles baseline; skip never advances state.
      [4] Newest .verified generation: none, older than the current index, or
          lacking pending dotfiles -> skip and wait for the packages task.
      [5] Invoke-OSyncDotfilesApply -WorkDir <gen>; ok/skipped -> stamp
          lastApplied.dotfiles = exportedAtUtc; failed -> lastApplied untouched.

  The result object shape (the entry script maps it to an exit code):
      { mode, whatIf, outcome ('skipped'|'ok'|'failed'), skipReason, error,
        exportedAtUtc, bootstrapped, bootstrapRan, pendingCategories, copyPlans,
        generation, verified, categories{cat -> {status,message,lastApplied}},
        copyPlanPath, refreshed, refreshSkippedReason, cleaned }

  Must NOT: take the apply.lock (entry scripts only); apply/refresh from the
  <repoRoot> sync dir directly (always the verified work copy); let dotfiles
  mode create work copies or write into work\.
#>

# ---- internal constants -----------------------------------------------------

# Valid apply categories, in canonical apply order for packages mode.
$script:OApplyCategories = @('winget', 'pip', 'npm', 'dotfiles')

# JSON reader probe: identical strategy to State.ps1 / RepoContract.ps1
# (JavaScriptSerializer on PS 5.1 dodges the ~2 MB ConvertFrom-Json cap;
# pwsh 7 falls back to ConvertFrom-Json).
$script:OApplyJsonParser = 'ConvertFromJson'
$script:OApplyJsonSerializer = $null
try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $probe = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $probe.MaxJsonLength = [int]::MaxValue
    $null = $probe.DeserializeObject('{}')
    $script:OApplyJsonParser = 'JavaScriptSerializer'
    $script:OApplyJsonSerializer = $probe
}
catch {
    $script:OApplyJsonParser = 'ConvertFromJson'
}

# ---- internal helpers -------------------------------------------------------

function ConvertFrom-OApplyJson {
    # Parse JSON text (same availability probe as State.ps1 / Bootstrap.ps1).
    # Throws on invalid JSON. Both branches yield IDictionary-compatible trees.
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($script:OApplyJsonParser -eq 'JavaScriptSerializer') {
        return $script:OApplyJsonSerializer.DeserializeObject($Text)
    }
    return ($Text | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop)
}

function New-OApplyCategoryResult {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $false)][string]$Message = '',
        [Parameter(Mandatory = $false)][AllowNull()]$LastApplied = $null
    )
    return [pscustomobject]@{
        category    = $Category
        status      = $Status
        message     = $Message
        lastApplied = $LastApplied
    }
}

function Get-OApplyIndexExportedAtUtc {
    # Reads exportedAtUtc out of an already-parsed index object, or $null.
    param([Parameter(Mandatory = $true)]$Index)
    if ($null -eq $Index -or -not ($Index -is [System.Collections.IDictionary])) { return $null }
    if (-not $Index.ContainsKey('exportedAtUtc')) { return $null }
    $v = [string]$Index['exportedAtUtc']
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return $v
}

# ---- public API -------------------------------------------------------------

function Get-OSyncApplyMode {
    <#
      Derives the apply mode from the requested -Category list (documented
      rule above). Throws on an unknown category name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)][string[]]$Category = @()
    )
    $cats = @($Category | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ -ne '' })
    foreach ($c in $cats) {
        if ($script:OApplyCategories -notcontains $c) {
            throw "Invoke-OfflineApply: unknown category '$c' (expected one of: $($script:OApplyCategories -join ', '))."
        }
    }
    $dotfilesOnly = ($cats.Count -gt 0) -and (($cats | Where-Object { $_ -ne 'dotfiles' }).Count -eq 0)
    if ($dotfilesOnly) { return 'dotfiles' }
    return 'packages'
}

function Get-OSyncApplyEnabledCategories {
    <#
      The categories enabled in the config. Uses dynamic property access
      (PSCustomObject ['name'] indexing is not reliable across shells).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)]$Config)
    $enabled = @()
    foreach ($cat in $script:OApplyCategories) {
        $prop = $Config.categories.PSObject.Properties[$cat]
        if ($null -ne $prop -and $true -eq [bool]$prop.Value) { $enabled += $cat }
    }
    return $enabled
}

function Test-OSyncRuntimeDrift {
    <#
      True when the current runtime payload (runtime-winget.txt and the
      runtime files.json) differs from the hashes recorded at bootstrap time
      (state.runtimeWingetHash / runtimeFilesHash). A drift means the runtime
      toolchain changed (Verdaccio/chezmoi/tool version upgrades) and the
      packages task must re-run the bootstrap ③④ upgrade path (Oracle r5-m1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][AllowNull()]$State
    )
    $drift = $false
    $runtimeTxt = Join-Path $RepoRoot 'runtime\runtime-winget.txt'
    if (Test-Path -LiteralPath $runtimeTxt -PathType Leaf) {
        if ([string]$State.runtimeWingetHash -ne (Get-OSyncFileSha256 -Path $runtimeTxt)) { $drift = $true }
    }
    $runtimeFiles = Join-Path $RepoRoot 'runtime\files.json'
    if (Test-Path -LiteralPath $runtimeFiles -PathType Leaf) {
        if ([string]$State.runtimeFilesHash -ne (Get-OSyncFileSha256 -Path $runtimeFiles)) { $drift = $true }
    }
    return $drift
}

function New-OApplyTransferStats {
    return [pscustomobject]@{
        copiedFiles         = 0
        copiedBytes         = [int64]0
        reusedFiles         = 0
        reusedBytes         = [int64]0
        deletedFiles        = 0
        deletedBytes        = [int64]0
        repoCopiedFiles     = 0
        repoCopiedBytes     = [int64]0
        hardLinkedFiles     = 0
        hardLinkedBytes     = [int64]0
        baselineCopiedFiles = 0
        baselineCopiedBytes = [int64]0
    }
}

function Get-OSyncApplyCategoryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('winget', 'pip', 'npm', 'dotfiles')][string]$Category,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Integrity,
        [Parameter(Mandatory = $true)][string]$ExportedAtUtc,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $plan = [pscustomobject]@{
        category          = $Category
        mode              = 'full'
        baseExportedAtUtc = $null
        baseDir           = $null
        fallbackReason    = $null
        currentManifest   = $null
        baselineManifest  = $null
        stats             = New-OApplyTransferStats
    }
    $state = Get-OSyncState -Category $Category -Config $Config
    $last = $state.lastApplied[$Category]
    if (-not (Test-OSyncCategoryNewer -Category $Category -ExportedAtUtc $ExportedAtUtc -Config $Config)) {
        $plan.mode = 'skip'
        $plan.fallbackReason = 'already applied'
        $plan.baseExportedAtUtc = $last
        return $plan
    }
    if ($null -eq $last -or [string]::IsNullOrWhiteSpace([string]$last)) {
        $plan.fallbackReason = 'no lastApplied baseline'
        return $plan
    }
    $plan.baseExportedAtUtc = [string]$last
    if ([string]$last -notmatch '^\d{8}T\d{6}Z$') {
        $plan.fallbackReason = 'lastApplied baseline has an invalid generation id'
        return $plan
    }
    $baseDir = Join-Path (Join-Path ([string]$Config.stateDir) 'work') ([string]$last)
    $plan.baseDir = $baseDir
    if (-not (Test-Path -LiteralPath $baseDir -PathType Container)) {
        $plan.fallbackReason = 'lastApplied work directory is missing'
        return $plan
    }
    if (-not (Test-Path -LiteralPath (Join-Path $baseDir '.verified') -PathType Leaf)) {
        $plan.fallbackReason = 'lastApplied work directory is not verified'
        return $plan
    }
    $baselineFiles = Join-Path (Join-Path $baseDir $Category) 'files.json'
    if (-not (Test-Path -LiteralPath $baselineFiles -PathType Leaf)) {
        $plan.fallbackReason = 'baseline files.json is missing'
        return $plan
    }
    try {
        $baselineManifest = ConvertFrom-OApplyJson -Text ([System.IO.File]::ReadAllText($baselineFiles))
        if ($null -eq $baselineManifest -or $baselineManifest -isnot [System.Collections.IDictionary]) {
            throw 'baseline files.json is not a JSON object'
        }
        $plan.baselineManifest = $baselineManifest
    }
    catch {
        $plan.fallbackReason = "baseline files.json is unreadable: $($_.Exception.Message)"
        return $plan
    }

    $currentRecord = $Integrity.Categories[$Category]
    $currentManifestPath = Join-Path (Join-Path $RepoRoot $Category) 'files.json'
    try {
        $currentManifest = ConvertFrom-OApplyJson -Text ([System.IO.File]::ReadAllText($currentManifestPath))
        if ($null -eq $currentManifest -or $currentManifest -isnot [System.Collections.IDictionary]) {
            throw 'current files.json is not a JSON object'
        }
        $plan.currentManifest = $currentManifest
    }
    catch {
        $plan.fallbackReason = "current files.json is unreadable: $($_.Exception.Message)"
        return $plan
    }
    if ((Get-OSyncFileSha256 -Path $baselineFiles) -eq [string]$currentRecord.ExpectedSha256) {
        $plan.mode = 'skip'
        $plan.fallbackReason = 'content equivalent to the verified baseline'
        return $plan
    }
    if ($Category -eq 'winget') { $plan.mode = 'delta' }
    return $plan
}

function Get-OApplyPlanReport {
    param([Parameter(Mandatory = $true)]$Plan)
    return [pscustomobject]@{
        category          = $Plan.category
        mode              = $Plan.mode
        baseExportedAtUtc = $Plan.baseExportedAtUtc
        fallbackReason    = $Plan.fallbackReason
        stats             = $Plan.stats
    }
}

function New-OSyncWingetDeltaWorkCopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$BaseDir,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)]$CurrentManifest,
        [Parameter(Mandatory = $true)]$BaselineManifest
    )

    $stats = New-OApplyTransferStats
    $sourceDir = Join-Path $RepoRoot 'winget'
    $baselineDir = Join-Path $BaseDir 'winget'
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($entry in $CurrentManifest.GetEnumerator()) {
        $rel = [string]$entry.Key
        $meta = $entry.Value
        $bytes = [int64]$meta['bytes']
        $sha = [string]$meta['sha256']
        $target = Join-Path $Destination ($rel.Replace('/', '\'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        $unchanged = $BaselineManifest.ContainsKey($rel)
        if ($unchanged) {
            $old = $BaselineManifest[$rel]
            $unchanged = ($old -is [System.Collections.IDictionary]) -and
                ([int64]$old['bytes'] -eq $bytes) -and
                ([string]::Equals([string]$old['sha256'], $sha, [System.StringComparison]::OrdinalIgnoreCase))
        }
        if (-not $unchanged) {
            Copy-Item -LiteralPath (Join-Path $sourceDir ($rel.Replace('/', '\'))) -Destination $target -Force -ErrorAction Stop
            $stats.copiedFiles++
            $stats.copiedBytes += $bytes
            $stats.repoCopiedFiles++
            $stats.repoCopiedBytes += $bytes
            continue
        }

        $baselineFile = Join-Path $baselineDir ($rel.Replace('/', '\'))
        $linked = $false
        if (Test-Path -LiteralPath $baselineFile -PathType Leaf) {
            try {
                New-Item -ItemType HardLink -Path $target -Target $baselineFile -Force -ErrorAction Stop | Out-Null
                $linked = $true
                $stats.hardLinkedFiles++
                $stats.hardLinkedBytes += $bytes
            }
            catch {
                $linked = $false
            }
        }
        if (-not $linked) {
            if (Test-Path -LiteralPath $baselineFile -PathType Leaf) {
                Copy-Item -LiteralPath $baselineFile -Destination $target -Force -ErrorAction Stop
                $stats.baselineCopiedFiles++
                $stats.baselineCopiedBytes += $bytes
            }
            else {
                Copy-Item -LiteralPath (Join-Path $sourceDir ($rel.Replace('/', '\'))) -Destination $target -Force -ErrorAction Stop
                $stats.copiedFiles++
                $stats.copiedBytes += $bytes
                $stats.repoCopiedFiles++
                $stats.repoCopiedBytes += $bytes
                continue
            }
        }
        $stats.reusedFiles++
        $stats.reusedBytes += $bytes
    }
    foreach ($entry in $BaselineManifest.GetEnumerator()) {
        $rel = [string]$entry.Key
        if (-not $CurrentManifest.ContainsKey($rel)) {
            $stats.deletedFiles++
            $stats.deletedBytes += [int64]$entry.Value['bytes']
        }
    }
    $currentFiles = Join-Path $sourceDir 'files.json'
    Copy-Item -LiteralPath $currentFiles -Destination (Join-Path $Destination 'files.json') -Force -ErrorAction Stop
    $controlBytes = (Get-Item -LiteralPath $currentFiles -Force).Length
    $stats.copiedFiles++
    $stats.copiedBytes += $controlBytes
    $stats.repoCopiedFiles++
    $stats.repoCopiedBytes += $controlBytes
    return $stats
}

function New-OSyncApplyGeneration {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ExportedAtUtc,
        [Parameter(Mandatory = $true)][string[]]$OkCategories,
        [Parameter(Mandatory = $false)]$Plans = $null
    )
    $workRoot = Join-Path ([string]$Config.stateDir) 'work'
    if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $workRoot -Force | Out-Null
    }
    $gen = Join-Path $workRoot $ExportedAtUtc
    if (Test-Path -LiteralPath $gen -PathType Container) {
        Remove-Item -LiteralPath $gen -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path $gen -Force | Out-Null
    $categories = @($OkCategories)
    if ($null -ne $Plans) {
        $categories = @($script:OApplyCategories | Where-Object { $Plans.Contains($_) -and $Plans[$_].mode -in @('full', 'delta') })
    }
    $reportPlans = [ordered]@{}
    foreach ($cat in (@('runtime') + $categories)) {
        $src = Join-Path $RepoRoot $cat
        if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
        $destination = Join-Path $gen $cat
        $plan = $null
        if ($cat -ne 'runtime' -and $null -ne $Plans) { $plan = $Plans[$cat] }
        if ($null -ne $plan -and $plan.mode -eq 'delta') {
            $plan.stats = New-OSyncWingetDeltaWorkCopy -RepoRoot $RepoRoot -BaseDir $plan.baseDir -Destination $destination -CurrentManifest $plan.currentManifest -BaselineManifest $plan.baselineManifest
        }
        else {
            Invoke-OSyncRobocopy -Source $src -Destination $destination -ExtraArgs @('/E') | Out-Null
            if ($null -ne $Plans) {
                $stats = New-OApplyTransferStats
                $filesJson = Join-Path $src 'files.json'
                $manifest = ConvertFrom-OApplyJson -Text ([System.IO.File]::ReadAllText($filesJson))
                foreach ($entry in $manifest.GetEnumerator()) {
                    $stats.copiedFiles++
                    $stats.copiedBytes += [int64]$entry.Value['bytes']
                    $stats.repoCopiedFiles++
                    $stats.repoCopiedBytes += [int64]$entry.Value['bytes']
                }
                $controlBytes = (Get-Item -LiteralPath $filesJson -Force).Length
                $stats.copiedFiles++
                $stats.copiedBytes += $controlBytes
                $stats.repoCopiedFiles++
                $stats.repoCopiedBytes += $controlBytes
                if ($null -ne $plan) { $plan.stats = $stats }
            }
        }
        if ($null -ne $plan) { $reportPlans[$cat] = Get-OApplyPlanReport -Plan $plan }
    }
    if ($null -ne $Plans) {
        $runtimePlan = [pscustomobject]@{
            category = 'runtime'; mode = 'full'; baseExportedAtUtc = $null
            fallbackReason = 'runtime is always delivered in a packages work copy'
            stats = New-OApplyTransferStats
        }
        $runtimeFiles = Join-Path $gen 'runtime\files.json'
        if (Test-Path -LiteralPath $runtimeFiles -PathType Leaf) {
            $runtimeManifest = ConvertFrom-OApplyJson -Text ([System.IO.File]::ReadAllText($runtimeFiles))
            foreach ($entry in $runtimeManifest.GetEnumerator()) {
                $runtimePlan.stats.copiedFiles++
                $runtimePlan.stats.copiedBytes += [int64]$entry.Value['bytes']
                $runtimePlan.stats.repoCopiedFiles++
                $runtimePlan.stats.repoCopiedBytes += [int64]$entry.Value['bytes']
            }
            $runtimeBytes = (Get-Item -LiteralPath $runtimeFiles -Force).Length
            $runtimePlan.stats.copiedFiles++
            $runtimePlan.stats.copiedBytes += $runtimeBytes
            $runtimePlan.stats.repoCopiedFiles++
            $runtimePlan.stats.repoCopiedBytes += $runtimeBytes
        }
        $reportPlans['runtime'] = $runtimePlan
        $copyPlanPath = Join-Path $gen 'copy-plan.json'
        [System.IO.File]::WriteAllText($copyPlanPath, (ConvertTo-OSyncJson -InputObject $reportPlans), (New-Object System.Text.UTF8Encoding($true)))
    }
    return $gen
}

function Test-OSyncApplyWorkCopy {
    <#
      RE-VERIFIES a work copy generation: every category dir present is
      checked against its own files.json - each listed file's byte count and
      sha256 are recomputed (the same trust semantics as the bootstrap work
      copy, Momus M3/Oracle M4). Throws with the list of mismatches; the
      caller then DELETES the generation - a bad generation must never be
      kept as the newest (Momus r4-B1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Bw)
    $bad = @()
    # runtime is copied into EVERY generation (New-OSyncApplyGeneration) and
    # carries chezmoi.exe / the tool payload - it must be re-verified too, or
    # the .verified marker misrepresents the verification scope (F2).
    foreach ($cat in (@('runtime') + $script:OApplyCategories)) {
        $catDir = Join-Path $Bw $cat
        if (-not (Test-Path -LiteralPath $catDir -PathType Container)) { continue }
        $filesJson = Join-Path $catDir 'files.json'
        if (-not (Test-Path -LiteralPath $filesJson -PathType Leaf)) {
            $bad += "${cat}: files.json missing in the work copy"
            continue
        }
        $manifest = $null
        try {
            $manifest = ConvertFrom-OApplyJson -Text ([System.IO.File]::ReadAllText($filesJson))
        }
        catch {
            $bad += "${cat}: files.json not parseable"
            continue
        }
        if ($null -eq $manifest -or -not ($manifest -is [System.Collections.IDictionary])) {
            $bad += "${cat}: files.json not a JSON object"
            continue
        }
        foreach ($entry in $manifest.GetEnumerator()) {
            $rel = [string]$entry.Key
            $meta = $entry.Value
            if ($meta -isnot [System.Collections.IDictionary]) { $bad += "${cat}/${rel}: malformed manifest entry"; continue }
            $filePath = Join-Path $catDir $rel
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { $bad += "${cat}/${rel}: missing"; continue }
            if ($meta.ContainsKey('bytes')) {
                try {
                    if ((Get-Item -LiteralPath $filePath -Force).Length -ne [int64]$meta['bytes']) { $bad += "${cat}/${rel}: byte-count mismatch"; continue }
                }
                catch { $bad += "${cat}/${rel}: unreadable"; continue }
            }
            if ($meta.ContainsKey('sha256')) {
                $expected = [string]$meta['sha256']
                if ((Get-OSyncFileSha256 -Path $filePath) -ne $expected) { $bad += "${cat}/${rel}: sha256 mismatch" }
            }
        }
    }
    if ($bad.Count -gt 0) {
        throw ("ApplyOrchestrator.ps1: work copy re-verification FAILED for {0} file(s): {1}" -f $bad.Count, ($bad -join '; '))
    }
    return $true
}

function Write-OSyncApplyVerifiedMarker {
    # Writes the <ts>\.verified marker: the generation passed the re-hash
    # re-verification and may be consumed by the dotfiles (user) task.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Bw,
        [Parameter(Mandatory = $true)][string]$ExportedAtUtc
    )
    $marker = Join-Path $Bw '.verified'
    $content = 'VERIFIED exportedAtUtc={0} PID={1} TIMESTAMP={2}' -f $ExportedAtUtc, $PID, [DateTime]::UtcNow.ToString('o')
    [System.IO.File]::WriteAllText($marker, $content, (New-Object System.Text.UTF8Encoding($false)))
    return $marker
}

function Get-OSyncApplyNewestVerifiedGeneration {
    <#
      The newest <work>\<ts>\ directory carrying a .verified marker, or
      $null. The dotfiles (user) task consumes exactly this one (Momus M2).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir)
    $workRoot = Join-Path $StateDir 'work'
    if (-not (Test-Path -LiteralPath $workRoot -PathType Container)) { return $null }
    $gens = @(Get-ChildItem -LiteralPath $workRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' -and (Test-Path -LiteralPath (Join-Path $_.FullName '.verified') -PathType Leaf) })
    if ($gens.Count -eq 0) { return $null }
    # Fixed-width zero-padded basic format -> ordinal string comparison is
    # chronological (same rationale as index exportedAtUtc).
    $newest = $gens | Sort-Object { [string]$_.Name } -Descending | Select-Object -First 1
    return [pscustomobject]@{ Ts = $newest.Name; Path = $newest.FullName }
}

function Invoke-OSyncApplyWorkCleanup {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter(Mandatory = $false)][int]$Keep = 2
    )
    $workRoot = Join-Path $StateDir 'work'
    $protected = @{}
    foreach ($statePath in @((Join-Path $StateDir 'state\system-state.json'), (Join-Path $StateDir 'run\user-state.json'))) {
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
        try {
            $state = ConvertFrom-OApplyJson -Text ([System.IO.File]::ReadAllText($statePath))
            if ($null -eq $state['lastApplied'] -or $state['lastApplied'] -isnot [System.Collections.IDictionary]) { continue }
            foreach ($entry in $state['lastApplied'].GetEnumerator()) {
                $ts = [string]$entry.Value
                if ($ts -notmatch '^\d{8}T\d{6}Z$') { continue }
                $marker = Join-Path (Join-Path $workRoot $ts) '.verified'
                if (Test-Path -LiteralPath $marker -PathType Leaf) { $protected[$ts] = $true }
            }
        }
        catch {
            continue
        }
    }
    $removed = 0
    foreach ($root in @($workRoot, (Join-Path $workRoot 'bootstrap'))) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $gens = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' } |
            Sort-Object { [string]$_.Name } -Descending)
        for ($i = $Keep; $i -lt $gens.Count; $i++) {
            if ($root -eq $workRoot -and $protected.ContainsKey($gens[$i].Name)) { continue }
            Remove-Item -LiteralPath $gens[$i].FullName -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
    return $removed
}

function Test-OSyncLandingReadyForRefresh {
    <#
      Re-verifies the tool landing before a self-refresh (Momus r7-MAJOR-1):
      the landing must exist, be owned by SYSTEM/Administrators (anti-poisoning)
      and carry the SYSTEM + Users ACEs from the bootstrap hardening. An
      abnormal landing abandons the refresh (the caller alerts + skips).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$LandingRoot)
    $LandingRoot = $LandingRoot.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $LandingRoot -PathType Container)) { return $false }
    if (-not (Test-OSyncTrustedDirOwner -Dir $LandingRoot)) { return $false }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $aclText = @(& icacls.exe $LandingRoot 2>&1)
        $out = ($aclText -join "`n")
    }
    catch { $out = '' }
    finally { $ErrorActionPreference = $oldEap }
    # icacls displays ACEs either as SID form (*S-1-5-18:...) or as resolved
    # names (NT AUTHORITY\SYSTEM / BUILTIN\Users) - match both.
    $hasSystem = ($out -match 'S-1-5-18') -or ($out -match 'SYSTEM')
    $hasUsers = ($out -match 'S-1-5-32-545') -or ($out -match 'Users')
    if ($hasSystem -and $hasUsers) { return $true }
    return $false
}

function Invoke-OSyncApplySelfRefresh {
    <#
      Self-refreshes the tool landing from a VERIFIED tool payload. Strict
      order (Oracle m9 / Momus r7-MAJOR-1): /MIR /XD config into
      <landing>.new, carry the CURRENT landing's config\ into .new\config
      (the B side owns its config, Oracle m4 - it must survive every
      rotation), delete a stale <landing>.old, rename current -> .old,
      then .new -> current. Any failure is caught and reported - the caller
      logs it and retries next cycle (Oracle m5). An interruption can never
      leave a half-damaged current copy (the swap is rename-based).
      Returns { Refreshed, Message }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ToolDir,
        [Parameter(Mandatory = $false)][string]$LandingRoot = 'C:\PakageSync'
    )
    $LandingRoot = $LandingRoot.TrimEnd('\')
    try {
        if (-not (Test-Path -LiteralPath $ToolDir -PathType Container)) {
            return [pscustomobject]@{ Refreshed = $false; Message = "tool payload not found at '$ToolDir' - refresh aborted." }
        }
        $newDir = $LandingRoot + '.new'
        $oldDir = $LandingRoot + '.old'
        $leaf = $LandingRoot | Split-Path -Leaf
        if (Test-Path -LiteralPath $newDir -PathType Container) {
            Remove-Item -LiteralPath $newDir -Recurse -Force -ErrorAction Stop
        }
        Invoke-OSyncRobocopy -Source $ToolDir -Destination $newDir -ExtraArgs @('/MIR', '/XD', 'config') | Out-Null
        # The B side owns its config (Oracle m4): carry the CURRENT landing's
        # config\ into .new BEFORE the swap so the local config survives every
        # rotation. Without this the config only ever rides into .old, which
        # the NEXT refresh deletes - permanent config loss (F3).
        $currentConfig = Join-Path $LandingRoot 'config'
        if (Test-Path -LiteralPath $currentConfig -PathType Container) {
            Invoke-OSyncRobocopy -Source $currentConfig -Destination (Join-Path $newDir 'config') -ExtraArgs @('/E') | Out-Null
        }
        if (Test-Path -LiteralPath $oldDir -PathType Container) {
            Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $LandingRoot -PathType Container) {
            $oldName = $leaf + '.old'
            Rename-Item -LiteralPath $LandingRoot -NewName $oldName -Force -ErrorAction Stop
        }
        Rename-Item -LiteralPath $newDir -NewName $leaf -Force -ErrorAction Stop
        return [pscustomobject]@{ Refreshed = $true; Message = "tool landing refreshed from '$ToolDir' (exact order: .new -> carry config -> delete .old -> current -> .old -> .new -> current; local config preserved)." }
    }
    catch {
        return [pscustomobject]@{ Refreshed = $false; Message = "self-refresh FAILED: $($_.Exception.Message)" }
    }
}

function Invoke-OSyncApplyOneCategory {
    <#
      Dispatches ONE category's apply function against the verified work
      copy. Returns { Status, Message, LastApplied }. Success (or the
      dotfiles source-hash 'skipped') stamps lastApplied; failure leaves it
      untouched so the next round retries (Metis m1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('winget', 'pip', 'npm', 'dotfiles')][string]$Category,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $false)][string]$VerdaccioTaskName = 'PakageSync-Verdaccio',
        [Parameter(Mandatory = $false)][bool]$WhatIf = $false
    )
    if ($WhatIf) {
        # WhatIf never runs the apply functions - the orchestrator reports
        # the would-apply decisions itself.
        return [pscustomobject]@{ Status = 'would-apply'; Message = 'WhatIf: apply would run against the verified work copy.'; LastApplied = $null }
    }
    $report = $null
    switch ($Category) {
        'winget' { $report = Invoke-OSyncWingetApply -WorkDir $WorkDir -Config $Config }
        'pip'    { $report = Invoke-OSyncPipApply -WorkDir $WorkDir -Config $Config }
        'npm'    { $report = Invoke-OSyncNpmApply -WorkDir $WorkDir -Config $Config -VerdaccioTaskName $VerdaccioTaskName }
        'dotfiles' { $report = Invoke-OSyncDotfilesApply -WorkDir $WorkDir -Config $Config }
    }
    if ($null -ne $report -and $report.PSObject.Properties.Name -contains 'status') {
        if ($report.status -eq 'ok') {
            return [pscustomobject]@{ Status = 'ok'; Message = "$Category apply reported ok."; LastApplied = $null }
        }
        if ($report.status -eq 'skipped') {
            # dotfiles 'skipped' = source hash unchanged = content already
            # applied -> safe to stamp lastApplied (prevents retrying every
            # cycle). No other apply function returns 'skipped'.
            return [pscustomobject]@{ Status = 'skipped'; Message = "$Category apply reported skipped (already current)."; LastApplied = 'stamp' }
        }
        return [pscustomobject]@{ Status = 'failed'; Message = "$Category apply reported status '$($report.status)'."; LastApplied = $null }
    }
    return [pscustomobject]@{ Status = 'ok'; Message = "$Category apply completed (no status field)."; LastApplied = $null }
}

function Invoke-OSyncApply {
    <#
      Runs one B-side apply round (see the module header for the full flow).
      Returns the result object { mode, whatIf, outcome, skipReason, error,
      exportedAtUtc, bootstrapped, bootstrapRan, pendingCategories,
      generation, verified, categories, refreshed, refreshSkippedReason,
      cleaned }. Never throws for handled conditions; hard failures surface
      as outcome='failed' + error. The apply.lock is NOT taken here - the
      entry script owns it (Momus r7-m3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $false)][string[]]$Category = @(),
        [switch]$WhatIf,
        # Suppresses ONLY the runtime-drift-triggered bootstrap self-heal in
        # the packages round (see Invoke-OSyncApplyPackagesRound). A machine
        # that never bootstrapped is unaffected and still bootstraps - it has
        # no Python/Node/Verdaccio and could not apply anything otherwise.
        [switch]$SkipRuntime,
        # QA seams (production uses the defaults): a QA run must use clearly
        # temp-named scheduled tasks so the A-side task store is never
        # polluted with B-side service names (same convention as bootstrap).
        [Parameter(Mandatory = $false)][string]$VerdaccioTaskName = 'PakageSync-Verdaccio',
        [Parameter(Mandatory = $false)][string]$WingetSettingsTaskName = 'PakageSync-WingetSettings-OneShot',
        # Test seam: production ALWAYS refreshes the fixed C:\PakageSync.
        [Parameter(Mandatory = $false)][string]$LandingRoot = 'C:\PakageSync'
    )

    $mode = Get-OSyncApplyMode -Category $Category
    $repoRoot = [System.IO.Path]::GetFullPath([string]$Config.repoRoot)
    $stateDir = [string]$Config.stateDir

    $result = [pscustomobject]@{
        mode                  = $mode
        whatIf                = [bool]$WhatIf
        outcome               = 'skipped'
        skipReason            = $null
        error                 = $null
        exportedAtUtc         = $null
        bootstrapped          = $null
        bootstrapRan          = $false
        pendingCategories     = @()
        generation            = $null
        verified              = $false
        categories            = [ordered]@{}
        refreshed             = $false
        refreshSkippedReason  = $null
        cleaned               = $false
    }

    if ([string]::IsNullOrWhiteSpace($stateDir)) {
        $result.outcome = 'failed'
        $result.error = 'ApplyOrchestrator.ps1: config.stateDir is empty.'
        return $result
    }
    if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) {
        $result.outcome = 'skipped'
        $result.skipReason = "repository root not found: '$repoRoot'."
        Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }

    Write-OSyncLog -Category 'apply' -Level Info `
        -Message ("apply round starting (mode={0}, repoRoot='{1}', category='{2}', whatIf={3})." -f $mode, $repoRoot, ($Category -join ','), $WhatIf) `
        -Data @{ mode = $mode; repoRoot = $repoRoot; category = @($Category); whatIf = [bool]$WhatIf } -Config $Config | Out-Null

    # [1] Trust root (Metis B2). An invalid/unparseable index -> whole round
    # skipped - nothing downstream is trusted.
    $integrity = $null
    try {
        $integrity = Test-OSyncRepoIntegrity -RepoRoot $repoRoot
    }
    catch {
        $result.outcome = 'skipped'
        $result.skipReason = "index.json read failed: $($_.Exception.Message)"
        Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    if ($integrity.Overall -eq 'Invalid') {
        $result.outcome = 'skipped'
        $result.skipReason = "repository trust root is INVALID: $($integrity.IndexError)"
        Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    $result.exportedAtUtc = $integrity.ExportedAtUtc
    $exportedAtUtc = [string]$integrity.ExportedAtUtc
    if ([string]::IsNullOrWhiteSpace($exportedAtUtc)) {
        $result.outcome = 'skipped'
        $result.skipReason = 'index.json has no exportedAtUtc.'
        Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    # The generation id becomes a DIRECTORY name under <stateDir>\work\ (and
    # is later Remove-Item'd on rebuild) - a '..\'-shaped value would escape
    # work\. Validate the strict basic-format stamp before any path use (same
    # semantics as the dotfiles-side ^\d{8}T\d{6}Z$ filter and
    # Assert-OExportedAtUtc).
    if ($exportedAtUtc -notmatch '^\d{8}T\d{6}Z$') {
        $result.outcome = 'skipped'
        $result.skipReason = "index.json exportedAtUtc '$exportedAtUtc' is not a valid generation id (expected ^\d{8}T\d{6}Z$)."
        Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }

    if ($mode -eq 'dotfiles') {
        return (Invoke-OSyncApplyDotfilesRound -Config $Config -Result $result -Integrity $integrity -ExportedAtUtc $exportedAtUtc -RepoRoot $repoRoot -WhatIf:$WhatIf)
    }
    return (Invoke-OSyncApplyPackagesRound -Config $Config -Result $result -Integrity $integrity -ExportedAtUtc $exportedAtUtc -RepoRoot $repoRoot -Category $Category -WhatIf:$WhatIf -SkipRuntime:$SkipRuntime `
        -VerdaccioTaskName $VerdaccioTaskName -WingetSettingsTaskName $WingetSettingsTaskName -LandingRoot $LandingRoot)
}

function Invoke-OSyncApplyPackagesRound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Integrity,
        [Parameter(Mandatory = $true)][string]$ExportedAtUtc,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $false)][string[]]$Category = @(),
        [switch]$WhatIf,
        # Suppresses ONLY the drift-triggered bootstrap self-heal (the
        # never-bootstrapped trigger below is unconditional).
        [switch]$SkipRuntime,
        [Parameter(Mandatory = $false)][string]$VerdaccioTaskName = 'PakageSync-Verdaccio',
        [Parameter(Mandatory = $false)][string]$WingetSettingsTaskName = 'PakageSync-WingetSettings-OneShot',
        [Parameter(Mandatory = $false)][string]$LandingRoot = 'C:\PakageSync'
    )
    $stateDir = [string]$Config.stateDir
    $enabled = @(Get-OSyncApplyEnabledCategories -Config $Config)

    # [2] Bootstrap self-heal (packages/SYSTEM only - Oracle m11 / Momus m4).
    $state = Get-OSyncState -Category 'winget' -Config $Config
    $bootstrapped = ($true -eq $state.bootstrapped)
    $result.bootstrapped = $bootstrapped
    $drift = $false
    if ($bootstrapped) {
        try { $drift = Test-OSyncRuntimeDrift -RepoRoot $RepoRoot -State $state } catch { $drift = $false }
    }
    # -SkipRuntime suppresses ONLY the drift half of the trigger: a machine
    # that never bootstrapped has no Python/Node/Verdaccio and must still
    # bootstrap (the switch is an operator opt-out of reinstalling a drifted
    # runtime payload, not of the initial bootstrap).
    $needBootstrap = (-not $bootstrapped) -or ($drift -and -not $SkipRuntime)
    if (-not $WhatIf -and $needBootstrap) {
        Write-OSyncLog -Category 'apply' -Level Info `
            -Message ("packages round: bootstrap self-heal triggered (bootstrapped={0}, runtimeDrift={1})." -f $bootstrapped, $drift) `
            -Data @{ bootstrapped = $bootstrapped; drift = $drift } -Config $Config | Out-Null
        $bootResult = Invoke-OSyncBootstrap -Config $Config `
            -VerdaccioTaskName $VerdaccioTaskName -WingetSettingsTaskName $WingetSettingsTaskName
        $result.bootstrapRan = $true
        if (-not $bootResult.Success) {
            # The auto path is a safety net; a failed bootstrap skips the
            # whole round and the next cycle retries.
            $result.outcome = 'skipped'
            $result.skipReason = "bootstrap self-heal failed: $($bootResult.Error)"
            Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
            return $result
        }
        $bootstrapped = $true
        $result.bootstrapped = $true
        # Re-read the state (the bootstrap re-recorded the runtime hashes).
        $state = Get-OSyncState -Category 'winget' -Config $Config
        Write-OSyncLog -Category 'apply' -Level Info -Message 'packages round: bootstrap self-heal SUCCEEDED.' -Config $Config | Out-Null
    }
    elseif (-not $WhatIf -and $drift -and $SkipRuntime) {
        # Drift is real but the operator suppressed the self-heal: the round
        # continues with the currently installed runtime (no bootstrapRan).
        Write-OSyncLog -Category 'apply' -Level Warning `
            -Message 'runtime drift detected but bootstrap self-heal suppressed by -SkipRuntime.' `
            -Data @{ bootstrapped = $bootstrapped; drift = $true } -Config $Config | Out-Null
    }

    # [3] Pending judgment across ALL enabled categories (Momus r5-m2): the
    # work copy is built when any of them is newer, not only the requested
    # ones - a dotfiles-only config still gets a packages-task work copy.
    $pending = @()
    $plans = [ordered]@{}
    foreach ($cat in $enabled) {
        $catResult = $null
        if ($Integrity.Categories.ContainsKey($cat)) { $catResult = $Integrity.Categories[$cat] }
        $catOk = ($null -ne $catResult) -and ($catResult.Status -eq 'OK')
        if (-not $catOk) { continue }
        try {
            $plan = Get-OSyncApplyCategoryPlan -Category $cat -Config $Config -Integrity $Integrity -ExportedAtUtc $ExportedAtUtc -RepoRoot $RepoRoot
        }
        catch {
            $plan = [pscustomobject]@{
                category = $cat; mode = 'full'; baseExportedAtUtc = $null; baseDir = $null
                fallbackReason = "category planning failed: $($_.Exception.Message)"
                currentManifest = $null; baselineManifest = $null; stats = New-OApplyTransferStats
            }
        }
        $plans[$cat] = $plan
        if ($plan.mode -in @('full', 'delta')) { $pending += $cat }
        Write-OSyncLog -Category 'apply' -Level Info -Message ("copy plan '{0}': mode={1}, base={2}, reason={3}." -f $cat, $plan.mode, $plan.baseExportedAtUtc, $plan.fallbackReason) -Data (Get-OApplyPlanReport -Plan $plan) -Config $Config | Out-Null
    }
    $result.pendingCategories = @($pending)
    $result | Add-Member -NotePropertyName copyPlans -NotePropertyValue ([ordered]@{}) -Force
    foreach ($cat in $plans.Keys) { $result.copyPlans[$cat] = Get-OApplyPlanReport -Plan $plans[$cat] }

    # WhatIf report (Metis m3): zero changes - no bootstrap, no generation,
    # no apply, no refresh, no cleanup.
    if ($WhatIf) {
        foreach ($cat in $script:OApplyCategories) {
            $requested = ($Category.Count -eq 0) -or ($Category -contains $cat)
            if (-not $requested -or $enabled -notcontains $cat) {
                $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'not-requested'
                continue
            }
            if ($cat -eq 'dotfiles') {
                # packages (SYSTEM) mode never applies dotfiles.
                $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'not-applied' -Message 'dotfiles is applied by the user-context task only (SYSTEM context would hit the wrong profile).'
                continue
            }
            if ($pending -contains $cat) {
                $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'would-apply' -Message "WhatIf: would apply '$cat' from a new verified work copy for generation $ExportedAtUtc."
            }
            else {
                $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'up-to-date' -Message "WhatIf: '$cat' is already at generation $ExportedAtUtc."
            }
        }
        $result.outcome = 'ok'
        Write-OSyncLog -Category 'apply' -Level Info -Message "apply WhatIf report produced (pending: $($pending -join ',')); zero changes." -Data @{ pending = @($pending); exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
        return $result
    }

    # Pending-only category work copy; runtime remains complete.
    if ($pending.Count -eq 0) {
        $result.outcome = 'skipped'
        $result.skipReason = 'nothing pending - all enabled categories are already applied or content-equivalent to their verified baselines (repository generation ' + $ExportedAtUtc + ').'
        Write-OSyncLog -Category 'apply' -Level Info -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        # No generation this round -> no verified source to refresh from.
        $result.refreshSkippedReason = 'no generation built this round (nothing pending) - tool-only changes are covered by the bootstrap drift path.'
        $result.cleaned = (Invoke-OSyncApplyWorkCleanup -StateDir $stateDir -Keep 2)
        return $result
    }

    # runtime Incomplete -> the whole round is skipped (chezmoi.exe and the
    # tool payload live in the runtime category, Momus r4-B1).
    $runtimeCat = $null
    if ($Integrity.Categories.ContainsKey('runtime')) { $runtimeCat = $Integrity.Categories['runtime'] }
    if ($null -eq $runtimeCat -or $runtimeCat.Status -ne 'OK') {
        $result.outcome = 'skipped'
        $result.skipReason = "runtime category is not OK (status '$($runtimeCat.Status)') - the work copy would be missing chezmoi.exe / tool payload."
        Write-OSyncLog -Category 'apply' -Level Warning -Message "round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }

    $okCategories = @($enabled | Where-Object {
        $cr = $null
        if ($Integrity.Categories.ContainsKey($_)) { $cr = $Integrity.Categories[$_] }
        ($null -ne $cr) -and ($cr.Status -eq 'OK')
    })

    $gen = Join-Path (Join-Path $stateDir 'work') $ExportedAtUtc
    $markerExisting = Join-Path $gen '.verified'
    $existingComplete = Test-Path -LiteralPath $markerExisting -PathType Leaf
    if ($existingComplete) {
        foreach ($cat in $pending) {
            if (-not (Test-Path -LiteralPath (Join-Path $gen "$cat\files.json") -PathType Leaf)) {
                $existingComplete = $false
                break
            }
        }
    }

    if ($existingComplete) {
        # A verified generation for THIS exact export already exists (a
        # previous round built it; the dotfiles task may still be consuming
        # it). Reuse it instead of re-copying + re-hashing the whole repo
        # every cycle - the work copy is a snapshot of this index ts and its
        # .verified marker already proves it (Momus M3/Oracle M4).
        $result.generation = $gen
        $result.verified = $true
        Write-OSyncLog -Category 'apply' -Level Info -Message "reusing already-verified generation '$gen' (export $ExportedAtUtc)." -Data @{ generation = $gen; exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
    }
    else {
        try {
            $gen = New-OSyncApplyGeneration -Config $Config -RepoRoot $RepoRoot -ExportedAtUtc $ExportedAtUtc -OkCategories $okCategories -Plans $plans
        }
        catch {
            $result.outcome = 'failed'
            $result.error = "work copy creation failed: $($_.Exception.Message)"
            Write-OSyncLog -Category 'apply' -Level Error -Message "round FAILED: $($result.error)" -Config $Config | Out-Null
            return $result
        }
        $result.generation = $gen
        foreach ($cat in $plans.Keys) { $result.copyPlans[$cat] = Get-OApplyPlanReport -Plan $plans[$cat] }
        $result | Add-Member -NotePropertyName copyPlanPath -NotePropertyValue (Join-Path $gen 'copy-plan.json') -Force

        # Re-verify EVERY copied file (Momus M3/Oracle M4). Verify failure ->
        # DELETE the whole generation and fail the round - a bad generation
        # must never remain "newest" (Momus r4-B1).
        try {
            $null = Test-OSyncApplyWorkCopy -Bw $gen
            Write-OSyncLog -Category 'apply' -Level Info -Message "work copy re-verification PASSED at '$gen'." -Data @{ generation = $gen; exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
        }
        catch {
            if (Test-Path -LiteralPath $gen -PathType Container) {
                Remove-Item -LiteralPath $gen -Recurse -Force -ErrorAction SilentlyContinue
            }
            $result.generation = $null
            $result.outcome = 'failed'
            $result.error = "work copy re-verification FAILED; generation deleted: $($_.Exception.Message)"
            Write-OSyncLog -Category 'apply' -Level Error -Message "round FAILED: $($result.error)" -Config $Config | Out-Null
            return $result
        }
        $marker = Write-OSyncApplyVerifiedMarker -Bw $gen -ExportedAtUtc $ExportedAtUtc
        $result.verified = $true
        Write-OSyncLog -Category 'apply' -Level Info -Message "verified marker written: '$marker'." -Data @{ marker = $marker } -Config $Config | Out-Null
        foreach ($cat in $pending) {
            $stats = $plans[$cat].stats
            Write-OSyncLog -Category 'apply' -Level Info -Message ("materialized '{0}': mode={1}, copied={2}/{3} bytes, reused={4}/{5} bytes, deleted={6}/{7} bytes, repoCopied={8}/{9} bytes." -f $cat, $plans[$cat].mode, $stats.copiedFiles, $stats.copiedBytes, $stats.reusedFiles, $stats.reusedBytes, $stats.deletedFiles, $stats.deletedBytes, $stats.repoCopiedFiles, $stats.repoCopiedBytes) -Data (Get-OApplyPlanReport -Plan $plans[$cat]) -Config $Config | Out-Null
        }
    }

    # [4] Per-category apply - one category's failure never blocks the others
    # (Metis m1); success stamps lastApplied, failure leaves it for retry.
    $requested = if ($Category.Count -eq 0) { @($enabled) } else {
        @($Category | Where-Object { $enabled -contains $_ })
    }
    foreach ($cat in $script:OApplyCategories) {
        if ($requested -notcontains $cat) {
            $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'not-requested'
            continue
        }
        if ($cat -eq 'dotfiles') {
            $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'not-applied' -Message 'dotfiles is applied by the user-context task only (SYSTEM context would hit the wrong profile).'
            continue
        }
        $catResult = $null
        if ($Integrity.Categories.ContainsKey($cat)) { $catResult = $Integrity.Categories[$cat] }
        if ($null -eq $catResult -or $catResult.Status -ne 'OK') {
            $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'not-available' -Message "category not OK in the repository (status '$($catResult.Status)') - not applied this round."
            Write-OSyncLog -Category 'apply' -Level Warning -Message "category '$cat' skipped (integrity not OK) - retrying next round." -Config $Config | Out-Null
            continue
        }
        if ($pending -notcontains $cat) {
            $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'not-pending' -Message "already at generation $ExportedAtUtc - nothing to apply."
            continue
        }
        Write-OSyncLog -Category 'apply' -Level Info -Message "applying category '$cat' from '$gen'." -Data @{ category = $cat; generation = $gen } -Config $Config | Out-Null
        $applyResult = $null
        try {
            $applyResult = Invoke-OSyncApplyOneCategory -Category $cat -WorkDir $gen -Config $Config -VerdaccioTaskName $VerdaccioTaskName
        }
        catch {
            $applyResult = [pscustomobject]@{ Status = 'failed'; Message = $_.Exception.Message; LastApplied = $null }
        }
        if ($applyResult.Status -in @('ok', 'skipped')) {
            try {
                Set-OSyncLastApplied -Category $cat -ExportedAtUtc $ExportedAtUtc -Config $Config | Out-Null
                $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status $applyResult.Status -Message $applyResult.Message -LastApplied $ExportedAtUtc
                Write-OSyncLog -Category 'apply' -Level Info -Message "category '$cat' applied; lastApplied.$cat=$ExportedAtUtc." -Data @{ category = $cat; exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
            }
            catch {
                $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'failed' -Message "apply succeeded but lastApplied stamp failed: $($_.Exception.Message)" -LastApplied $null
                Write-OSyncLog -Category 'apply' -Level Error -Message "category '$cat' lastApplied stamp FAILED: $($_.Exception.Message)" -Config $Config | Out-Null
            }
        }
        else {
            $result.categories[$cat] = New-OApplyCategoryResult -Category $cat -Status 'failed' -Message $applyResult.Message -LastApplied $null
            Write-OSyncLog -Category 'apply' -Level Error -Message "category '$cat' FAILED (lastApplied untouched, retry next round): $($applyResult.Message)" -Config $Config | Out-Null
        }
    }

    # [5] Self-refresh (packages task only, regardless of per-category
    # outcome) + work\ cleanup.
    if (Test-OSyncLandingReadyForRefresh -LandingRoot $LandingRoot) {
        $toolDir = Join-Path $gen 'runtime\tool'
        $refresh = Invoke-OSyncApplySelfRefresh -ToolDir $toolDir -LandingRoot $LandingRoot
        $result.refreshed = $refresh.Refreshed
        if (-not $refresh.Refreshed) {
            $result.refreshSkippedReason = $refresh.Message
            Write-OSyncLog -Category 'apply' -Level Warning -Message "self-refresh skipped/failed (logged only, retry next cycle): $($refresh.Message)" -Config $Config | Out-Null
        }
        else {
            Write-OSyncLog -Category 'apply' -Level Info -Message "self-refresh of '$LandingRoot' SUCCEEDED (takes effect next cycle)." -Config $Config | Out-Null
        }
    }
    else {
        $result.refreshSkippedReason = "landing '$LandingRoot' failed the owner/ACL re-verification - refresh abandoned + alert."
        Write-OSyncLog -Category 'apply' -Level Warning -Message $result.refreshSkippedReason -Config $Config | Out-Null
    }
    $result.cleaned = (Invoke-OSyncApplyWorkCleanup -StateDir $stateDir -Keep 2)

    $result.outcome = 'ok'
    Write-OSyncLog -Category 'apply' -Level Info -Message ("packages round completed (outcome=ok, generation={0}, refreshed={1})." -f $gen, $result.refreshed) -Data @{ generation = $gen; refreshed = $result.refreshed } -Config $Config | Out-Null
    return $result
}

function Invoke-OSyncApplyDotfilesRound {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)]$Integrity,
        [Parameter(Mandatory = $true)][string]$ExportedAtUtc,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$WhatIf
    )
    $stateDir = [string]$Config.stateDir

    # Unbootstrapped user task -> skip + log (Oracle m11). The dotfiles
    # runtime (chezmoi.exe / tool) is not in place yet.
    $state = Get-OSyncState -Category 'winget' -Config $Config
    $bootstrapped = ($true -eq $state.bootstrapped)
    $result.bootstrapped = $bootstrapped
    if (-not $bootstrapped) {
        $result.outcome = 'skipped'
        $result.skipReason = 'not bootstrapped - the user-context dotfiles task skips until the packages/SYSTEM task has run the bootstrap.'
        Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }

    if (-not $Integrity.Categories.ContainsKey('dotfiles') -or $Integrity.Categories['dotfiles'].Status -ne 'OK') {
        $result.outcome = 'skipped'
        $result.skipReason = 'dotfiles category is not OK in the repository.'
        return $result
    }
    try {
        $dotfilesPlan = Get-OSyncApplyCategoryPlan -Category 'dotfiles' -Config $Config -Integrity $Integrity -ExportedAtUtc $ExportedAtUtc -RepoRoot $RepoRoot
    }
    catch {
        $dotfilesPlan = [pscustomobject]@{ mode = 'full'; fallbackReason = $_.Exception.Message; baseExportedAtUtc = $null; stats = New-OApplyTransferStats }
    }
    $result | Add-Member -NotePropertyName copyPlans -NotePropertyValue ([ordered]@{ dotfiles = (Get-OApplyPlanReport -Plan $dotfilesPlan) }) -Force
    if ($dotfilesPlan.mode -eq 'skip') {
        $result.outcome = 'skipped'
        $result.skipReason = if ($dotfilesPlan.fallbackReason -eq 'already applied') { "dotfiles already at generation $ExportedAtUtc." } else { "dotfiles content does not require apply: $($dotfilesPlan.fallbackReason)." }
        $result.categories['dotfiles'] = New-OApplyCategoryResult -Category 'dotfiles' -Status 'not-pending' -Message $result.skipReason -LastApplied $dotfilesPlan.baseExportedAtUtc
        Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    $result.pendingCategories = @('dotfiles')

    # Consume ONLY the newest .verified generation (Momus M2). None (or one
    # older than the current index - the packages task has not produced a
    # verified generation for this export yet) -> skip + log; the next cycle
    # catches up (Momus r4-B1).
    $gen = Get-OSyncApplyNewestVerifiedGeneration -StateDir $stateDir
    if ($null -eq $gen) {
        $result.outcome = 'skipped'
        $result.skipReason = 'dotfiles pending but no verified generation exists yet - the packages task must build it first.'
        Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    if ([string]::CompareOrdinal($gen.Ts, $ExportedAtUtc) -lt 0) {
        $result.outcome = 'skipped'
        $result.skipReason = "dotfiles pending but the newest verified generation ($($gen.Ts)) predates the current index ($ExportedAtUtc) - waiting for the packages task to verify the new export."
        Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    if (-not (Test-Path -LiteralPath (Join-Path $gen.Path 'dotfiles\files.json') -PathType Leaf)) {
        $result.outcome = 'skipped'
        $result.skipReason = "dotfiles is pending but verified generation '$($gen.Ts)' does not contain that category - waiting for the packages task."
        Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles round skipped: $($result.skipReason)" -Config $Config | Out-Null
        return $result
    }
    $result.generation = $gen.Path
    $result.verified = $true

    if ($WhatIf) {
        $result.categories['dotfiles'] = New-OApplyCategoryResult -Category 'dotfiles' -Status 'would-apply' -Message "WhatIf: would apply dotfiles from verified generation $($gen.Ts) (zero changes)."
        $result.outcome = 'ok'
        Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles WhatIf report produced (generation=$($gen.Ts)); zero changes." -Data @{ generation = $gen.Ts; exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
        return $result
    }

    Write-OSyncLog -Category 'apply' -Level Info -Message "applying dotfiles from verified generation '$($gen.Path)'." -Data @{ generation = $gen.Path; exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
    $applyResult = $null
    try {
        $applyResult = Invoke-OSyncApplyOneCategory -Category 'dotfiles' -WorkDir $gen.Path -Config $Config
    }
    catch {
        $applyResult = [pscustomobject]@{ Status = 'failed'; Message = $_.Exception.Message; LastApplied = $null }
    }
    if ($applyResult.Status -in @('ok', 'skipped')) {
        try {
            Set-OSyncLastApplied -Category 'dotfiles' -ExportedAtUtc $ExportedAtUtc -Config $Config | Out-Null
            $result.categories['dotfiles'] = New-OApplyCategoryResult -Category 'dotfiles' -Status $applyResult.Status -Message $applyResult.Message -LastApplied $ExportedAtUtc
            Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles applied; lastApplied.dotfiles=$ExportedAtUtc." -Data @{ exportedAtUtc = $ExportedAtUtc } -Config $Config | Out-Null
        }
        catch {
            $result.categories['dotfiles'] = New-OApplyCategoryResult -Category 'dotfiles' -Status 'failed' -Message "apply succeeded but lastApplied stamp failed: $($_.Exception.Message)" -LastApplied $null
            Write-OSyncLog -Category 'apply' -Level Error -Message "dotfiles lastApplied stamp FAILED: $($_.Exception.Message)" -Config $Config | Out-Null
        }
    }
    else {
        $result.categories['dotfiles'] = New-OApplyCategoryResult -Category 'dotfiles' -Status 'failed' -Message $applyResult.Message -LastApplied $null
        Write-OSyncLog -Category 'apply' -Level Error -Message "dotfiles FAILED (lastApplied untouched, retry next round): $($applyResult.Message)" -Config $Config | Out-Null
    }

    $result.outcome = 'ok'
    Write-OSyncLog -Category 'apply' -Level Info -Message "dotfiles round completed (outcome=ok, generation=$($gen.Path))." -Data @{ generation = $gen.Path } -Config $Config | Out-Null
    return $result
}
