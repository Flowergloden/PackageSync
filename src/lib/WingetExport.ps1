#Requires -Version 5.1
<#
  WingetExport.ps1 - A-side winget whitelist download + YAML InstallerUrl rewrite.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  OBSERVED `winget download` ON-DISK LAYOUT (winget v1.29.290, observed 2026-09-03
  on this machine; captured golden fixture in tests\fixtures\winget\README.txt):

    * `winget download --download-directory <dir> ...` writes the selected
      installer(s) AND one generated manifest YAML per installer FLAT into
      <dir>. winget does NOT create a package-Id subfolder of its own, so this
      library passes a PER-PACKAGE directory (<staging>\winget\<Id>) as
      --download-directory.
    * Generated YAML filename pattern (real observed example):
          7-Zip_26.02_Machine_X64_wix_zh-CN.yaml
      i.e. <PackageName>_<Version>_<Scope(Machine|User)>_<Arch>_<InstallerType>_<Locale>.yaml
      The downloaded installer file has the SAME STEM with its real extension:
          7-Zip_26.02_Machine_X64_wix_zh-CN.msi
      The installer stem is NOT derived from the original InstallerUrl filename
      (winget renames the file); it is always the YAML's sibling with the same stem.
    * The generated YAML is a MERGED manifest (ManifestType: merged) with an
      Installers: list; each installer node carries its own InstallerUrl: and
      InstallerSha256:.
    * Package dependencies are downloaded into a Dependencies\ SUBDIRECTORY of
      the download-directory, each dependency installer getting its own
      generated YAML next to it (winget-cli PR #3376 + #3448). The rewrite
      below therefore walks ALL *.yaml recursively, INCLUDING Dependencies\
      subfolders. `--skip-dependencies` exists but is NOT passed: B needs the
      dependency installers too.

  URL contract (matches PackageSync.md method A and src\lib\HttpServer.ps1):
      http://<httpBind>:<httpPort>/winget/<Id>/<rel-path-from-Id-dir>
    - forward slashes only,
    - every URL-path segment percent-encoded via Uri.EscapeDataString
      (space -> %20, '#' -> %23, '+' -> %2B, ...); the HttpListener server
      percent-decodes before resolving (Oracle m-1).
    - InstallerSha256 is NEVER touched (B-side hash verification depends on it).
#>

function ConvertTo-OSyncUrlPathSegment {
    <#
    .SYNOPSIS
    Percent-encodes ONE URL-path segment (RFC 3986 unreserved characters kept).

    .DESCRIPTION
    Uri.EscapeDataString encodes space, '#', '+', '%' and every other
    non-unreserved character while leaving A-Z a-z 0-9 - . _ ~ alone. The
    HttpListener side decodes with Uri.UnescapeDataString before path
    resolution, so the two are symmetric (Oracle m-1).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Segment
    )

    return [Uri]::EscapeDataString($Segment)
}

function Get-OSyncWingetLocalUrl {
    <#
    .SYNOPSIS
    Builds the localhost URL for one installer file inside a package directory.

    .DESCRIPTION
    Format: http://<HttpBind>:<HttpPort>/winget/<Id>/<segments>
    Backslashes in RelativePath are normalized to forward slashes and every
    path segment is percent-encoded individually (slashes stay slashes).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RelativePath,

        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$HttpBind,

        [Parameter(Mandatory = $true)]
        [int]$HttpPort
    )

    $forward = $RelativePath -replace '\\', '/'
    $encodedSegments = @($forward -split '/') | ForEach-Object {
        ConvertTo-OSyncUrlPathSegment -Segment $_
    }
    $encodedId = ConvertTo-OSyncUrlPathSegment -Segment $Id

    return ('http://{0}:{1}/winget/{2}/{3}' -f $HttpBind, $HttpPort, $encodedId, ($encodedSegments -join '/'))
}

function Get-OSyncWingetInstallerPath {
    <#
    .SYNOPSIS
    Maps a generated manifest YAML to its on-disk installer file.

    .DESCRIPTION
    Per the observed layout, the installer is the YAML's sibling file with the
    SAME STEM (filename without extension) and any extension other than .yaml.
    Returns $null when no such file exists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath
    )

    $dir = Split-Path -Parent $YamlPath
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($YamlPath)

    $candidates = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -cne '.yaml' -and
        [System.IO.Path]::GetFileNameWithoutExtension($_.FullName) -ceq $stem
    } | Sort-Object -Property Name)

    if ($candidates.Count -eq 0) {
        return $null
    }
    return $candidates[0].FullName
}

function Get-OSyncWingetYamlUrls {
    <#
    .SYNOPSIS
    Extracts every URL written under InstallerUrl: and InstallerFallbackUrls:
    keys (including every list item) from a manifest YAML text.

    .DESCRIPTION
    Line-based state machine: a plain `InstallerFallbackUrls:` key starts a
    block whose `- <url>` list items are collected until the first non-list
    line. Flow-style `InstallerFallbackUrls: [a, b]` is handled as well.
    No other keys (IconUrl, DocumentUrl, PackageUrl, ...) are touched.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $urls = @()
    $inFallback = $false

    # Split on LF keeping empty trailing entries ([regex]::Split does not
    # swallow them the way the -split operator does).
    foreach ($rawLine in [regex]::Split($Text, "\n")) {
        $line = $rawLine.TrimEnd("`r")

        if ($inFallback) {
            if ($line -match '^\s*-\s+(\S.*?)\s*$') {
                $urls += $Matches[1]
                continue
            }
            $inFallback = $false
        }

        # Flow-style sequence: InstallerFallbackUrls: [url1, url2]
        if ($line -match '^\s*InstallerFallbackUrls:\s*\[(.*)\]\s*$') {
            $inner = $Matches[1].Trim()
            if ($inner.Length -gt 0) {
                foreach ($part in ($inner -split ',')) {
                    $u = $part.Trim().Trim('"').Trim("'")
                    if ($u.Length -gt 0) {
                        $urls += $u
                    }
                }
            }
            continue
        }

        # Block-style sequence start: InstallerFallbackUrls:
        if ($line -match '^\s*InstallerFallbackUrls:\s*$') {
            $inFallback = $true
            continue
        }

        # Plain scalar: InstallerUrl: <value> (may be single/double quoted).
        if ($line -match '^\s*InstallerUrl:\s+(.+)$') {
            $val = $Matches[1].Trim()
            if ($val.Length -ge 2 -and
                (($val[0] -eq '"' -and $val[$val.Length - 1] -eq '"') -or
                 ($val[0] -eq "'" -and $val[$val.Length - 1] -eq "'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            $urls += $val
        }
    }

    return $urls
}

function Test-OSyncWingetYamlNoLeak {
    <#
    .SYNOPSIS
    Leak assertion: every InstallerUrl: / InstallerFallbackUrls: value in the
    YAML must point at 127.0.0.1 or localhost, else returns $false.

    .DESCRIPTION
    Enforced at export time (fatal) and in Pester unit tests. The export is
    considered broken when any installer URL would reach the internet - B is
    an air-gapped machine and such a URL can never be served locally.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $urls = @(Get-OSyncWingetYamlUrls -Text $Text)
    $offenders = @($urls | Where-Object { $_ -notmatch '^https?://(127\.0\.0\.1|localhost)(:\d+)?(/|$)' })

    if ($offenders.Count -gt 0) {
        Write-Warning ("Test-OSyncWingetYamlNoLeak: {0} installer URL(s) do not point at 127.0.0.1/localhost: {1}" -f $offenders.Count, ($offenders -join ' | '))
        return $false
    }
    return $true
}

function ConvertTo-OSyncWingetYamlContent {
    <#
    .SYNOPSIS
    Rewrites every InstallerUrl: scalar value and every InstallerFallbackUrls:
    list item in one manifest YAML to the localhost URL of its on-disk
    installer, and returns the rewritten text.

    .DESCRIPTION
    Mapping rule (observed layout): the YAML's installer is the sibling file
    with the same stem. Its path relative to the package Id directory becomes
    the URL path (forward slashes, percent-encoded segments). ALL URLs in the
    file are replaced with that one local URL (winget's generated merged
    manifest references exactly one downloaded installer per YAML - PR #3448).
    InstallerSha256 and every other key are left byte-identical.

    Throws when no sibling installer exists - a manifest that cannot be mapped
    to a locally served file must fail loudly instead of shipping an external
    URL (leak guard).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$YamlPath,

        [Parameter(Mandatory = $true)]
        [string]$IdDir,

        [Parameter(Mandatory = $true)]
        [string]$Id,

        [Parameter(Mandatory = $true)]
        [string]$HttpBind,

        [Parameter(Mandatory = $true)]
        [int]$HttpPort
    )

    $installer = Get-OSyncWingetInstallerPath -YamlPath $YamlPath
    if ($null -eq $installer) {
        throw "ConvertTo-OSyncWingetYamlContent: no on-disk installer file found next to manifest '$YamlPath' (expected a sibling with the same stem). Refusing to rewrite."
    }

    # Relative path from the Id directory (PS 5.1 has no [IO.Path]::GetRelativePath).
    $idDirFull = [System.IO.Path]::GetFullPath($IdDir).TrimEnd('\') + '\'
    $installerFull = [System.IO.Path]::GetFullPath($installer)
    if (-not $installerFull.StartsWith($idDirFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "ConvertTo-OSyncWingetYamlContent: installer '$installerFull' is outside the package directory '$idDirFull'."
    }
    $relativePath = $installerFull.Substring($idDirFull.Length)

    $localUrl = Get-OSyncWingetLocalUrl -RelativePath $relativePath -Id $Id -HttpBind $HttpBind -HttpPort $HttpPort

    $text = [System.IO.File]::ReadAllText($YamlPath, [System.Text.Encoding]::UTF8)
    # winget writes CRLF; keep whatever the file uses.
    $newline = "`n"
    if ($text.Contains("`r`n")) {
        $newline = "`r`n"
    }

    $outLines = @()
    $inFallback = $false
    foreach ($rawLine in [regex]::Split($text, "\n")) {
        $line = $rawLine.TrimEnd("`r")

        if ($inFallback) {
            # Fallback list item: '- <url>' - continue the block and rewrite.
            if ($line -match '^(\s*-\s+)(\S.*?)\s*$') {
                $line = $Matches[1] + $localUrl
                $outLines += $line
                continue
            }
            $inFallback = $false
        }

        # Flow-style sequence: InstallerFallbackUrls: [url1, url2]
        if ($line -match '^(\s*InstallerFallbackUrls:\s*\[)(.*)(\]\s*)$') {
            $inner = $Matches[2].Trim()
            if ($inner.Length -gt 0) {
                $parts = @($inner -split ',')
                $rewritten = @()
                foreach ($part in $parts) {
                    $u = $part.Trim()
                    $quote = ''
                    if ($u.Length -ge 2 -and (($u[0] -eq '"' -and $u[$u.Length - 1] -eq '"') -or ($u[0] -eq "'" -and $u[$u.Length - 1] -eq "'"))) {
                        $quote = $u[0].ToString()
                    }
                    $rewritten += ($quote + $localUrl + $quote)
                }
                $line = $Matches[1] + ($rewritten -join ', ') + $Matches[3]
            }
            $outLines += $line
            continue
        }

        # Block-style sequence start: InstallerFallbackUrls:
        if ($line -match '^\s*InstallerFallbackUrls:\s*$') {
            $inFallback = $true
            $outLines += $line
            continue
        }

        # Plain scalar: InstallerUrl: <value> (quotes preserved, value replaced).
        $m = [regex]::Match($line, '^(\s*InstallerUrl:\s*)(.+)$')
        if ($m.Success) {
            $val = $m.Groups[2].Value.Trim()
            $quote = ''
            if ($val.Length -ge 2 -and (($val[0] -eq '"' -and $val[$val.Length - 1] -eq '"') -or ($val[0] -eq "'" -and $val[$val.Length - 1] -eq "'"))) {
                $quote = $val[0].ToString()
            }
            $line = $m.Groups[1].Value + $quote + $localUrl + $quote
        }

        $outLines += $line
    }

    # [regex]::Split above keeps trailing empty entries, so a trailing newline
    # in the source is represented by a final '' element and the join restores
    # it exactly - no extra newline may be appended here.
    $rewritten = $outLines -join $newline

    # Write back UTF-8 WITH BOM (PS 5.1 / winget both handle BOM fine).
    [System.IO.File]::WriteAllText($YamlPath, $rewritten, (New-Object System.Text.UTF8Encoding($true)))

    return $rewritten
}

function Get-OSyncWingetPackagesTxtContent {
    <#
    .SYNOPSIS
    Renders the packages.txt content: only IDs that downloaded successfully
    this round (failed packages must not enter the B-side install list,
    Oracle r7-10). Format stays identical to the whitelist (Id or Id@version)
    so Read-OSyncWingetList parses it unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        $ParsedList,

        # NOT mandatory: PS 5.1 refuses to bind an empty array to a mandatory
        # [string[]] parameter ("Cannot bind argument ... because it is an
        # empty array"), and an all-failed export round legitimately passes
        # zero ok IDs.
        [Parameter(Mandatory = $false)]
        [string[]]$OkIds = @()
    )

    $lines = @()
    foreach ($entry in @($ParsedList)) {
        if ($OkIds -contains $entry.Id) {
            if ($null -ne $entry.Version -and $entry.Version.Trim().Length -gt 0) {
                $lines += ('{0}@{1}' -f $entry.Id, $entry.Version)
            }
            else {
                $lines += $entry.Id
            }
        }
    }
    return $lines
}

function Invoke-OSyncWingetDownload {
    <#
    .SYNOPSIS
    Runs one `winget download` invocation with a hard timeout (unattended
    export must not hang forever on a stalled ISV host).

    .DESCRIPTION
    Uses [System.Diagnostics.Process] + ProcessStartInfo instead of
    Start-Process: under Windows PowerShell 5.1, Start-Process with
    -RedirectStandardOutput/-RedirectStandardError returns a Process object
    whose ExitCode property is ALWAYS $null (PowerShell issue #3028), which
    would silently turn every download into a "failed" record. ProcessStartInfo
    populates ExitCode correctly on both PS 5.1 and pwsh 7.

    Output is read from the redirected streams (winget writes localized
    console output and progress bars that must not pollute the pipeline) and
    trimmed to the tail before being returned for the export report. On
    timeout the process is killed and TimedOut is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WingetExe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = 900000
    )

    # Build the command line: quote any argument that contains whitespace and
    # is not already quoted (the download-directory arrives pre-quoted).
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

function Export-OSyncWinget {
    <#
    .SYNOPSIS
    Downloads every whitelist entry with `winget download` into
    <StagingDir>\winget\<Id>\, rewrites every manifest YAML (including
    Dependencies\ subfolders) to serve installers from
    http://<httpBind>:<httpPort>/winget/<Id>/..., enforces the leak assertion,
    and writes <StagingDir>\winget\packages.txt with ONLY the successful IDs.

    .DESCRIPTION
    Per-package failures (non-zero exit, timeout, no manifest downloaded -
    including UA-403 blocks and nonexistent versions) are recorded in the
    report's failed array and processing CONTINUES with the next package.
    A rewrite/leak-assertion failure is a tool bug, not a per-package
    condition, and therefore throws (the whole export fails).

    Returns the export report object and also writes it to
    <StagingDir>\winget\export-report.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $ParsedList,

        [Parameter(Mandatory = $true)]
        [string]$StagingDir,

        [Parameter(Mandatory = $true)]
        $Config,

        # Test seam: unit tests inject a fake winget; production resolves
        # the real winget.exe via Resolve-OSyncWingetExePath.
        [Parameter(Mandatory = $false)]
        [string]$WingetExePath
    )

    $entries = @($ParsedList)
    if ($entries.Count -eq 0) {
        throw 'Export-OSyncWinget: ParsedList is empty - nothing to export.'
    }

    if (-not [string]::IsNullOrWhiteSpace($WingetExePath)) {
        $wingetExe = $WingetExePath
    }
    else {
        $wingetExe = Resolve-OSyncWingetExePath
        if ($null -eq $wingetExe) {
            throw 'Export-OSyncWinget: winget.exe not found under C:\Program Files\WindowsApps (App Installer not installed?).'
        }
    }

    $wingetDir = Join-Path $StagingDir 'winget'
    New-Item -ItemType Directory -Path $wingetDir -Force | Out-Null

    $scope = [string]$Config.winget.scope
    $arch = [string]$Config.winget.architecture
    $httpBind = [string]$Config.httpBind
    $httpPort = [int]$Config.httpPort

    $okIds = @{}
    $failed = @()

    $wingetVersion = ''
    try {
        $versionOutput = & $wingetExe '--version' 2>&1 | Out-String
        $wingetVersion = $versionOutput.Trim()
    }
    catch {
        $wingetVersion = '(unknown)'
    }

    foreach ($entry in $entries) {
        $pkgDir = Join-Path $wingetDir $entry.Id

        # Stale-content guard: a previous partial download must not leak files
        # into this round's rewrite.
        if (Test-Path -LiteralPath $pkgDir) {
            Remove-Item -Recurse -Force -LiteralPath $pkgDir
        }
        New-Item -ItemType Directory -Path $pkgDir -Force | Out-Null

        # --download-directory is quoted and placed LAST (also the contract
        # for the fake winget used in unit tests).
        $downloadArgs = @('download', '--id', $entry.Id, '-e')
        if ($null -ne $entry.Version -and $entry.Version.Trim().Length -gt 0) {
            $downloadArgs += @('-v', $entry.Version)
        }
        $downloadArgs += @(
            '--scope', $scope,
            '--architecture', $arch,
            '--accept-package-agreements',
            '--accept-source-agreements',
            '--disable-interactivity',
            '--download-directory', ('"{0}"' -f $pkgDir)
        )

        # Write-OSyncLog RETURNS the JSONL path - pipe to Out-Null so the
        # export report object is the ONLY thing this function emits.
        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message ("Downloading winget package {0} ({1})" -f $entry.Id, $entry.Version) `
            -Data @{ Id = $entry.Id; Version = $entry.Version } -Config $Config | Out-Null

        $result = Invoke-OSyncWingetDownload -WingetExe $wingetExe -Arguments $downloadArgs

        $yamls = @(Get-ChildItem -LiteralPath $pkgDir -Recurse -Filter '*.yaml' -File -ErrorAction SilentlyContinue)

        if ($result.TimedOut -or $result.ExitCode -ne 0 -or $yamls.Count -eq 0) {
            $tail = ''
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
                $tailLines = @($result.Output -split "`n")
                $tail = (($tailLines | Select-Object -Last 15) -join "`n").Trim()
            }
            $reason = 'download failed'
            if ($result.TimedOut) {
                $reason = 'timeout'
            }
            elseif ($result.ExitCode -eq 0) {
                $reason = 'no manifest downloaded'
            }
            $failure = [pscustomobject]@{
                Id       = $entry.Id
                Version  = $entry.Version
                ExitCode = $result.ExitCode
                Reason   = $reason
                Output   = $tail
            }
            $failed += $failure
            Write-OSyncLog -Category 'winget' -Level 'Warning' `
                -Message ("winget download FAILED for {0} (exit {1}, {2}) - recorded in report, continuing" -f $entry.Id, $result.ExitCode, $reason) `
                -Data $failure -Config $Config | Out-Null
            continue
        }

        # Rewrite + leak assertion. A failure here is a tool bug (the layout
        # diverged from the observed facts or the rewrite is broken), so it is
        # FATAL - never a silent per-package skip.
        try {
            foreach ($yaml in $yamls) {
                $rewritten = ConvertTo-OSyncWingetYamlContent `
                    -YamlPath $yaml.FullName -IdDir $pkgDir -Id $entry.Id `
                    -HttpBind $httpBind -HttpPort $httpPort
                if (-not (Test-OSyncWingetYamlNoLeak -Text $rewritten)) {
                    throw ("leak assertion failed for manifest '{0}' - rewritten YAML still contains a non-localhost InstallerUrl." -f $yaml.FullName)
                }
            }
        }
        catch {
            throw ("Export-OSyncWinget: YAML rewrite / leak assertion failed for package '{0}': {1}" -f $entry.Id, $_.Exception.Message)
        }

        $okIds[$entry.Id.ToLowerInvariant()] = $entry
        Write-OSyncLog -Category 'winget' -Level 'Info' `
            -Message ("winget package {0} exported ({1} manifest(s) rewritten)" -f $entry.Id, $yamls.Count) `
            -Data @{ Id = $entry.Id; Version = $entry.Version; Manifests = $yamls.Count } -Config $Config | Out-Null
    }

    # packages.txt: ONLY the IDs that downloaded successfully this round.
    $packagesLines = @(Get-OSyncWingetPackagesTxtContent -ParsedList $entries -OkIds @($okIds.Keys))
    $packagesTxtPath = Join-Path $wingetDir 'packages.txt'
    $packagesContent = $packagesLines -join "`r`n"
    if ($packagesLines.Count -gt 0) {
        $packagesContent += "`r`n"
    }
    [System.IO.File]::WriteAllText($packagesTxtPath, $packagesContent, (New-Object System.Text.UTF8Encoding($true)))

    $okReport = @()
    foreach ($entry in $entries) {
        if ($okIds.ContainsKey($entry.Id.ToLowerInvariant())) {
            $okReport += [pscustomobject]@{ Id = $entry.Id; Version = $entry.Version }
        }
    }

    $report = [pscustomobject]@{
        category        = 'winget'
        wingetExeVersion = $wingetVersion
        ok              = $okReport
        failed          = $failed
        packagesTxt     = $packagesTxtPath
    }

    $reportJson = ConvertTo-OSyncJson -InputObject $report
    [System.IO.File]::WriteAllText((Join-Path $wingetDir 'export-report.json'), $reportJson, (New-Object System.Text.UTF8Encoding($true)))

    Write-OSyncLog -Category 'winget' -Level 'Info' `
        -Message ("winget export round done: {0} ok, {1} failed" -f $okReport.Count, $failed.Count) `
        -Data @{ ok = $okReport.Count; failed = $failed.Count } -Config $Config | Out-Null

    return $report
}
