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
      0                                        -> success
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
      { category, wingetExe, wingetExeVersion, ok, satisfied, failed, packagesTxt }
    ok/satisfied entries: { Id, Version, Sha256, ExitCode }
    failed entries:       { Id, ExitCode, Output }

  PORT-COUPLING GUARD (Oracle r7-4): the InstallerUrl port is baked in at
  A-side export time and the B config must never override it. Every rewritten
  YAML under <WorkDir>\winget\ is scanned; if ANY InstallerUrl /
  InstallerFallbackUrls port differs from config.httpPort the function fails
  fast BEFORE the HTTP server is started.

  winget.exe is RE-DERIVED every run via Resolve-OSyncWingetExePath - a path
  read back from state is never executed (Oracle r3-B1). -WingetExePath is a
  test seam only (same contract as Export-OSyncWinget).
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
    Stages a manifest-ONLY flat directory for one package.

.DESCRIPTION
    winget v1.29.290 rejects non-YAML files AND subdirectories in the
    --manifest path (observed in QA). The export layout keeps the installer
    next to the YAML, so this function copies every *.yaml (recursively,
    flattened) into <StagingRoot>\<Id>\ and returns that path. The installers
    stay in the work copy where the HTTP server serves them. On a filename
    collision the later file is prefixed with its immediate parent directory
    name so no manifest is lost.
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
    $yamls = @(Get-ChildItem -LiteralPath $PackageDir -Recurse -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    foreach ($yaml in $yamls) {
        $name = $yaml.Name
        if ($used.ContainsKey($name.ToLowerInvariant())) {
            $parent = Split-Path -Leaf (Split-Path -Parent $yaml.FullName)
            $name = '{0}_{1}' -f $parent, $name
        }
        $used[$name.ToLowerInvariant()] = $true
        Copy-Item -LiteralPath $yaml.FullName -Destination (Join-Path $staging $name)
    }
    return $staging
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

        foreach ($entry in $toInstall) {
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

            $installArgs = @(
                'install',
                '--manifest', ('"{0}"' -f $manifestDir),
                '--scope', $scope,
                '--architecture', $arch,
                '--accept-package-agreements',
                '--accept-source-agreements',
                '--disable-interactivity'
            )

            Write-OSyncLog -Category 'winget' -Level 'Info' `
                -Message ("Installing winget package {0} from manifest set {1}" -f $entry.Id, $manifestDir) `
                -Data @{ Id = $entry.Id; Version = $entry.Version; ManifestDir = $manifestDir } -Config $Config | Out-Null

            $result = Invoke-OSyncWingetInstall -WingetExe $wingetExe -Arguments $installArgs

            # winget source auto-update failures are logged, never blocking:
            # the full output tail is captured and logged regardless of the
            # exit code so an offline B still leaves a diagnostic trail.
            $tail = ''
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
                $tailLines = @($result.Output -split "`n")
                $tail = (($tailLines | Select-Object -Last 15) -join "`n").Trim()
            }

            if ($result.TimedOut) {
                $failure = [pscustomobject]@{ Id = $entry.Id; ExitCode = -1; Output = 'winget install timed out' }
                $failed += $failure
                Write-OSyncLog -Category 'winget' -Level 'Warning' `
                    -Message ("winget install TIMED OUT for {0} - recorded, continuing" -f $entry.Id) `
                    -Data $failure -Config $Config | Out-Null
                continue
            }

            if ($result.ExitCode -eq 0) {
                $info = Get-OSyncWingetManifestInfo -YamlPath $yamls[0].FullName
                $ok += [pscustomobject]@{
                    Id       = $entry.Id
                    Version  = $info.PackageVersion
                    Sha256   = $info.InstallerSha256
                    ExitCode = 0
                }
                Add-OSyncStateRecord -Category 'winget' -Name $entry.Id `
                    -Version $info.PackageVersion -Sha256 $info.InstallerSha256 -Config $Config | Out-Null
                Write-OSyncLog -Category 'winget' -Level 'Info' `
                    -Message ("winget package {0} installed (exit 0)" -f $entry.Id) `
                    -Data @{ Id = $entry.Id; Version = $info.PackageVersion; Sha256 = $info.InstallerSha256 } -Config $Config | Out-Null
            }
            elseif ($script:WingetSatisfiedExitCodes -contains $result.ExitCode) {
                $info = Get-OSyncWingetManifestInfo -YamlPath $yamls[0].FullName
                $satisfied += [pscustomobject]@{
                    Id       = $entry.Id
                    Version  = $info.PackageVersion
                    Sha256   = $info.InstallerSha256
                    ExitCode = $result.ExitCode
                }
                Add-OSyncStateRecord -Category 'winget' -Name $entry.Id `
                    -Version $info.PackageVersion -Sha256 $info.InstallerSha256 -Config $Config | Out-Null
                Write-OSyncLog -Category 'winget' -Level 'Info' `
                    -Message ("winget package {0} already satisfied (exit {1}) - idempotent success" -f $entry.Id, $result.ExitCode) `
                    -Data @{ Id = $entry.Id; Version = $info.PackageVersion; Sha256 = $info.InstallerSha256; ExitCode = $result.ExitCode } -Config $Config | Out-Null
            }
            else {
                $failure = [pscustomobject]@{
                    Id       = $entry.Id
                    ExitCode = $result.ExitCode
                    Output   = $tail
                }
                $failed += $failure
                Write-OSyncLog -Category 'winget' -Level 'Warning' `
                    -Message ("winget install FAILED for {0} (exit {1}) - recorded, continuing" -f $entry.Id, $result.ExitCode) `
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
        -Message ("winget apply round done: {0} ok, {1} satisfied, {2} failed" -f $ok.Count, $satisfied.Count, $failed.Count) `
        -Data @{ ok = $ok.Count; satisfied = $satisfied.Count; failed = $failed.Count } -Config $Config | Out-Null

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
        failed          = $failed
        packagesTxt     = $packagesTxt
    }
}