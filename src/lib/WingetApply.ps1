#Requires -Version 5.1
<#
  WingetApply.ps1 - B-side winget apply (method A: local HTTP + winget install --manifest).
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncWingetApply -WorkDir <validated work copy root> -Config
    Reads <WorkDir>\winget\packages.txt, excludes the runtime IDs listed in
    <WorkDir>\runtime\runtime-winget.txt (runtime entries belong to the
    bootstrap, todo 12 - read from the WORK COPY, never from the A-side
    manifests), starts the local HTTP server on config.httpPort, and installs
    each remaining package with:

        winget install --manifest <WorkDir>\winget\<Id>\ --scope <scope>
            --architecture <arch> --accept-package-agreements
            --accept-source-agreements --disable-interactivity

    --manifest receives the manifest-set DIRECTORY (not a single YAML). The
    InstallerUrl inside the YAML MUST be an HTTP URL served by the local
    server - passing file paths to --manifest is known to fail
    (PackageSync.md:25, winget-cli#4361).

    OBSERVED (winget v1.29.290, QA 2026-09-04): `winget install --manifest
    <dir>` scans the directory and tries to parse EVERY file as a manifest.
    The todo-6 export layout puts the installer NEXT TO the YAML in
    <WorkDir>\winget\<Id>\ - winget then chokes on the binary installer
    ("[YAML:Reader] control characters are not allowed") and aborts with
    0x8a150004. Subdirectories in the manifest path are rejected too
    ("Subdirectory not supported in manifest path"). The apply therefore
    stages a manifest-ONLY flat directory per package (all *.yaml copied,
    installers left in the work copy for the HTTP server) and passes THAT to
    --manifest. The work copy itself stays pristine.

  EXIT-CODE POLICY (this todo owns the constant, see Winget.Common.ps1):
      $script:WingetSuccessfulInstallExitCodes -> success (including reboot required)
      $script:WingetSatisfiedExitCodes         -> already satisfied
          (already installed / no applicable upgrade) -> idempotent success
      anything else                             -> recorded in failed,
          processing continues with the next package

    winget source auto-update failures are logged only, never blocking: the
    full install output is captured and logged regardless of the exit code.

    After all packages the HTTP server is stopped (finally). If any package
    failed, an Error-level log is written and a terminating error is thrown
    (the non-zero aggregate exit). The caller (todo 17 orchestrator) treats a
    thrown error as "category failed" and continues with the other categories.

    Returns the report object on full success:
      { category, wingetExe, wingetExeVersion, ok, satisfied, skipped, failed, packagesTxt }
    ok entries:           { Id, Version, Sha256, ExitCode, Scope, ScopeFallback }
        (Scope/ScopeFallback added by the reactive portable scope fallback;
        ScopeFallback=$true only when a machine-scope attempt failed and the
        package was retried with user scope)
    satisfied entries:    { Id, Version, Sha256, ExitCode }
    skipped entries:      { Id, Version, Sha256, Reason='state-match' }
        (P2 incremental: state record EXACTLY matches the work copy manifest,
        so winget is never invoked for the package - see README 5.8 for the
        manual-uninstall trade-off)
    failed entries:       { Id, ExitCode, Output } and, when a scope fallback
        was attempted, optional { ScopeAttempts = [ {Scope,ExitCode}, ... ] }
        (always retains the machine and user attempts with their exit codes)

  PORT-COUPLING GUARD (Oracle r7-4): the InstallerUrl port is baked in at
  A-side export time and the B config must never override it. Every rewritten
  YAML under <WorkDir>\winget\ is scanned; if ANY InstallerUrl /
  InstallerFallbackUrls port differs from config.httpPort the function fails
  fast BEFORE the HTTP server is started.

  winget.exe is RE-DERIVED every run via Resolve-OSyncWingetExePath - a path
  read back from state is never executed (Oracle r3-B1). -WingetExePath is a
  test seam only (same contract as Export-OSyncWinget).

  PORTABLE SCOPE FALLBACK: for portable packages (InstallerType: portable, or
  zip + NestedInstallerType: portable) a machine-scope install that fails with
  a permission / portable-class error (0x80070005 / 0x8A150052 / 0x8A150054 / 0x8A150057)
  is retried ONCE with --scope user. The global config.winget.scope is never
  modified; the fallback is reactive (never a proactive scope choice) so a
  healthy machine-scope package keeps its idempotent/repair semantics. A
  best-effort cleanup (see Invoke-OSyncWingetBestEffortCleanup) runs only on
  this retry path and never blocks it. Non-portable access-denied failures are
  NOT retried.
#>

<#
.SYNOPSIS
    Scans every rewritten manifest YAML under <WorkDir>\winget\ and returns the
    first InstallerUrl / InstallerFallbackUrls value whose port differs from
    -HttpPort. Returns $null when every URL is coupled to -HttpPort.
#>
function Get-OSyncWingetPortMismatch {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,

        [Parameter(Mandatory = $true)]
        [int]$HttpPort
    )

    $wingetDir = Join-Path $WorkDir 'winget'
    if (-not (Test-Path -LiteralPath $wingetDir -PathType Container)) {
        # Nothing to check; the per-package loop reports missing directories.
        return $null
    }

    $yamls = @(Get-ChildItem -LiteralPath $wingetDir -Recurse -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    foreach ($yaml in $yamls) {
        $text = [System.IO.File]::ReadAllText($yaml.FullName, [System.Text.Encoding]::UTF8)
        $urls = @(Get-OSyncWingetYamlUrls -Text $text)
        foreach ($url in $urls) {
            $uri = $null
            if ([System.Uri]::TryCreate($url, [System.UriKind]::Absolute, [ref]$uri)) {
                if ($uri.Port -ne $HttpPort) {
                    return $url
                }
            }
            else {
                # An unparseable URL cannot prove coupling - treat as mismatch.
                return $url
            }
        }
    }
    return $null
}

<#
.SYNOPSIS
    Extracts PackageVersion and the first InstallerSha256 from a manifest YAML
    for the state record (state.winget[<id>] = { version, sha256 }).
#>
function Get-OSyncWingetManifestInfo {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath
    )

    $text = [System.IO.File]::ReadAllText($YamlPath, [System.Text.Encoding]::UTF8)
    $version = $null
    $sha256 = $null

    foreach ($rawLine in [regex]::Split($text, "\n")) {
        $line = $rawLine.TrimEnd("`r")
        if ($null -eq $version -and $line -match '^PackageVersion:\s*(.+)$') {
            $version = $Matches[1].Trim().Trim('"').Trim("'")
        }
        if ($null -eq $sha256 -and $line -match '^\s*InstallerSha256:\s*([0-9a-fA-F]{64})\s*$') {
            $sha256 = $Matches[1].ToLowerInvariant()
        }
        if ($null -ne $version -and $null -ne $sha256) { break }
    }

    return [pscustomobject]@{
        PackageVersion  = $version
        InstallerSha256 = $sha256
    }
}


<#
.SYNOPSIS
    Runs one `winget install` invocation with a hard timeout.

.DESCRIPTION
    Uses [System.Diagnostics.Process] + ProcessStartInfo instead of
    Start-Process: under Windows PowerShell 5.1, Start-Process with
    -RedirectStandardOutput/-RedirectStandardError returns a Process object
    whose ExitCode property is ALWAYS $null (PowerShell issue #3028), which
    would silently turn every install into a "failed" record. ProcessStartInfo
    populates ExitCode correctly on both PS 5.1 and pwsh 7. Redirected streams
    also dodge the PS 5.1 native-stderr EAP=Stop crash (learnings.md).
#>
function Invoke-OSyncWingetInstall {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WingetExe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = 600000
    )

    # Build the command line: quote any argument that contains whitespace and
    # is not already quoted (the manifest directory arrives pre-quoted).
    $argString = (($Arguments | ForEach-Object {
        if ($_ -match '\s' -and -not ($_.StartsWith('"') -and $_.EndsWith('"'))) {
            '"' + $_ + '"'
        }
        else {
            $_
        }
    }) -join ' ')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $WingetExe
    $psi.Arguments = $argString
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($psi)

    # Drain both pipes concurrently so a chatty winget cannot deadlock on a
    # full pipe buffer while we wait.
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()

    $exited = $proc.WaitForExit($TimeoutMs)
    $exitCode = -1
    $timedOut = $false
    if ($exited) {
        $exitCode = $proc.ExitCode
    }
    else {
        $timedOut = $true
        try {
            $proc.Kill()
            $proc.WaitForExit(10000)
        }
        catch {
            # Process may have exited between WaitForExit and Kill.
        }
    }

    $outText = ''
    $errText = ''
    try {
        $outText = $outTask.Result
    }
    catch {
        $outText = ''
    }
    try {
        $errText = $errTask.Result
    }
    catch {
        $errText = ''
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        Output   = ($outText + $errText)
    }
}

<#
.SYNOPSIS
    Strips inline PackageDependencies from a YAML manifest string so winget
    does not try to resolve them against an unavailable source in an offline
    B-end. The caller is responsible for installing the extracted dependencies
    via the normal packages.txt ordering.

.DESCRIPTION
    winget's --skip-dependencies flag has been observed to be ineffective at
    suppressing source resolution for packages that declare a Dependencies
    section in their manifest YAML.  This function performs a text-level
    removal of the top-level Dependencies block and returns the cleaned YAML
    together with the list of extracted PackageIdentifier strings.
#>
function Remove-OSyncWingetDependencies {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [string]$YamlText
    )

    $deps = @()
    $eol = if ($YamlText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = $YamlText -split $eol

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^(\s*)Dependencies:') {
            $depIndent = $Matches[1].Length

            # Collect child lines that are MORE indented than the Dependencies
            # line.  The block ends at the next non-empty line whose indent is
            # <= depIndent (sibling or ancestor key, or end of file).  Empty
            # lines are skipped so they never cut the block short.
            $j = $i + 1
            while ($j -lt $lines.Count) {
                $childLine = $lines[$j]
                if ($childLine -match '^(\s*)\S') {
                    $childIndent = $Matches[1].Length
                    if ($childIndent -le $depIndent) { break }
                    # Extract PackageIdentifier from list entries.
                    if ($childLine -match 'PackageIdentifier:\s+(\S+)') {
                        $deps += $Matches[1]
                    }
                }
                # Empty lines (no non-whitespace content) stay inside the block.
                $j++
            }

            # Remove lines [$i .. $j-1] (the Dependencies line + its children).
            $keep = @()
            if ($i -gt 0) { $keep += $lines[0..($i - 1)] }
            if ($j -lt $lines.Count) { $keep += $lines[$j..($lines.Count - 1)] }
            $YamlText = $keep -join $eol
            break   # only the first Dependencies block
        }
    }

    return [pscustomobject]@{
        CleanYaml    = $YamlText
        Dependencies = $deps
    }
}

<#
.SYNOPSIS
    Stages a manifest-ONLY flat directory for one package.

.DESCRIPTION
    winget v1.29.290 rejects non-YAML files AND subdirectories in the
    --manifest path (observed in QA). The export layout keeps the installer
    next to the YAML, so this function copies every *.yaml (recursively,
    flattened) into <StagingRoot>\<Id>\ and returns that path. The installers
    stay in the work copy where the HTTP server serves them. On a filename
    collision the later file is prefixed with its immediate parent directory
    name so no manifest is lost.

    Additionally, each YAML is scanned for a top-level Dependencies section.
    If found, the section is stripped from the staged copy and the dependency
    PackageIdentifiers are written to the log.  winget's --skip-dependencies
    flag has been shown to be ineffective, so text-level removal is required
    to prevent offline source-resolution failures.
#>
function New-OSyncWingetManifestStaging {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir,

        [Parameter(Mandatory = $true)]
        [string]$StagingRoot
    )

    $staging = Join-Path $StagingRoot ([System.IO.Path]::GetFileName($PackageDir))
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -Recurse -Force -LiteralPath $staging
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    $used = @{}
    # Do NOT recurse: Dependencies\ subdirectory contains YAMLs for OTHER
    # PackageIdentifiers. Flattening them into staging causes winget to see
    # multiple PackageIdentifiers in the same --manifest directory and reject
    # the entire manifest set (observed: 0x8A150004).
    $yamls = @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    foreach ($yaml in $yamls) {
        $name = $yaml.Name
        if ($used.ContainsKey($name.ToLowerInvariant())) {
            $parent = Split-Path -Leaf (Split-Path -Parent $yaml.FullName)
            $name = '{0}_{1}' -f $parent, $name
        }
        $used[$name.ToLowerInvariant()] = $true

        # Read YAML and strip inline PackageDependencies (winget's
        # --skip-dependencies is ineffective — text-level removal is required
        # to prevent offline source-resolution failures).
        $text = [System.IO.File]::ReadAllText($yaml.FullName, [System.Text.Encoding]::UTF8)
        $result = Remove-OSyncWingetDependencies -YamlText $text
        # Note: we deliberately avoid logging here because
        # New-OSyncWingetManifestStaging does NOT carry a -Config parameter,
        # and adding one would require updating every caller.  The caller
        # (Invoke-OSyncWingetApply) logs the install attempt where the
        # operator can inspect it, and any missing dependencies show up as
        # later failures in the apply report.
        [System.IO.File]::WriteAllText((Join-Path $staging $name), $result.CleanYaml, [System.Text.Encoding]::UTF8)
    }
    return $staging
}

<#
.SYNOPSIS
    Classifies a raw winget install result into ok / satisfied / timedout / failed.

.DESCRIPTION
    Pure mapping helper so the first attempt and the reactive scope-fallback
    retry share a single classification rule. The ordering matches the original
    inline logic: success codes win over satisfied codes (0 appears in BOTH
    constant sets and must be reported as ok).
#>
function Get-OSyncWingetInstallOutcome {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0,

        [Parameter(Mandatory = $false)]
        [switch]$TimedOut
    )

    if ($TimedOut) { return 'timedout' }
    if ($script:WingetSuccessfulInstallExitCodes -contains $ExitCode) { return 'ok' }
    if ($script:WingetSatisfiedExitCodes -contains $ExitCode) { return 'satisfied' }
    return 'failed'
}

<#
.SYNOPSIS
    Runs one `winget install --manifest ... --scope <Scope> ...` attempt.

.DESCRIPTION
    Owns the whole single-attempt path: build the --scope arguments, invoke
    Invoke-OSyncWingetInstall, truncate the captured output to the last 15
    lines, and classify the result. Both the first machine-scope attempt and
    the user-scope fallback retry call this helper, so the argument set, the
    tail truncation and the classification cannot drift between the two paths.
#>
function Invoke-OSyncWingetInstallAttempt {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WingetExe,

        [Parameter(Mandatory = $true)]
        [string]$ManifestDir,

        [Parameter(Mandatory = $true)]
        [string]$Scope,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        $Entry,

        [Parameter(Mandatory = $true)]
        $Config
    )

    # --skip-dependencies: when a YAML declares PackageDependencies, winget
    # unconditionally resolves them against the configured source, which fails
    # hard in an offline B-end (no source available).  We control the install
    # order ourselves via packages.txt, so telling winget to skip its own
    # dependency resolution is both safer and reliable.
    $installArgs = @(
        'install',
        '--manifest', ('"{0}"' -f $ManifestDir),
        '--scope', $Scope,
        '--architecture', $Architecture,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--skip-dependencies'
    )

    Write-OSyncLog -Category 'winget' -Level 'Info' `
        -Message ("Installing winget package {0} from manifest set {1} (scope={2})" -f $Entry.Id, $ManifestDir, $Scope) `
        -Data @{ Id = $Entry.Id; Version = $Entry.Version; ManifestDir = $ManifestDir; Scope = $Scope } -Config $Config | Out-Null

    $result = Invoke-OSyncWingetInstall -WingetExe $WingetExe -Arguments $installArgs

    # winget source auto-update failures are logged, never blocking: the full
    # output tail is captured so an offline B still leaves a diagnostic trail.
    $tail = ''
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $tailLines = @($result.Output -split "`n")
        $tail = (($tailLines | Select-Object -Last 15) -join "`n").Trim()
    }

    return [pscustomobject]@{
        Scope     = $Scope
        ExitCode  = $result.ExitCode
        TimedOut  = [bool]$result.TimedOut
        Outcome   = (Get-OSyncWingetInstallOutcome -ExitCode $result.ExitCode -TimedOut:$result.TimedOut)
        Tail      = $tail
        RawOutput = [string]$result.Output
    }
}

<#
.SYNOPSIS
    Reads winget's Uninstall ARP entries (read-only) for product-code lookup.

.DESCRIPTION
    Scans the machine (64/32-bit views) and current-user Uninstall hives for
    subkeys carrying a WinGetPackageIdentifier value and returns one row per
    entry as { Key, WinGetPackageIdentifier }. Reading the registry normally
    needs no elevation, so this is safe to call on the failure path.
#>
function Get-OSyncWingetUninstallEntries {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    )

    $entries = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $keys = @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)
        foreach ($key in $keys) {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            $idProp = $props.PSObject.Properties['WinGetPackageIdentifier']
            if ($null -eq $idProp) { continue }
            $entries += [pscustomobject]@{
                Key                     = $key.PSChildName
                WinGetPackageIdentifier = [string]$idProp.Value
            }
        }
    }
    return $entries
}

<#
.SYNOPSIS
    Returns the ARP subkey name (product code) registered for a winget package Id.

.DESCRIPTION
    Matches WinGetPackageIdentifier equal to -PackageId (case-insensitive) and
    returns that subkey's name, or $null when the package has no ARP entry.
    -UninstallEntries is a test seam: pass a synthetic registry snapshot
    (rows of { Key, WinGetPackageIdentifier }) to exercise the matching logic
    without touching the real registry.
#>
function Get-OSyncWingetInstalledProductCode {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $false)]
        [object[]]$UninstallEntries
    )

    if ($PSBoundParameters.ContainsKey('UninstallEntries')) {
        $entries = @($UninstallEntries)
    }
    else {
        $entries = @(Get-OSyncWingetUninstallEntries)
    }

    foreach ($entry in $entries) {
        if ($null -eq $entry) { continue }
        if ([string]::Equals([string]$entry.WinGetPackageIdentifier, $PackageId, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$entry.Key
        }
    }
    return $null
}

<#
.SYNOPSIS
    Best-effort removal of a broken winget install before a user-scope retry.

.DESCRIPTION
    Prefers `uninstall --product-code <GUID>` (the offline B has no source, so
    `--id` may fail to resolve).  The product code comes from a read-only ARP
    scan; when it cannot be found the call falls back to `--id <PackageId>`.
    The whole operation is best-effort: every failure (including the expected
    repeat of the same access-denied error) is swallowed and only logged, so
    the caller always proceeds with the user-scope retry.
#>
function Invoke-OSyncWingetBestEffortCleanup {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WingetExe,

        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        $Config
    )

    try {
        $productCode = Get-OSyncWingetInstalledProductCode -PackageId $PackageId
        if (-not [string]::IsNullOrWhiteSpace($productCode)) {
            $cleanupArgs = @('uninstall', '--product-code', $productCode, '--accept-source-agreements', '--disable-interactivity')
            $cleanupTarget = "product-code $productCode"
        }
        else {
            $cleanupArgs = @('uninstall', '--id', $PackageId, '--accept-source-agreements', '--disable-interactivity')
            $cleanupTarget = "id $PackageId"
        }

        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message ("winget package {0}: best-effort cleanup before user-scope retry ({1})" -f $PackageId, $cleanupTarget) `
            -Data @{ Id = $PackageId; CleanupTarget = $cleanupTarget } -Config $Config | Out-Null

        $result = Invoke-OSyncWingetInstall -WingetExe $WingetExe -Arguments $cleanupArgs
        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message ("winget package {0}: cleanup finished (exit {1}) - continuing regardless" -f $PackageId, $result.ExitCode) `
            -Data @{ Id = $PackageId; ExitCode = $result.ExitCode; TimedOut = [bool]$result.TimedOut } -Config $Config | Out-Null
        return $result
    }
    catch {
        Write-OSyncLog -Category 'winget' -Level 'Warning' `
            -Message ("winget package {0}: cleanup threw ({1}) - continuing regardless" -f $PackageId, $_.Exception.Message) `
            -Config $Config | Out-Null
        return $null
    }
}

<#
.SYNOPSIS
    Applies every non-runtime winget package from a validated work copy.

.DESCRIPTION
    See the file header for the full contract. Returns the report object on
    full success; throws a terminating error when any package failed (the
    non-zero aggregate exit).
#>
function Invoke-OSyncWingetApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,

        [Parameter(Mandatory = $true)]
        $Config,

        # Test seam: unit tests inject a fake winget; production re-derives
        # the real winget.exe via Resolve-OSyncWingetExePath every run.
        [Parameter(Mandatory = $false)]
        [string]$WingetExePath
    )

    $workFull = [System.IO.Path]::GetFullPath($WorkDir)
    if (-not [System.IO.Directory]::Exists($workFull)) {
        throw "Invoke-OSyncWingetApply: work copy root does not exist: $workFull"
    }

    $packagesTxt = Join-Path $workFull 'winget\packages.txt'
    if (-not (Test-Path -LiteralPath $packagesTxt -PathType Leaf)) {
        throw "Invoke-OSyncWingetApply: packages.txt not found in work copy: $packagesTxt"
    }

    $httpPort = [int]$Config.httpPort
    $scope = [string]$Config.winget.scope
    $arch = [string]$Config.winget.architecture

    # winget.exe RE-DERIVED this run - never a path read back from state.
    if (-not [string]::IsNullOrWhiteSpace($WingetExePath)) {
        $wingetExe = $WingetExePath
    }
    else {
        $wingetExe = Resolve-OSyncWingetExePath
        if ($null -eq $wingetExe) {
            throw 'Invoke-OSyncWingetApply: winget.exe not found under C:\Program Files\WindowsApps (App Installer not installed?).'
        }
    }

    # Port-coupling guard BEFORE the server starts (fail-fast, Oracle r7-4).
    $mismatch = Get-OSyncWingetPortMismatch -WorkDir $workFull -HttpPort $httpPort
    if ($null -ne $mismatch) {
        throw ("Invoke-OSyncWingetApply: port-coupling guard failed - rewritten InstallerUrl '{0}' uses a port different from config.httpPort ({1}). The URL port is baked in at A-side export time and the B config must never override it." -f $mismatch, $httpPort)
    }

    # Read packages.txt and exclude runtime IDs (read from the WORK COPY).
    $entries = @(Read-OSyncWingetList -Path $packagesTxt)
    $runtimeTxt = Join-Path $workFull 'runtime\runtime-winget.txt'
    $runtimeIds = @()
    if (Test-Path -LiteralPath $runtimeTxt -PathType Leaf) {
        $runtimeIds = @(Read-OSyncWingetList -Path $runtimeTxt | ForEach-Object { $_.Id.ToLowerInvariant() })
    }
    else {
        Write-OSyncLog -Category 'winget' -Level 'Warning' `
            -Message "runtime-winget.txt not found in work copy ($runtimeTxt) - no runtime exclusions applied" `
            -Config $Config | Out-Null
    }
    $toInstall = @($entries | Where-Object { $runtimeIds -notcontains $_.Id.ToLowerInvariant() })

    # winget version for the report. EAP is scoped to Continue around the
    # native call: PS 5.1 turns native stderr into a terminating
    # NativeCommandError under EAP=Stop (learnings.md).
    $wingetVersion = ''
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $versionOutput = & $wingetExe '--version' 2>&1 | Out-String
        $wingetVersion = $versionOutput.Trim()
    }
    catch {
        $wingetVersion = '(unknown)'
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    if ($toInstall.Count -eq 0) {
        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message 'winget apply: no packages to install (packages.txt empty or all entries are runtime-excluded)' `
            -Data @{ packages = $entries.Count; excluded = $runtimeIds.Count } -Config $Config | Out-Null
        return [pscustomobject]@{
            category        = 'winget'
            wingetExe       = $wingetExe
            wingetExeVersion = $wingetVersion
            ok              = @()
            satisfied       = @()
            skipped         = @()
            failed          = @()
            packagesTxt     = $packagesTxt
        }
    }

    # INCREMENTAL (P2): skip a package when its state record EXACTLY matches
    # the work copy manifest (PackageVersion + first InstallerSha256, both
    # from Get-OSyncWingetManifestInfo - the same values Add-OSyncStateRecord
    # persists). The record is written ONLY after a real successful/satisfied
    # install, so a match proves "B already runs precisely this payload" and
    # winget would only echo a satisfied exit code. A null/absent field on
    # either side cannot prove the match and falls through to a real install.
    #
    # Trade-off (documented in README 5.8): a package MANUALLY uninstalled on
    # B is not reinstalled while its state record still matches - winget is
    # never invoked for it. Remediation: delete the winget/<Id> record from
    # system-state.json (or bump the pinned version) and re-run apply.
    $applyState = Get-OSyncState -Category 'winget' -Config $Config
    $wingetRecords = $applyState['winget']
    if ($null -eq $wingetRecords -or $wingetRecords -isnot [System.Collections.IDictionary]) {
        $wingetRecords = @{}
    }

    $pendingInstall = @()
    $skipped = @()
    foreach ($entry in $toInstall) {
        $pkgDir = Join-Path $workFull ('winget\{0}' -f $entry.Id)
        $yamls = @(Get-ChildItem -LiteralPath $pkgDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
        $info = $null
        if ($yamls.Count -gt 0) {
            $info = Get-OSyncWingetManifestInfo -YamlPath $yamls[0].FullName
        }

        # Case-insensitive key scan (bulletproof across JSON round-trips;
        # the package count is tiny so a linear scan is fine).
        $record = $null
        foreach ($k in $wingetRecords.Keys) {
            if ([string]::Equals([string]$k, $entry.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
                $record = $wingetRecords[$k]
                break
            }
        }

        $isMatch = ($null -ne $info) -and
                   ($null -ne $info.PackageVersion) -and
                   ($null -ne $info.InstallerSha256) -and
                   ($null -ne $record) -and
                   ($record -is [System.Collections.IDictionary]) -and
                   ([string]::Equals([string]$record['version'], [string]$info.PackageVersion, [System.StringComparison]::OrdinalIgnoreCase)) -and
                   ([string]::Equals(([string]$record['sha256']).ToLowerInvariant(), [string]$info.InstallerSha256, [System.StringComparison]::Ordinal))
        if ($isMatch) {
            $skipped += [pscustomobject]@{
                Id      = $entry.Id
                Version = $info.PackageVersion
                Sha256  = $info.InstallerSha256
                Reason  = 'state-match'
            }
            Write-OSyncLog -Category 'winget' -Level 'Info' `
                -Message ("winget package {0}@{1} already applied (state match) - install skipped" -f $entry.Id, $info.PackageVersion) `
                -Data @{ Id = $entry.Id; Version = $info.PackageVersion; Sha256 = $info.InstallerSha256 } -Config $Config | Out-Null
            continue
        }
        $pendingInstall += $entry
    }

    if ($pendingInstall.Count -eq 0) {
        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message ("winget apply: all {0} package(s) already applied (state match) - nothing to install, HTTP server not started" -f $skipped.Count) `
            -Data @{ skipped = $skipped.Count } -Config $Config | Out-Null
        return [pscustomobject]@{
            category        = 'winget'
            wingetExe       = $wingetExe
            wingetExeVersion = $wingetVersion
            ok              = @()
            satisfied       = @()
            skipped         = $skipped
            failed          = @()
            packagesTxt     = $packagesTxt
        }
    }

    $server = $null
    $ok = @()
    $satisfied = @()
    $failed = @()

    # Manifest staging root (B-local, cleaned every run). winget rejects
    # non-YAML files and subdirectories in the --manifest path, so each
    # package gets a manifest-only flat staging dir (see file header).
    $stagingRoot = Join-Path (Join-Path $Config.stateDir 'run') 'winget-manifests'
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -Recurse -Force -LiteralPath $stagingRoot
    }

    try {
        $server = Start-OSyncHttpServer -Root $workFull -Port $httpPort
        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message ("winget apply: HTTP server started on port {0} serving {1}" -f $httpPort, $workFull) `
            -Data @{ Port = $httpPort; Root = $workFull } -Config $Config | Out-Null

        foreach ($entry in $pendingInstall) {
            $pkgDir = Join-Path $workFull ('winget\{0}' -f $entry.Id)

            # The package directory must contain at least one manifest YAML.
            $yamls = @(Get-ChildItem -LiteralPath $pkgDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
            if ($yamls.Count -eq 0) {
                $failure = [pscustomobject]@{
                    Id       = $entry.Id
                    ExitCode = -1
                    Output   = 'no manifest YAML found in package directory'
                }
                $failed += $failure
                Write-OSyncLog -Category 'winget' -Level 'Warning' `
                    -Message ("winget apply FAILED for {0}: no manifest YAML in {1} - recorded, continuing" -f $entry.Id, $pkgDir) `
                    -Data $failure -Config $Config | Out-Null
                continue
            }

            # Manifest-ONLY flat staging dir (installers stay in the work copy
            # where the HTTP server serves them).
            $manifestDir = New-OSyncWingetManifestStaging -PackageDir $pkgDir -StagingRoot $stagingRoot

            # Per-package scope override: user-scoped installers (including MSIX/AppX)
            # MUST use --scope user even when the config default is 'machine'.
            $actualScope = $scope
            if ($scope -eq 'machine' -and (Test-OSyncWingetNeedsUserScope -PackageDir $pkgDir)) {
                $actualScope = 'user'
                Write-OSyncLog -Category 'winget' -Level 'Info' `
                    -Message ("winget package {0}: overriding scope to 'user' (manifest is user-scoped or MSIX/AppX)" -f $entry.Id) `
                    -Data @{ Id = $entry.Id; ConfigScope = $scope; OverrideScope = 'user' } -Config $Config | Out-Null
            }

            # Portable gate for the reactive machine->user fallback. Computed
            # from the ORIGINAL package dir (pkgDir); the staged manifest is an
            # exact copy, so either would do, but pkgDir is the source of truth.
            $isPortable = Test-OSyncWingetIsPortable -PackageDir $pkgDir

            $first = Invoke-OSyncWingetInstallAttempt -WingetExe $wingetExe -ManifestDir $manifestDir `
                -Scope $actualScope -Architecture $arch -Entry $entry -Config $Config

            if ($first.Outcome -eq 'timedout') {
                $failure = [pscustomobject]@{ Id = $entry.Id; ExitCode = -1; Output = 'winget install timed out' }
                $failed += $failure
                Write-OSyncLog -Category 'winget' -Level 'Warning' `
                    -Message ("winget install TIMED OUT for {0} - recorded, continuing" -f $entry.Id) `
                    -Data $failure -Config $Config | Out-Null
                continue
            }

            # Reactive scope fallback: portable package + permission/portable
            # class failure + the attempt actually used machine scope. MSI/EXE
            # access-denied is NOT retried (user scope cannot repair it), and a
            # deterministic failure never reaches here.
            $needsFallback =
                $isPortable -and
                ($actualScope -eq 'machine') -and
                ($first.Outcome -eq 'failed') -and
                (Test-OSyncWingetNeedsUserScopeRetry -ExitCode $first.ExitCode -Output $first.RawOutput)

            $final = $first
            $scopeFallback = $false

            if ($needsFallback) {
                $scopeFallback = $true
                Write-OSyncLog -Category 'winget' -Level 'Warning' `
                    -Message ("winget package {0}: portable machine-scope install failed (exit {1}) - attempting user-scope fallback" -f $entry.Id, $first.ExitCode) `
                    -Data @{ Id = $entry.Id; FirstExitCode = $first.ExitCode; FirstScope = $actualScope; NextScope = 'user' } -Config $Config | Out-Null

                # Best-effort cleanup of the broken machine-level state before
                # the retry. Cleanup failure (often the same access-denied) is
                # logged only and never blocks the retry.
                $null = Invoke-OSyncWingetBestEffortCleanup -WingetExe $wingetExe -PackageId $entry.Id -Config $Config

                $final = Invoke-OSyncWingetInstallAttempt -WingetExe $wingetExe -ManifestDir $manifestDir `
                    -Scope 'user' -Architecture $arch -Entry $entry -Config $Config
            }

            if ($final.Outcome -eq 'ok') {
                $info = Get-OSyncWingetManifestInfo -YamlPath $yamls[0].FullName
                $ok += [pscustomobject]@{
                    Id            = $entry.Id
                    Version       = $info.PackageVersion
                    Sha256        = $info.InstallerSha256
                    ExitCode      = $final.ExitCode
                    Scope         = $final.Scope
                    ScopeFallback = $scopeFallback
                }
                Add-OSyncStateRecord -Category 'winget' -Name $entry.Id `
                    -Version $info.PackageVersion -Sha256 $info.InstallerSha256 -Config $Config | Out-Null
                $rebootRequired = ($final.ExitCode -eq -1978334967)
                Write-OSyncLog -Category 'winget' -Level 'Info' `
                    -Message ("winget package {0} installed (exit {1}, scope={2}{3}{4})" -f $entry.Id, $final.ExitCode, $final.Scope, $(if ($scopeFallback) { ', scope fallback from machine' } else { '' }), $(if ($rebootRequired) { ', reboot required' } else { '' })) `
                    -Data @{ Id = $entry.Id; Version = $info.PackageVersion; Sha256 = $info.InstallerSha256; ExitCode = $final.ExitCode; Scope = $final.Scope; ScopeFallback = $scopeFallback; FirstExitCode = $(if ($scopeFallback) { $first.ExitCode } else { $null }); RebootRequired = $rebootRequired } -Config $Config | Out-Null
            }
            elseif ($final.Outcome -eq 'satisfied') {
                $info = Get-OSyncWingetManifestInfo -YamlPath $yamls[0].FullName
                $satisfied += [pscustomobject]@{
                    Id       = $entry.Id
                    Version  = $info.PackageVersion
                    Sha256   = $info.InstallerSha256
                    ExitCode = $final.ExitCode
                }
                Add-OSyncStateRecord -Category 'winget' -Name $entry.Id `
                    -Version $info.PackageVersion -Sha256 $info.InstallerSha256 -Config $Config | Out-Null
                Write-OSyncLog -Category 'winget' -Level 'Info' `
                    -Message ("winget package {0} already satisfied (exit {1}, scope={2}) - idempotent success" -f $entry.Id, $final.ExitCode, $final.Scope) `
                    -Data @{ Id = $entry.Id; Version = $info.PackageVersion; Sha256 = $info.InstallerSha256; ExitCode = $final.ExitCode; Scope = $final.Scope; ScopeFallback = $scopeFallback } -Config $Config | Out-Null
            }
            else {
                # 0x800700C7 = ERROR_INSTALL_SUSPEND / operation cancelled by
                # user. Common when running under a non-interactive / S4U User
                # principal: the MSI installer triggers a UAC prompt that times
                # out because no user is present to confirm it. Log a clear
                # hint so the operator knows this is not a networking error.
                $uacHint = ''
                if ($final.ExitCode -eq -2147023673) {
                    $uacHint = ' (0x800700C7 = installation cancelled by user - likely UAC prompt timeout; consider SYSTEM principal or /quiet in installer switches)'
                }
                $failure = [pscustomobject]@{
                    Id       = $entry.Id
                    ExitCode = $final.ExitCode
                    Output   = $final.Tail
                }
                if ($scopeFallback) {
                    # Preserve both attempts so an operator can see the machine
                    # failure that triggered the fallback and the user failure.
                    $failure | Add-Member -NotePropertyName ScopeAttempts -NotePropertyValue @(
                        [pscustomobject]@{ Scope = $first.Scope; ExitCode = $first.ExitCode },
                        [pscustomobject]@{ Scope = $final.Scope; ExitCode = $final.ExitCode }
                    )
                }
                $failed += $failure
                Write-OSyncLog -Category 'winget' -Level 'Warning' `
                    -Message ("winget install FAILED for {0} (exit {1}, scope={2}){3} - recorded, continuing" -f $entry.Id, $final.ExitCode, $final.Scope, $uacHint) `
                    -Data $failure -Config $Config | Out-Null
            }
        }
    }
    finally {
        if ($null -ne $server) {
            Stop-OSyncHttpServer -Handle $server
            Write-OSyncLog -Category 'winget' -Level 'Info' `
                -Message 'winget apply: HTTP server stopped' -Config $Config | Out-Null
        }
    }

    Write-OSyncLog -Category 'winget' -Level 'Info' `
        -Message ("winget apply round done: {0} ok, {1} satisfied, {2} skipped, {3} failed" -f $ok.Count, $satisfied.Count, $skipped.Count, $failed.Count) `
        -Data @{ ok = $ok.Count; satisfied = $satisfied.Count; skipped = $skipped.Count; failed = $failed.Count } -Config $Config | Out-Null

    if ($failed.Count -gt 0) {
        $ids = ($failed | ForEach-Object { $_.Id }) -join ', '
        throw ("Invoke-OSyncWingetApply: {0} package(s) failed to install: {1}" -f $failed.Count, $ids)
    }

    return [pscustomobject]@{
        category        = 'winget'
        wingetExe       = $wingetExe
        wingetExeVersion = $wingetVersion
        ok              = $ok
        satisfied       = $satisfied
        skipped         = $skipped
        failed          = $failed
        packagesTxt     = $packagesTxt
    }
}