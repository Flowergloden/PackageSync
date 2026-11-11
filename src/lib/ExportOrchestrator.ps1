#Requires -Version 5.1
<#
  ExportOrchestrator.ps1 - A-side export orchestration for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncExport -ConfigPath <file> [-Category winget,pip,npm,dotfiles]
    is the core of src\Export-OfflineRepo.ps1 (the entry script is a thin
    wrapper that imports the module and maps the report's Success flag to
    the process exit code).

    1. Get-OSyncConfig - the role MUST be 'A' (this is the A-side
       orchestrator; the B-side apply orchestrator is todo 17).
    2. Pre-flight: python / node / npm / winget must be resolvable for the
       enabled categories - a missing tool is an explicit error BEFORE any
       staging work (Oracle m7). Refresh the enabled package manifests
       from locally installed versions without prompting; also refresh the
       runtime whitelist unless -SkipRuntime reuses the published payload.
    3. Creates <stagingRoot>\<yyyyMMddTHHmmssZ>\ - the same ISO8601-basic
       format and source ([datetime]::UtcNow) as the index exportedAtUtc
       (Oracle r7-2).
    4. Runs Export-OSyncWinget/Pip/Npm/Dotfiles/Runtime for the enabled
       categories (runtime always runs unless -SkipRuntime reuses the latest
       successful local generation, falling back to <repoRoot>). Each category
       is try/caught into the export report; one failure does NOT block others.
    5. Per category New-OSyncFilesManifest, then Publish-OSyncIndex - the
       index.json is the LAST index artifact written into the staging root.
    6. Test-OSyncRepoIntegrity on the staging root: publish only when
       Overall == 'OK' AND no category failed; otherwise abort with the report.
    7. Invoke-OSyncIncrementalPublish compares parsed files.json maps and only
       copies changed payloads/deletes stale files. Unchanged categories retain
       their published manifest and index record. index.json is written LAST;
       an all-unchanged run is a successful no-op and leaves it untouched.
    8. Export report JSON + logging, including per-category transfer stats.
    9. After a successful publish/no-op, clean <stagingRoot> keeping only the
       newest 3 generations. The A-side-only .verdaccio-a dir is never touched.

  Returns a SINGLE report object (Success = $true for a published run or a
  content-equivalent no-op). Every Write-OSyncLog
  call is piped to Out-Null - Write-OSyncLog RETURNS the JSONL path and a
  bare call would leak strings into the output stream (documented gotcha).
#>

function Test-OSyncExportPreflight {
    <#
      Checks that the tools required by the enabled categories are
      resolvable. Returns [pscustomobject]@{ Ok; Missing = @() } - the
      orchestrator throws with the missing list when Ok is $false.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string[]]$Category
    )

    $missing = New-Object System.Collections.Generic.List[string]

    if ('pip' -in $Category) {
        try {
            $null = Resolve-OSyncPython
        }
        catch {
            $missing.Add('python (pip category)')
        }
    }

    if ('npm' -in $Category) {
        if ($null -eq (Get-Command node -ErrorAction SilentlyContinue)) {
            $missing.Add('node (npm category)')
        }
        if ($null -eq (Get-Command npm -ErrorAction SilentlyContinue)) {
            $missing.Add('npm (npm category)')
        }
    }

    if ('winget' -in $Category) {
        $wingetExe = Resolve-OSyncWingetExePath
        if ($null -eq $wingetExe) {
            $missing.Add('winget.exe (winget category)')
        }
    }

    return [pscustomobject]@{ Ok = ($missing.Count -eq 0); Missing = @($missing) }
}

function Invoke-OSyncStagingCleanup {
    <#
      Removes all but the newest <Keep> generation dirs under <StagingRoot>.
      A generation is a directory whose name matches ^\d{8}T\d{6}Z$ (the
      same format as the staging dir and the index exportedAtUtc; fixed-width
      zero-padded names sort chronologically). Anything else - e.g. the
      A-side-only .verdaccio-a tool dir - is never touched.
      Returns [pscustomobject]@{ Kept; Removed }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingRoot,

        [Parameter(Mandatory = $false)]
        [int]$Keep = 3
    )

    $kept = @()
    $removed = @()
    if (Test-Path -LiteralPath $StagingRoot -PathType Container) {
        $generations = @(
            Get-ChildItem -LiteralPath $StagingRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d{8}T\d{6}Z$' } |
                Sort-Object Name -Descending
        )
        for ($i = $Keep; $i -lt $generations.Count; $i++) {
            Remove-Item -LiteralPath $generations[$i].FullName -Recurse -Force -ErrorAction SilentlyContinue
            $removed += $generations[$i].Name
        }
        $kept = @($generations | Select-Object -First $Keep | ForEach-Object { $_.Name })
    }
    return [pscustomobject]@{ Kept = $kept; Removed = $removed }
}

function Write-OSyncExportReport {
    <#
      Writes the export report JSON to <Path>. UTF-8 WITH BOM - PS 5.1
      misreads BOM-less non-ASCII as ANSI (documented gotcha).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Report,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $json = ConvertTo-OSyncJson -InputObject $Report
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-OSyncPublishCategoryPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$StagingDir,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )

    $currentDir = Join-Path $StagingDir $Category
    $repoDir = Join-Path $RepoRoot $Category
    $currentManifest = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText((Join-Path $currentDir 'files.json')))
    if ($null -eq $currentManifest -or $currentManifest -isnot [System.Collections.IDictionary]) {
        throw "Get-OSyncPublishCategoryPlan: current '$Category/files.json' is not a JSON object."
    }

    $publishedIndex = $null
    $publishedRecord = $null
    $publishedManifest = $null
    $fallbackReason = $null
    $indexPath = Join-Path $RepoRoot 'index.json'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        $fallbackReason = 'published index.json is missing'
    }
    else {
        try {
            $publishedIndex = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText($indexPath))
            if ($null -eq $publishedIndex -or $publishedIndex -isnot [System.Collections.IDictionary] -or
                -not $publishedIndex.ContainsKey('categories') -or $publishedIndex['categories'] -isnot [System.Collections.IDictionary] -or
                -not $publishedIndex['categories'].ContainsKey($Category)) {
                $fallbackReason = "published index has no usable record for '$Category'"
            }
            else {
                $publishedRecord = $publishedIndex['categories'][$Category]
                $publishedFiles = Join-Path $repoDir 'files.json'
                if (-not (Test-Path -LiteralPath $publishedFiles -PathType Leaf)) {
                    $fallbackReason = "published '$Category/files.json' is missing"
                }
                else {
                    $publishedManifest = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText($publishedFiles))
                    if ($null -eq $publishedManifest -or $publishedManifest -isnot [System.Collections.IDictionary]) {
                        $fallbackReason = "published '$Category/files.json' is not a JSON object"
                    }
                }
            }
        }
        catch {
            $fallbackReason = "published index or '$Category/files.json' is unreadable: $($_.Exception.Message)"
            $publishedManifest = $null
        }
    }

    $copy = @()
    $reuse = @()
    $delete = @()
    $repairReasons = @()
    if ($null -ne $fallbackReason) {
        foreach ($entry in $currentManifest.GetEnumerator()) {
            $meta = $entry.Value
            $copy += [pscustomobject]@{ relativePath = [string]$entry.Key; bytes = [int64]$meta['bytes']; sha256 = [string]$meta['sha256'] }
        }
    }
    else {
        foreach ($entry in $currentManifest.GetEnumerator()) {
            $rel = [string]$entry.Key
            $meta = $entry.Value
            $item = [pscustomobject]@{ relativePath = $rel; bytes = [int64]$meta['bytes']; sha256 = [string]$meta['sha256'] }
            $same = $publishedManifest.ContainsKey($rel)
            if ($same) {
                $old = $publishedManifest[$rel]
                $same = ($old -is [System.Collections.IDictionary]) -and
                    ($old.ContainsKey('bytes')) -and ($old.ContainsKey('sha256')) -and
                    ([int64]$old['bytes'] -eq $item.bytes) -and
                    ([string]::Equals([string]$old['sha256'], $item.sha256, [System.StringComparison]::OrdinalIgnoreCase))
            }
            if (-not $same) {
                $copy += $item
                continue
            }
            $target = Join-Path $repoDir ($rel.Replace('/', '\'))
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                $copy += $item
                $repairReasons += "target missing: $rel"
                continue
            }
            if ((Get-Item -LiteralPath $target -Force).Length -ne $item.bytes) {
                $copy += $item
                $repairReasons += "target length differs: $rel"
                continue
            }
            $reuse += $item
        }
        foreach ($entry in $publishedManifest.GetEnumerator()) {
            $rel = [string]$entry.Key
            if (-not $currentManifest.ContainsKey($rel)) {
                $old = $entry.Value
                $delete += [pscustomobject]@{ relativePath = $rel; bytes = [int64]$old['bytes']; sha256 = [string]$old['sha256'] }
            }
        }
    }

    $copiedBytes = ($copy | Measure-Object -Property bytes -Sum).Sum
    $reusedBytes = ($reuse | Measure-Object -Property bytes -Sum).Sum
    $deletedBytes = ($delete | Measure-Object -Property bytes -Sum).Sum
    $mode = if ($null -eq $fallbackReason) { 'incremental' } else { 'full' }
    return [pscustomobject]@{
        category          = $Category
        mode              = $mode
        changed           = ($mode -eq 'full' -or $copy.Count -gt 0 -or $delete.Count -gt 0)
        copy              = $copy
        reuse             = $reuse
        delete            = $delete
        copiedFiles       = $copy.Count
        copiedBytes       = $(if ($null -eq $copiedBytes) { 0 } else { [int64]$copiedBytes })
        reusedFiles       = $reuse.Count
        reusedBytes       = $(if ($null -eq $reusedBytes) { 0 } else { [int64]$reusedBytes })
        deletedFiles      = $delete.Count
        deletedBytes      = $(if ($null -eq $deletedBytes) { 0 } else { [int64]$deletedBytes })
        fallbackReason    = $fallbackReason
        repairReasons     = $repairReasons
        publishedRecord   = $publishedRecord
    }
}

function Invoke-OSyncIncrementalPublish {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StagingDir,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $false)]$Config
    )

    $currentIndexPath = Join-Path $StagingDir 'index.json'
    $currentIndex = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText($currentIndexPath))
    $publishedIndexPath = Join-Path $RepoRoot 'index.json'

    $plans = [ordered]@{}
    $publishedCategories = @()
    foreach ($entry in @($currentIndex['categories'].GetEnumerator())) {
        $cat = [string]$entry.Key
        $plan = Get-OSyncPublishCategoryPlan -Category $cat -StagingDir $StagingDir -RepoRoot $RepoRoot
        $plans[$cat] = $plan
        Write-OSyncLog -Category 'export' -Level Info -Message ("publish plan '{0}': mode={1}, copy={2}/{3} bytes, reuse={4}/{5} bytes, delete={6}/{7} bytes, fallback={8}." -f $cat, $plan.mode, $plan.copiedFiles, $plan.copiedBytes, $plan.reusedFiles, $plan.reusedBytes, $plan.deletedFiles, $plan.deletedBytes, $plan.fallbackReason) -Config $Config | Out-Null
        if (-not $plan.changed) {
            $currentIndex['categories'][$cat] = $plan.publishedRecord
            continue
        }

        $sourceDir = Join-Path $StagingDir $cat
        $targetDir = Join-Path $RepoRoot $cat
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        foreach ($item in $plan.copy) {
            $rel = $item.relativePath
            $source = Join-Path $sourceDir ($rel.Replace('/', '\'))
            $target = Join-Path $targetDir ($rel.Replace('/', '\'))
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        }
        foreach ($item in $plan.delete) {
            $target = Join-Path $targetDir ($item.relativePath.Replace('/', '\'))
            if (Test-Path -LiteralPath $target -PathType Leaf) {
                Remove-Item -LiteralPath $target -Force -ErrorAction Stop
            }
        }
        Copy-Item -LiteralPath (Join-Path $sourceDir 'files.json') -Destination (Join-Path $targetDir 'files.json') -Force -ErrorAction Stop
        $publishedCategories += $cat
        Write-OSyncLog -Category 'export' -Level Info -Message "published changed category '$cat' -> '$targetDir'." -Config $Config | Out-Null
    }

    $changed = @($plans.Values | Where-Object { $_.changed })
    if ($changed.Count -eq 0) {
        Write-OSyncLog -Category 'export' -Level Info -Message 'publish NO-OP: every delivered file matches the published repository; index.json and exportedAtUtc left unchanged.' -Config $Config | Out-Null
        return [pscustomobject]@{ published = $false; noOp = $true; indexCopied = $false; publishedCategories = @(); plans = $plans }
    }

    New-Item -ItemType Directory -Path $RepoRoot -Force | Out-Null
    Write-RcTextFile -Path $publishedIndexPath -Text (ConvertTo-OSyncJson -InputObject $currentIndex)
    Write-OSyncLog -Category 'export' -Level Info -Message "index.json written LAST to '$publishedIndexPath'." -Config $Config | Out-Null
    return [pscustomobject]@{ published = $true; noOp = $false; indexCopied = $true; publishedCategories = $publishedCategories; plans = $plans }
}

function Invoke-OSyncExport {
    <#
    .SYNOPSIS
        Runs the full A-side export pipeline: per-category export into a
        fresh <stagingRoot>\<yyyyMMddTHHmmssZ>\ generation, files.json +
        index.json, integrity gate, publish to <repoRoot>, staging cleanup.
        Returns the export report object (Success = $true on publish or no-op).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [string]$Category = 'winget,pip,npm,dotfiles',

        # Disables the live console echo (milestone log lines + throttled
        # winget download output). Echo is ON by default for export runs;
        # unattended scheduled runs are unaffected either way (Write-Host
        # with no interactive host is harmless).
        [Parameter(Mandatory = $false)]
        [switch]$Quiet,

        # Skips the runtime re-export (VC_redist/bun downloads, Python/Node
        # winget downloads, portable Verdaccio build, tool snapshot) and reuses
        # the latest successful local generation, falling back to repoRoot.
        # runtime\ and every runtime winget entry are mirrored into staging and
        # re-manifested, preserving index -> files.json -> per-file sha256.
        # The pre-check fails fast when neither source is complete.
        [Parameter(Mandatory = $false)]
        [switch]$SkipRuntime
    )

    $startedAt = [datetime]::UtcNow.ToString('o')

    # --- 1. config + role gate ---
    $config = Get-OSyncConfig -Path $ConfigPath
    if ($config.role -ne 'A') {
        throw "Export-OfflineRepo: config role must be 'A' (got '$($config.role)') - this script is the A-side export orchestrator."
    }

    # Console echo flag rides the IN-MEMORY config object only (never written
    # back to the JSON file). Write-OSyncLog and Invoke-OSyncWingetDownload
    # read it; absent/false means silent.
    $echoOn = -not $Quiet.IsPresent
    if ($config.PSObject.Properties['consoleEcho']) {
        $config.consoleEcho = $echoOn
    }
    else {
        $config | Add-Member -NotePropertyName consoleEcho -NotePropertyValue $echoOn
    }

    # --- parse -Category (comma separated) and intersect with config.categories ---
    $requested = @($Category -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    $invalid = @($requested | Where-Object { $_ -notin @('winget', 'pip', 'npm', 'dotfiles') })
    if ($invalid.Count -gt 0) {
        throw "Export-OfflineRepo: unknown -Category value(s): '$($invalid -join ', ')' - valid values: winget,pip,npm,dotfiles."
    }
    $enabled = @($requested | Where-Object { $config.categories.$_ })

    Write-OSyncLog -Category 'export' -Level Info -Message "export run starting (config '$ConfigPath', requested '$($requested -join ',')', enabled '$($enabled -join ',')')." -Config $config | Out-Null

    # --- nothing enabled: report and stop (no staging work at all) ---
    if ($enabled.Count -eq 0) {
        $emptyReport = [pscustomobject]@{
            schemaVersion       = 1
            tool                = 'ab-one-way-sync'
            startedAtUtc        = $startedAt
            finishedAtUtc       = [datetime]::UtcNow.ToString('o')
            configPath          = $ConfigPath
            repoRoot            = $config.repoRoot
            stagingRoot         = $config.stagingRoot
            stagingDir          = $null
            requestedCategories = $requested
            enabledCategories   = @()
            categories          = @{}
            failedCategories    = @()
            published           = $false
            success             = $true
            note                = 'no categories enabled - nothing to export'
        }
        Write-OSyncLog -Category 'export' -Level Warning -Message 'no categories enabled - nothing to export.' -Config $config | Out-Null
        return $emptyReport
    }

    # --- 2. pre-flight (Oracle m7): explicit error BEFORE any staging work ---
    $preflight = Test-OSyncExportPreflight -Config $config -Category $enabled
    if (-not $preflight.Ok) {
        throw "Export-OfflineRepo: pre-flight failed - required tool(s) not resolvable: $($preflight.Missing -join ', ')."
    }
    Write-OSyncLog -Category 'export' -Level Info -Message 'pre-flight OK (python/node/npm/winget resolvable for the enabled categories).' -Config $config | Out-Null

    # --- -SkipRuntime pre-check (fail-fast BEFORE any staging work): the
    # reuse sources must already exist in the landing zone - a previous full
    # export's runtime\ dir plus every runtime winget entry's payload under
    # winget\<Id>\ (the runtime winget entries live inside the winget
    # category dir, see RuntimeExport.ps1 step 4). ---
    $runtimeReuseEntries = @()
    $runtimeReuseRoot = $null
    if ($SkipRuntime) {
        $localExport = Get-OSyncLatestSuccessfulExport -StagingRoot $config.stagingRoot
        $candidateRoots = @()
        if (-not [string]::IsNullOrWhiteSpace($localExport)) { $candidateRoots += $localExport }
        $candidateRoots += $config.repoRoot
        $runtimeWingetListPath = Resolve-OSyncConfigPath -Config $config -Path $config.paths.runtimeWhitelist
        $runtimeReuseEntries = @(Read-OSyncWingetList -Path $runtimeWingetListPath)
        foreach ($candidateRoot in $candidateRoots) {
            $candidateRuntimeDir = Join-Path $candidateRoot 'runtime'
            if (-not (Test-Path -LiteralPath $candidateRuntimeDir -PathType Container)) { continue }
            $missingPayloads = @()
            foreach ($entry in $runtimeReuseEntries) {
                if (-not (Test-Path -LiteralPath (Join-Path $candidateRoot "winget\$($entry.Id)") -PathType Container)) {
                    $missingPayloads += $entry.Id
                }
            }
            if ($missingPayloads.Count -eq 0) {
                $runtimeReuseRoot = $candidateRoot
                break
            }
        }
        if ($null -eq $runtimeReuseRoot) {
            throw "Export-OfflineRepo: -SkipRuntime requires a previously published runtime payload in the latest successful local export or '$($config.repoRoot)'; runtime winget payload(s) missing or runtime directory absent (last candidate missing: $($missingPayloads -join ', ')) - run a full export (without -SkipRuntime) first."
        }
        Write-OSyncLog -Category 'export' -Level Info -Message "-SkipRuntime: reuse sources verified in '$runtimeReuseRoot' (runtime\ + $($runtimeReuseEntries.Count) runtime winget payload(s))." -Config $config | Out-Null
    }

    # Refresh every input manifest before any exporter reads it (including the
    # runtime tool snapshot). Failures retain the normal category isolation,
    # but the publish gate must never accept a stale-manifest fallback.
    $refreshErrors = @{}
    $refreshCategories = @($enabled | Where-Object { $_ -ne 'dotfiles' })
    if (-not $SkipRuntime) { $refreshCategories += 'runtime' }
    foreach ($refreshCategory in $refreshCategories) {
        try {
            Invoke-OSyncManifestRefresh -Config $config -Category $refreshCategory
        }
        catch {
            $refreshErrors[$refreshCategory] = "manifest refresh failed: $($_.Exception.Message)"
            Write-OSyncLog -Category 'export' -Level Error -Message "category '$refreshCategory' $($refreshErrors[$refreshCategory])" -Config $config | Out-Null
        }
    }

    # --- 3. staging dir: <stagingRoot>\<yyyyMMddTHHmmssZ> (same format/source as index exportedAtUtc) ---
    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $staging = Join-Path $config.stagingRoot $stamp
    if (Test-Path -LiteralPath $staging -PathType Container) {
        throw "Export-OfflineRepo: staging directory already exists: '$staging' (same-second re-run?)."
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Write-OSyncLog -Category 'export' -Level Info -Message "staging directory created: '$staging'." -Config $config | Out-Null

    # --- 4. per-category export (try/catch isolation: one failure never blocks the others) ---
    $categoriesReport = [ordered]@{}
    $failedCategories = New-Object System.Collections.Generic.List[string]

    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles')) {
        if ($cat -notin $enabled) { continue }
        try {
            if ($refreshErrors.ContainsKey($cat)) { throw $refreshErrors[$cat] }
            switch ($cat) {
                'winget' {
                    # config.paths.* are tool-root-relative INPUT manifests
                    # (never config.repoRoot - that is the output landing dir).
                    $listPath = Resolve-OSyncConfigPath -Config $config -Path $config.paths.wingetWhitelist
                    if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) {
                        throw "Export-OfflineRepo: winget whitelist not found: '$listPath'."
                    }
                    $parsed = @(Read-OSyncWingetList -Path $listPath)
                    $catReport = Export-OSyncWinget -ParsedList $parsed -StagingDir $staging -Config $config
                }
                'pip' {
                    $catReport = Export-OSyncPip -Config $config -StagingDir $staging
                }
                'npm' {
                    $catReport = Export-OSyncNpm -Config $config -StagingDir $staging -ConfigPath $ConfigPath
                }
                'dotfiles' {
                    $catReport = Export-OSyncDotfiles -Config $config -StagingDir $staging
                }
            }
            $categoriesReport[$cat] = [ordered]@{ status = 'ok'; report = $catReport }
            Write-OSyncLog -Category 'export' -Level Info -Message "category '$cat' export OK." -Config $config | Out-Null
        }
        catch {
            $categoriesReport[$cat] = [ordered]@{ status = 'failed'; error = $_.Exception.Message }
            $failedCategories.Add($cat)
            Write-OSyncLog -Category 'export' -Level Error -Message "category '$cat' export FAILED: $($_.Exception.Message)" -Config $config | Out-Null
        }
    }

    # runtime: the bootstrap payload - always delivered when any category is
    # enabled. -SkipRuntime skips the re-export (downloads/builds/snapshot)
    # and reuses the selected local/repo source (validated in the pre-check);
    # the reused files are re-manifested into this
    # generation, so the trust chain is unchanged. The reuse runs at the same
    # pipeline position as a real export (after the category exports), so the
    # runtime winget payloads land in <staging>\winget\<Id>\ exactly as
    # Export-OSyncRuntime would have placed them.
    try {
        if ($SkipRuntime) {
            $repoRuntimeDir = Join-Path $runtimeReuseRoot 'runtime'
            $null = Invoke-OSyncRobocopy -Source $repoRuntimeDir -Destination (Join-Path $staging 'runtime') -ExtraArgs @('/MIR')
            $reusedWingetIds = @()
            foreach ($entry in $runtimeReuseEntries) {
                $null = Invoke-OSyncRobocopy -Source (Join-Path $runtimeReuseRoot "winget\$($entry.Id)") -Destination (Join-Path $staging "winget\$($entry.Id)") -ExtraArgs @('/MIR')
                $reusedWingetIds += $entry.Id
            }
            $runtimeReport = [pscustomobject]@{
                category         = 'runtime'
                status           = 'ok'
                reused           = $true
                reusedFrom       = $runtimeReuseRoot
                runtimeWingetIds = $reusedWingetIds
            }
            Write-OSyncLog -Category 'export' -Level Info -Message "category 'runtime' export SKIPPED (-SkipRuntime): reused '$repoRuntimeDir' + $($reusedWingetIds.Count) runtime winget payload(s)." -Config $config | Out-Null
        }
        else {
            if ($refreshErrors.ContainsKey('runtime')) { throw $refreshErrors['runtime'] }
            $runtimeReport = Export-OSyncRuntime -Config $config -StagingDir $staging
            Write-OSyncLog -Category 'export' -Level Info -Message "category 'runtime' export OK." -Config $config | Out-Null
        }
        $categoriesReport['runtime'] = [ordered]@{ status = 'ok'; report = $runtimeReport }
    }
    catch {
        $categoriesReport['runtime'] = [ordered]@{ status = 'failed'; error = $_.Exception.Message }
        $failedCategories.Add('runtime')
        Write-OSyncLog -Category 'export' -Level Error -Message "category 'runtime' export FAILED: $($_.Exception.Message)" -Config $config | Out-Null
    }

    # --- 5. per-category files.json, then index.json LAST in the staging root ---
    $manifested = @()
    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
        $catDir = Join-Path $staging $cat
        if (Test-Path -LiteralPath $catDir -PathType Container) {
            $null = New-OSyncFilesManifest -Dir $catDir
            $manifested += $cat
        }
    }
    $indexFile = Publish-OSyncIndex -StagingDir $staging
    Write-OSyncLog -Category 'export' -Level Info -Message "index.json written LAST into staging root: '$($indexFile.FullName)' (manifested categories: $($manifested -join ','))." -Config $config | Out-Null

    # --- 6. integrity gate: publish only when ALL OK and no category failed ---
    $integrity = Test-OSyncRepoIntegrity -RepoRoot $staging
    Write-OSyncLog -Category 'export' -Level Info -Message "staging integrity: $($integrity.Overall)." -Config $config | Out-Null

    $publishable = ($integrity.Overall -eq 'OK') -and ($failedCategories.Count -eq 0)

    $published = $false
    $noOp = $false
    $publishedCategories = @()
    $indexCopied = $false
    $publishError = $null
    $publishPlans = [ordered]@{}
    $cleanup = [pscustomobject]@{ Kept = @(); Removed = @() }

    if (-not $publishable) {
        Write-OSyncLog -Category 'export' -Level Error -Message ("publish ABORTED - integrity={0}, failed categories=[{1}]." -f $integrity.Overall, ($failedCategories -join ',')) -Config $config | Out-Null
    }
    else {
        try {
            $publishResult = Invoke-OSyncIncrementalPublish -StagingDir $staging -RepoRoot $config.repoRoot -Config $config
            $published = $publishResult.published
            $noOp = $publishResult.noOp
            $publishedCategories = $publishResult.publishedCategories
            $indexCopied = $publishResult.indexCopied
            $publishPlans = $publishResult.plans
            $cleanup = Invoke-OSyncStagingCleanup -StagingRoot $config.stagingRoot -Keep 3
            Write-OSyncLog -Category 'export' -Level Info -Message ("staging cleanup: kept [{0}], removed [{1}]." -f ($cleanup.Kept -join ','), ($cleanup.Removed -join ',')) -Config $config | Out-Null
        }
        catch {
            $publishError = $_.Exception.Message
            $published = $false
            $noOp = $false
            Write-OSyncLog -Category 'export' -Level Error -Message "publish FAILED: $publishError; index.json was not advanced by this run." -Config $config | Out-Null
        }
    }

    # --- 8. export report JSON + log ---
    $report = [pscustomobject]@{
        schemaVersion       = 1
        tool                = 'ab-one-way-sync'
        startedAtUtc        = $startedAt
        finishedAtUtc       = [datetime]::UtcNow.ToString('o')
        configPath          = $ConfigPath
        repoRoot            = $config.repoRoot
        stagingRoot         = $config.stagingRoot
        stagingDir          = $staging
        requestedCategories = $requested
        enabledCategories   = $enabled
        categories          = $categoriesReport
        failedCategories    = @($failedCategories)
        manifestedCategories = $manifested
        indexPath           = $indexFile.FullName
        integrity           = [pscustomobject]@{
            overall    = $integrity.Overall
            categories = $integrity.Categories
        }
        published           = $published
        noOp                = $noOp
        publishedCategories = $publishedCategories
        publication         = $publishPlans
        indexCopied         = $indexCopied
        publishError        = $publishError
        cleanup             = $cleanup
        success             = ($published -or $noOp)
    }

    $reportPath = Join-Path $staging 'export-report.json'
    Write-OSyncExportReport -Report $report -Path $reportPath
    Write-OSyncLog -Category 'export' -Level $(if ($report.success) { 'Info' } else { 'Error' }) -Message ("export run finished: success={0}, published={1}, failed categories=[{2}]. Report: '{3}'." -f $report.success, $report.published, ($report.failedCategories -join ','), $reportPath) -Config $config | Out-Null

    return $report
}