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
       staging work (Oracle m7).
    3. Creates <stagingRoot>\<yyyyMMddTHHmmssZ>\ - the same ISO8601-basic
       format and source ([datetime]::UtcNow) as the index exportedAtUtc
       (Oracle r7-2).
    4. Runs Export-OSyncWinget/Pip/Npm/Dotfiles/Runtime for the enabled
       categories (runtime always runs - it is the bootstrap payload every
       category depends on - unless -SkipRuntime reuses the payloads already
       published in <repoRoot>). Each category is try/caught into the export
       report (ok/failed per package); one category's failure does NOT
       block the others.
    5. Per category New-OSyncFilesManifest, then Publish-OSyncIndex - the
       index.json is the LAST index artifact written into the staging root.
    6. Test-OSyncRepoIntegrity on the staging root: publish only when
       Overall == 'OK' AND no category failed; otherwise abort with the
       report (Metis B2).
    7. Publish: per category Invoke-OSyncRobocopy <staging>\<cat>
       <repoRoot>\<cat> /MIR, then LAST Copy-Item index.json <repoRoot>\
       (Metis B2: the ordering is a local guarantee only; out-of-order
       transfer is caught by the B-side integrity check).
    8. Export report JSON + logging.
    9. After a successful publish, clean <stagingRoot> keeping only the
       newest 3 generations (Momus M4 - disk exhaustion guard). The
       A-side-only tool dir .verdaccio-a is never a generation and is
       never touched.

  Returns a SINGLE report object (Success = $true only when the full
  export -> integrity -> publish chain succeeded). Every Write-OSyncLog
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

function Invoke-OSyncExport {
    <#
    .SYNOPSIS
        Runs the full A-side export pipeline: per-category export into a
        fresh <stagingRoot>\<yyyyMMddTHHmmssZ>\ generation, files.json +
        index.json, integrity gate, publish to <repoRoot>, staging cleanup.
        Returns the export report object (Success = $true only on a fully
        published run).
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
        # winget downloads, portable Verdaccio build, tool snapshot) and
        # REUSES the payloads already published in <repoRoot> instead:
        # runtime\ is mirrored into the staging generation and each runtime
        # winget entry's <repoRoot>\winget\<Id>\ payload is copied into
        # <staging>\winget\<Id>\. The reused files are re-manifested into
        # this generation, so the trust chain (index -> files.json -> per-
        # file sha256) is unchanged. Requires a previous full export - the
        # pre-check fails fast when the reuse sources are absent.
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
    if ($SkipRuntime) {
        $repoRuntimeDir = Join-Path $config.repoRoot 'runtime'
        if (-not (Test-Path -LiteralPath $repoRuntimeDir -PathType Container)) {
            throw "Export-OfflineRepo: -SkipRuntime requires a previously published runtime payload at '$repoRuntimeDir' - run a full export (without -SkipRuntime) first."
        }
        $runtimeWingetListPath = Resolve-OSyncConfigPath -Config $config -Path $config.paths.runtimeWhitelist
        $runtimeReuseEntries = @(Read-OSyncWingetList -Path $runtimeWingetListPath)
        $missingPayloads = @()
        foreach ($entry in $runtimeReuseEntries) {
            if (-not (Test-Path -LiteralPath (Join-Path $config.repoRoot "winget\$($entry.Id)") -PathType Container)) {
                $missingPayloads += $entry.Id
            }
        }
        if ($missingPayloads.Count -gt 0) {
            throw "Export-OfflineRepo: -SkipRuntime: runtime winget payload(s) missing from '$($config.repoRoot)\winget': $($missingPayloads -join ', ') - run a full export (without -SkipRuntime) first."
        }
        Write-OSyncLog -Category 'export' -Level Info -Message "-SkipRuntime: reuse sources verified in '$($config.repoRoot)' (runtime\ + $($runtimeReuseEntries.Count) runtime winget payload(s))." -Config $config | Out-Null
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
    # and REUSES the payloads already published in <repoRoot> (validated in
    # the pre-check above); the reused files are re-manifested into this
    # generation, so the trust chain is unchanged. The reuse runs at the same
    # pipeline position as a real export (after the category exports), so the
    # runtime winget payloads land in <staging>\winget\<Id>\ exactly as
    # Export-OSyncRuntime would have placed them.
    try {
        if ($SkipRuntime) {
            $repoRuntimeDir = Join-Path $config.repoRoot 'runtime'
            $null = Invoke-OSyncRobocopy -Source $repoRuntimeDir -Destination (Join-Path $staging 'runtime') -ExtraArgs @('/MIR')
            $reusedWingetIds = @()
            foreach ($entry in $runtimeReuseEntries) {
                $null = Invoke-OSyncRobocopy -Source (Join-Path $config.repoRoot "winget\$($entry.Id)") -Destination (Join-Path $staging "winget\$($entry.Id)") -ExtraArgs @('/MIR')
                $reusedWingetIds += $entry.Id
            }
            $runtimeReport = [pscustomobject]@{
                category         = 'runtime'
                status           = 'ok'
                reused           = $true
                reusedFrom       = $config.repoRoot
                runtimeWingetIds = $reusedWingetIds
            }
            Write-OSyncLog -Category 'export' -Level Info -Message "category 'runtime' export SKIPPED (-SkipRuntime): reused '$repoRuntimeDir' + $($reusedWingetIds.Count) runtime winget payload(s) from the landing zone." -Config $config | Out-Null
        }
        else {
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
    $publishedCategories = @()
    $indexCopied = $false
    $publishError = $null
    $cleanup = [pscustomobject]@{ Kept = @(); Removed = @() }

    if (-not $publishable) {
        Write-OSyncLog -Category 'export' -Level Error -Message ("publish ABORTED - integrity={0}, failed categories=[{1}]." -f $integrity.Overall, ($failedCategories -join ',')) -Config $config | Out-Null
    }
    else {
        # --- 7. publish: per category /MIR, then index.json LAST (Metis B2) ---
        try {
            New-Item -ItemType Directory -Path $config.repoRoot -Force | Out-Null
            foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
                $catDir = Join-Path $staging $cat
                if (-not (Test-Path -LiteralPath $catDir -PathType Container)) { continue }
                $null = Invoke-OSyncRobocopy -Source $catDir -Destination (Join-Path $config.repoRoot $cat) -ExtraArgs @('/MIR')
                $publishedCategories += $cat
                Write-OSyncLog -Category 'export' -Level Info -Message "published category '$cat' -> '$($config.repoRoot)\$cat'." -Config $config | Out-Null
            }
            Copy-Item -LiteralPath $indexFile.FullName -Destination (Join-Path $config.repoRoot 'index.json') -Force
            $indexCopied = $true
            $published = $true
            Write-OSyncLog -Category 'export' -Level Info -Message "index.json copied LAST to '$($config.repoRoot)\index.json'." -Config $config | Out-Null

            # --- 9. cleanup: keep only the newest 3 generations (Momus M4) ---
            $cleanup = Invoke-OSyncStagingCleanup -StagingRoot $config.stagingRoot -Keep 3
            Write-OSyncLog -Category 'export' -Level Info -Message ("staging cleanup: kept [{0}], removed [{1}]." -f ($cleanup.Kept -join ','), ($cleanup.Removed -join ',')) -Config $config | Out-Null
        }
        catch {
            $publishError = $_.Exception.Message
            $published = $false
            Write-OSyncLog -Category 'export' -Level Error -Message "publish FAILED: $publishError" -Config $config | Out-Null
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
        publishedCategories = $publishedCategories
        indexCopied         = $indexCopied
        publishError        = $publishError
        cleanup             = $cleanup
        success             = $published
    }

    $reportPath = Join-Path $staging 'export-report.json'
    Write-OSyncExportReport -Report $report -Path $reportPath
    Write-OSyncLog -Category 'export' -Level $(if ($report.success) { 'Info' } else { 'Error' }) -Message ("export run finished: success={0}, published={1}, failed categories=[{2}]. Report: '{3}'." -f $report.success, $report.published, ($report.failedCategories -join ','), $reportPath) -Config $config | Out-Null

    return $report
}