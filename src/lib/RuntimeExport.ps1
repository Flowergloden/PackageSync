#Requires -Version 5.1
<#
  RuntimeExport.ps1 - A-side runtime bootstrap payload export.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Export-OSyncRuntime -Config -StagingDir [-WingetExePath] [-ToolSourceDir]

  Execution order (fail-fast first, heavy work last):

    1. Validate manifests\runtime-winget.txt (Assert-OSyncRuntimeWinget):
       when categories.pip is enabled the file MUST contain a line matching
       ^Python\.Python\.3\.\d+@ and when categories.npm is enabled one
       matching ^OpenJS\.NodeJS(\.LTS)?@ - missing -> explicit error
       (Metis M5). When only winget/dotfiles are enabled the not-needed
       entries are exempt (Momus r4-M2).

    2. Cross-assertion (Oracle m6): config.pip.downloadArgs --python-version
       and --abi must match the Python line's major.minor version; mismatch
       -> the export fails. Missing args fall back to the pinned defaults
       (--python-version 3.12 / --abi cp312, same semantics as PipExport's
       Get-OSyncPipDownloadArgs).

    3. VC_redist (config.pins.appInstaller.vcRedistUrl/vcRedistSha256) into
       <staging>\runtime\appinstaller\ with the per-piece sha256 PIN-ME flow
       (same semantics as todo 9 / DotfilesExport):
         - the piece still 'PIN-ME' -> prints the real hash and exits
           non-zero (the operator pins it and re-runs),
         - hash mismatch -> aborts naming the file (expected vs actual),
         - match -> proceeds.
        The App Installer chain (msixbundle/VCLibs/UI.Xaml) is NO LONGER
        exported at all (user decision, 2026-09): modern Windows ships App
        Installer / winget preinstalled, so the B-side bootstrap only
        verifies winget.exe presence and never installs the pieces. The
        appinstaller dir now carries ONLY VC_redist.x64.exe.

     3.5. bun runtime payload (config.pins.bun - presence-gated; bun is NOT
        a category): when pins.bun is present the pinned Windows bun
        release zip is downloaded into <staging>\runtime\bun\bun.zip
        (reuse-on-existing, so a PIN-ME run followed by a pinned re-run
        performs exactly ONE download) and the same PIN-ME sha256 gate as
        chezmoi is enforced:
          - 'PIN-ME' -> prints the actual hash and exits non-zero,
          - mismatch -> aborts (the download is not the pinned artifact),
          - match -> extracts bun.exe (Expand-OSyncBunZip) and writes
            version.txt = pins.bun.version (UTF8, no BOM) - the B-side
            version-expectation source (the B config carries no pins.bun).
        When pins.bun is absent the payload is skipped (Info log) and the
        report carries bun = $null. Runs BETWEEN the appInstaller PIN-ME
        gate and the heavy Python/Node winget downloads so a PIN-ME
        iteration never re-downloads them. No files.json / trust-root
        change is needed: New-OSyncFilesManifest enumerates whole category
        dirs.

    4. Runtime winget entries: REUSES todo 6's download+rewrite functions
       (Invoke-OSyncWingetDownload / ConvertTo-OSyncWingetYamlContent /
       Test-OSyncWingetYamlNoLeak / Resolve-OSyncWingetExePath from
       WingetExport.ps1) to export each runtime-winget.txt entry into
       <staging>\winget\<Id>\ - the same shape as the winget category, for
       the B-side bootstrap. NO packages.txt is written here: the runtime
       entries are tracked by <staging>\runtime\runtime-winget.txt and the
       winget category's packages.txt must keep only its own entries
       (todo 13 excludes the runtime IDs from it).

5. Portable Verdaccio: npm install --prefix <LOCAL temp build dir>
        verdaccio@<pins.npm.verdaccioVersion> -> robocopy to
        <staging>\runtime\verdaccio\ (the build dir is removed afterwards).
        The build dir is LOCAL (under %TEMP%): npm's arborist 'realpathCached'
        infinitely recurses on UNC prefixes (RangeError: Maximum call stack
        size exceeded) - the staging location is only ever written via
        robocopy (plain file IO).
       B-side launch entry candidates (layout verified in QA, see learnings):
         primary:  node.exe <dir>\node_modules\verdaccio\bin\verdaccio --config <yml>
         fallback: <dir>\node_modules\.bin\verdaccio.cmd --config <yml>  (.bin shim)

    6. Copy manifests\runtime-winget.txt -> <staging>\runtime\runtime-winget.txt
       (delivery contract, Momus B1/Oracle m5).

    7. Tool self-bootstrap snapshot: robocopy src\ + copy
       config\packagesync.b.json + README.md (when present) ->
       <staging>\runtime\tool\ (Momus B1: the tool itself must reach B via
       the repo).

  Must NOT: Python/Node installers are NEVER procured outside the winget
  pipeline (single install semantics); nothing is installed on A
  (no Add-AppxPackage, no VC_redist run) - static verification only.

  Returns the export report as a PSCustomObject.
#>

function Assert-OSyncRuntimeWinget {
    <#
      Validates manifests\runtime-winget.txt for the runtime export:
        - the file must exist,
        - when categories.pip is enabled a line matching
          ^Python\.Python\.3\.\d+@ is REQUIRED (the B-side bootstrap installs
          Python from this list),
        - when categories.npm is enabled a line matching
          ^OpenJS\.NodeJS(\.LTS)?@ is REQUIRED (Node for the portable
          Verdaccio / npm apply).
      Missing required lines -> explicit error (Metis M5). When only
      winget/dotfiles are enabled the not-needed entries are exempt
      (Momus r4-M2).
      Returns { Path, PythonLine, NodeLine } (lines are $null when absent).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $Config
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Export-OSyncRuntime: runtime winget whitelist not found: '$Path'."
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $pythonLine = $null
    $nodeLine = $null
    foreach ($line in $lines) {
        $trimmed = [string]$line
        if ($trimmed -match '^Python\.Python\.3\.\d+@') {
            if ($null -eq $pythonLine) { $pythonLine = $trimmed }
        }
        elseif ($trimmed -match '^OpenJS\.NodeJS(\.LTS)?@') {
            if ($null -eq $nodeLine) { $nodeLine = $trimmed }
        }
    }

    $needPython = [bool]$Config.categories.pip
    $needNode = [bool]$Config.categories.npm

    if ($needPython -and $null -eq $pythonLine) {
        throw "Export-OSyncRuntime: '$Path' is missing a 'Python.Python.3.<minor>@<version>' line - required because categories.pip is enabled (the B-side bootstrap installs Python from this list)."
    }
    if ($needNode -and $null -eq $nodeLine) {
        throw "Export-OSyncRuntime: '$Path' is missing an 'OpenJS.NodeJS[.LTS]@<version>' line - required because categories.npm is enabled (the B-side bootstrap installs Node from this list)."
    }

    return [pscustomobject]@{
        Path       = $Path
        PythonLine = $pythonLine
        NodeLine   = $nodeLine
    }
}

function Get-OSyncRuntimeVersionFromLine {
    <#
      Extracts the version after '@' from a whitelist line
      ('Python.Python.3.12@3.12.10' -> '3.12.10'). Returns $null for a
      $null/empty line or a line without '@'.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $at = $Line.IndexOf('@')
    if ($at -lt 0) { return $null }
    return $Line.Substring($at + 1).Trim()
}

function Test-OSyncPipCrossAssertion {
    <#
      Cross-assertion (Oracle m6): config.pip.downloadArgs --python-version
      and --abi must match the Python line's major.minor version pinned in
      runtime-winget.txt. Missing args fall back to the pinned defaults
      (--python-version 3.12 / --abi cp312 - same semantics as PipExport).
      --abi 'cp312' is decoded as major.minor '3.12' (cp + major + minor
      concatenated).
      Returns { Match, PythonVersion, Abi, AbiMajorMinor, RuntimePython,
      Reason }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$DownloadArgs,

        [AllowNull()]
        [string]$RuntimePythonVersion
    )

    $pythonVersion = $null
    $abi = $null
    $args = @($DownloadArgs)
    for ($i = 0; $i -lt $args.Count - 1; $i++) {
        if ($args[$i] -eq '--python-version') { $pythonVersion = [string]$args[$i + 1] }
        elseif ($args[$i] -eq '--abi') { $abi = [string]$args[$i + 1] }
    }
    if ([string]::IsNullOrWhiteSpace($pythonVersion)) { $pythonVersion = '3.12' }
    if ([string]::IsNullOrWhiteSpace($abi)) { $abi = 'cp312' }

    $runtimeMajorMinor = $null
    if (-not [string]::IsNullOrWhiteSpace($RuntimePythonVersion) -and $RuntimePythonVersion -match '^(\d+)\.(\d+)') {
        $runtimeMajorMinor = '{0}.{1}' -f $Matches[1], $Matches[2]
    }

    $abiMajorMinor = $null
    if ($abi -match '^cp(\d+)$') {
        $digits = $Matches[1]
        if ($digits.Length -ge 2) {
            $abiMajorMinor = '{0}.{1}' -f $digits.Substring(0, 1), $digits.Substring(1)
        }
    }

    $match = $false
    $reason = ''
    if ($null -eq $runtimeMajorMinor) {
        $reason = 'no Python line in the runtime whitelist to compare against'
    }
    elseif ($pythonVersion -ne $runtimeMajorMinor) {
        $reason = "--python-version '$pythonVersion' does not match the runtime Python major.minor '$runtimeMajorMinor'"
    }
    elseif ($abiMajorMinor -ne $runtimeMajorMinor) {
        $reason = "--abi '$abi' (major.minor '$abiMajorMinor') does not match the runtime Python major.minor '$runtimeMajorMinor'"
    }
    else {
        $match = $true
        $reason = 'ok'
    }

    return [pscustomobject]@{
        Match         = $match
        PythonVersion = $pythonVersion
        Abi           = $abi
        AbiMajorMinor = $abiMajorMinor
        RuntimePython = $runtimeMajorMinor
        Reason        = $reason
    }
}

function Get-OSyncAppInstallerPieces {
    <#
      Returns the appInstaller piece definitions (name, url, target file).
      Only the VC_redist piece remains (user decision, 2026-09): the App
      Installer chain (msixbundle/VCLibs/UI.Xaml) is no longer exported -
      modern Windows ships App Installer / winget preinstalled and the
      B-side bootstrap only verifies winget.exe presence.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $pins = $Config.pins.appInstaller
    return @(
        [pscustomobject]@{
            Name     = 'vcredist'
            Url      = [string]$pins.vcRedistUrl
            File     = 'VC_redist.x64.exe'
            Expected = [string]$pins.vcRedistSha256
        }
    )
}

function Assert-OSyncAppInstallerHashes {
    <#
      Downloads (download-if-missing) the appInstaller piece(s) into <Dir>,
      computes their sha256, and enforces the PIN-ME flow per piece (same
      semantics as todo 9):
        - a piece still 'PIN-ME' -> prints the real hash and throws
          (non-zero exit; the operator pins it and re-runs),
        - any hash mismatch -> throws naming the file (expected vs actual),
        - all match -> returns the per-piece results.
      The download-if-missing design means a PIN-ME run followed by a pinned
      re-run (same staging dir) performs exactly ONE download per piece.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Dir
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }

    $pieces = @(Get-OSyncAppInstallerPieces -Config $Config)
    $results = @()

    foreach ($piece in $pieces) {
        $target = Join-Path $Dir $piece.File

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Write-OSyncLog -Category 'runtime' -Level Info -Message ("Downloading appInstaller piece {0} from '{1}' -> '{2}'" -f $piece.Name, $piece.Url, $target) -Config $Config | Out-Null
            $null = Invoke-OSyncDownload -Uri $piece.Url -OutFile $target
        }
        else {
            Write-OSyncLog -Category 'runtime' -Level Info -Message ("Reusing existing download '{0}'" -f $target) -Config $Config | Out-Null
        }

        $actualHash = Get-OSyncFileSha256 -Path $target
        $results += [pscustomobject]@{
            Name     = $piece.Name
            Url      = $piece.Url
            File     = $piece.File
            Sha256   = $actualHash
            Expected = $piece.Expected
            IsPinMe  = ($piece.Expected -eq 'PIN-ME')
        }
    }

    $pinMe = @($results | Where-Object { $_.IsPinMe })
    if ($pinMe.Count -gt 0) {
        Write-Host 'Export-OSyncRuntime: one or more config.pins.appInstaller.*Sha256 values are still PIN-ME.'
        foreach ($r in $results) {
            Write-Host ("  {0}: {1}" -f $r.Name, $r.Sha256)
        }
        Write-Host 'Pin the real sha256 value(s) into config\packagesync.json (pins.appInstaller.*Sha256) and re-run.'
        $names = ($pinMe | ForEach-Object { $_.Name }) -join ', '
        $hashList = ($results | ForEach-Object { '{0}={1}' -f $_.Name, $_.Sha256 }) -join '; '
        Write-OSyncLog -Category 'runtime' -Level Error -Message "PIN-ME: appInstaller piece(s) $names still unpinned - actual hashes printed." -Data @{ pieces = $results } -Config $Config | Out-Null
        throw "Export-OSyncRuntime: config.pins.appInstaller.*Sha256 is still 'PIN-ME' for: $names. Actual sha256 values: $hashList. Pin them into config\packagesync.json and re-run."
    }

    $mismatches = @($results | Where-Object { $_.Sha256 -ne $_.Expected })
    if ($mismatches.Count -gt 0) {
        $detail = ($mismatches | ForEach-Object { "{0} ('{1}'): expected '{2}', got '{3}'" -f $_.Name, $_.File, $_.Expected, $_.Sha256 }) -join '; '
        Write-OSyncLog -Category 'runtime' -Level Error -Message "appInstaller sha256 mismatch: $detail" -Data @{ mismatches = $mismatches } -Config $Config | Out-Null
        throw "Export-OSyncRuntime: appInstaller sha256 mismatch for file(s): $detail. Aborting - the download is not the pinned artifact."
    }

    return $results
}

function Expand-OSyncBunZip {
    <#
      Extracts the bun.exe entry from the pinned bun release zip into
      <Destination>\bun.exe. The bun Windows release zip contains only
      bun.exe, but the entry is matched by Name (case-insensitive) like the
      chezmoi helper for robustness. Throws when the entry is missing.
      Modeled on Expand-OSyncChezmoiZip (DotfilesExport.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.Name -ieq 'bun.exe' } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "Expand-OSyncBunZip: no 'bun.exe' entry found in '$ZipPath'."
        }
        if (-not (Test-Path -LiteralPath $Destination -PathType Container)) {
            New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        }
        $target = Join-Path $Destination 'bun.exe'
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        return $target
    }
    finally {
        $zip.Dispose()
    }
}

function Invoke-OSyncRuntimeWingetExport {
    <#
      Exports every runtime-winget.txt entry into <StagingDir>\winget\<Id>\
      REUSING todo 6's download+rewrite functions (Invoke-OSyncWingetDownload
      / ConvertTo-OSyncWingetYamlContent / Test-OSyncWingetYamlNoLeak from
      WingetExport.ps1) - the same shape as the winget category, for the
      B-side bootstrap. Per-package failures are recorded and processing
      continues; a rewrite/leak-assertion failure is a tool bug and throws.
      NO packages.txt is written (the runtime entries are tracked by
      <staging>\runtime\runtime-winget.txt).
      Returns { ok, failed }.
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
        # the real winget.exe via Resolve-OSyncWingetExePath (per-user alias
        # fallback for non-elevated shells - observed, todo 6).
        [Parameter(Mandatory = $false)]
        [string]$WingetExePath
    )

    $entries = @($ParsedList)
    if ($entries.Count -eq 0) {
        throw 'Invoke-OSyncRuntimeWingetExport: ParsedList is empty - nothing to export.'
    }

    if (-not [string]::IsNullOrWhiteSpace($WingetExePath)) {
        $wingetExe = $WingetExePath
    }
    else {
        $wingetExe = Resolve-OSyncWingetExePath
        if ($null -eq $wingetExe) {
            # Non-elevated shells cannot glob C:\Program Files\WindowsApps
            # (ACL); the per-user alias works there (observed, todo 6).
            $cmd = Get-Command winget -ErrorAction SilentlyContinue
            if ($null -ne $cmd) { $wingetExe = $cmd.Source }
        }
        if ($null -eq $wingetExe) {
            throw 'Invoke-OSyncRuntimeWingetExport: winget.exe not found (App Installer not installed?).'
        }
    }

    $wingetDir = Join-Path $StagingDir 'winget'
    New-Item -ItemType Directory -Path $wingetDir -Force | Out-Null

    # consoleEcho is an in-memory-only flag pinned by the export orchestrator
    # (absent/false on B-side configs -> silent, same as WingetExport.ps1).
    $echoOn = ($null -ne $Config -and $Config.PSObject.Properties['consoleEcho'] -and [bool]$Config.consoleEcho)

    $scope = [string]$Config.winget.scope
    $arch = [string]$Config.winget.architecture
    $httpBind = [string]$Config.httpBind
    $httpPort = [int]$Config.httpPort

    $ok = @()
    $failed = @()

    foreach ($entry in $entries) {
        $pkgDir = Join-Path $wingetDir $entry.Id

        # Stale-content guard: a previous partial download must not leak
        # files into this round's rewrite.
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
        Write-OSyncLog -Category 'runtime' -Level Info -Message ("Downloading runtime winget package {0} ({1})" -f $entry.Id, $entry.Version) -Data @{ Id = $entry.Id; Version = $entry.Version } -Config $Config | Out-Null

        $result = Invoke-OSyncWingetDownload -WingetExe $wingetExe -Arguments $downloadArgs -Echo $echoOn

        $yamls = @(Get-ChildItem -LiteralPath $pkgDir -Recurse -Filter '*.yaml' -File -ErrorAction SilentlyContinue)

        if ($result.TimedOut -or $result.ExitCode -ne 0 -or $yamls.Count -eq 0) {
            $tail = ''
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
                $tailLines = @($result.Output -split "`n")
                $tail = (($tailLines | Select-Object -Last 15) -join "`n").Trim()
            }
            $reason = 'download failed'
            if ($result.TimedOut) { $reason = 'timeout' }
            elseif ($result.ExitCode -eq 0) { $reason = 'no manifest downloaded' }
            $failed += [pscustomobject]@{
                Id       = $entry.Id
                Version  = $entry.Version
                ExitCode = $result.ExitCode
                Reason   = $reason
                Output   = $tail
            }
            Write-OSyncLog -Category 'runtime' -Level Warning -Message ("runtime winget download FAILED for {0} (exit {1}, {2}) - recorded in report, continuing" -f $entry.Id, $result.ExitCode, $reason) -Data @{ Id = $entry.Id } -Config $Config | Out-Null
            continue
        }

        # Rewrite + leak assertion. A failure here is a tool bug (the layout
        # diverged from the observed facts or the rewrite is broken), so it
        # is FATAL - never a silent per-package skip.
        try {
            foreach ($yaml in $yamls) {
                $rewritten = ConvertTo-OSyncWingetYamlContent -YamlPath $yaml.FullName -IdDir $pkgDir -Id $entry.Id -HttpBind $httpBind -HttpPort $httpPort
                if (-not (Test-OSyncWingetYamlNoLeak -Text $rewritten)) {
                    throw ("leak assertion failed for manifest '{0}' - rewritten YAML still contains a non-localhost InstallerUrl." -f $yaml.FullName)
                }
            }
        }
        catch {
            throw ("Invoke-OSyncRuntimeWingetExport: YAML rewrite / leak assertion failed for package '{0}': {1}" -f $entry.Id, $_.Exception.Message)
        }

        $ok += [pscustomobject]@{ Id = $entry.Id; Version = $entry.Version; Manifests = $yamls.Count }
        Write-OSyncLog -Category 'runtime' -Level Info -Message ("runtime winget package {0} exported ({1} manifest(s) rewritten)" -f $entry.Id, $yamls.Count) -Data @{ Id = $entry.Id; Manifests = $yamls.Count } -Config $Config | Out-Null
    }

    return [pscustomobject]@{ ok = @($ok); failed = @($failed) }
}

function Get-ORuntimeNpmExe {
    <#
      Resolves the npm executable (npm.cmd on Windows). Throws when npm is
      not available - the portable Verdaccio install cannot work without it.
    #>
    [CmdletBinding()]
    param()

    $cmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        throw "Export-OSyncRuntime: 'npm' was not found on PATH - npm is required for the portable Verdaccio install."
    }
    return $cmd.Source
}

function Get-ORuntimeVerdaccioBuildDir {
    <#
      Returns a fresh, already-created LOCAL scratch dir for the portable
      Verdaccio npm install (<temp>\osync-runtime-verdaccio-<guid>). npm's
      arborist 'realpathCached' infinitely recurses on UNC prefixes
      (RangeError: Maximum call stack size exceeded - reproduced with a UNC
      stagingRoot), so the --prefix npm sees must be local; the finished
      build is robocopy-mirrored to <staging>\runtime\verdaccio afterwards.
      The caller owns the cleanup (long-path \\?\ delete - node_modules
      paths exceed MAX_PATH).
    #>
    [CmdletBinding()]
    param()

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-runtime-verdaccio-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Invoke-ORuntimeNpmInstall {
    <#
      Runs `npm install verdaccio@<version> --prefix <dir>` with the
      temp-EAP-Continue pattern (PS 5.1: native stderr + EAP=Stop throws a
      terminating NativeCommandError - see NpmExport learnings). --prefix is
      placed LAST (contract for the fake npm used in unit tests).
      Returns { ExitCode, Output }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NpmExe,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        # Forward each output line to the console live (Write-Host only -
        # the pipeline still carries the captured objects untouched, so the
        # returned Output keeps its exact pre-echo shape).
        [Parameter(Mandatory = $false)]
        [bool]$Echo = $false
    )

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # --prefix is passed UNQUOTED: PowerShell 5.1 quotes native args with
        # spaces itself; pre-embedding quotes makes npm treat them as part of
        # the path (observed: 'CWD\"C:\path"' -> ENOENT). --prefix stays LAST
        # (contract for the fake npm used in unit tests).
        $output = @(& $NpmExe install "verdaccio@$Version" --no-audit --no-fund --loglevel error --prefix $Prefix 2>&1 | ForEach-Object {
            if ($Echo) {
                # PS 5.1 wraps native stderr lines in ErrorRecords - render
                # the exception message, not the type name (see PipExport).
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
                Write-Host ('  npm: ' + $line) -ForegroundColor DarkGray
            }
            $_
        })
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output)
    }
}

function Export-OSyncRuntime {
    <#
      The runtime bootstrap payload export. See the file header for the
      full step list and the execution order (fail-fast first, heavy work
      last - the appInstaller PIN-ME gate runs BEFORE the large Python/Node
      winget downloads so a PIN-ME iteration never re-downloads them).
      Returns the export report as a PSCustomObject.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$StagingDir,

        # Test seam: unit tests inject a fake winget.
        [Parameter(Mandatory = $false)]
        [string]$WingetExePath,

        # Test seam: the tool source dir (defaults to the repo root derived
        # from this module's location).
        [Parameter(Mandatory = $false)]
        [string]$ToolSourceDir
    )

    # --- 1. validate manifests\runtime-winget.txt (config.paths.* are
    # tool-root-relative INPUT manifests - never config.repoRoot, the output
    # landing dir) ---
    $runtimeWingetPath = Resolve-OSyncConfigPath -Config $Config -Path $Config.paths.runtimeWhitelist
    $validated = Assert-OSyncRuntimeWinget -Path $runtimeWingetPath -Config $Config
    # Write-OSyncLog RETURNS the JSONL path - pipe to Out-Null so the export
    # report object is the ONLY thing this function emits.
    Write-OSyncLog -Category 'runtime' -Level Info -Message "runtime winget whitelist validated: '$runtimeWingetPath'" -Config $Config | Out-Null

    $pythonVersion = Get-OSyncRuntimeVersionFromLine -Line $validated.PythonLine
    $nodeVersion = Get-OSyncRuntimeVersionFromLine -Line $validated.NodeLine

    # --- 2. cross-assertion: pip downloadArgs vs Python line (fail-fast) ---
    $cross = Test-OSyncPipCrossAssertion -DownloadArgs @($Config.pip.downloadArgs) -RuntimePythonVersion $pythonVersion
    Write-OSyncLog -Category 'runtime' -Level Info -Message ("pip cross-assertion: --python-version {0} / --abi {1} vs runtime Python {2} -> match={3} ({4})" -f $cross.PythonVersion, $cross.Abi, $cross.RuntimePython, $cross.Match, $cross.Reason) -Config $Config | Out-Null
    if (-not $cross.Match) {
        throw "Export-OSyncRuntime: cross-assertion failed - config.pip.downloadArgs (--python-version '$($cross.PythonVersion)', --abi '$($cross.Abi)') does not match the Python major.minor '$($cross.RuntimePython)' pinned in '$runtimeWingetPath'. $($cross.Reason)"
    }

    # --- 3. VC_redist (PIN-ME flow; the App Installer chain is no longer
    # exported - modern Windows ships App Installer / winget preinstalled) ---
    $runtimeDir = Join-Path $StagingDir 'runtime'
    $appInstallerDir = Join-Path $runtimeDir 'appinstaller'
    $pieceResults = Assert-OSyncAppInstallerHashes -Config $Config -Dir $appInstallerDir

    # --- 3.5 bun payload (config.pins.bun - presence-gated; bun is NOT a
    # category, and pins.bun is NEVER a required key: its absence disables
    # bun entirely). Runs BEFORE the heavy Python/Node winget downloads so a
    # PIN-ME iteration never re-downloads them. Mirrors the chezmoi PIN-ME
    # flow (DotfilesExport.ps1 step 4) exactly. ---
    $bunResult = $null
    if (Test-OSyncBunEnabled -Config $Config) {
        $runtimeBunDir = Join-Path $runtimeDir 'bun'
        $zipPath = Join-Path $runtimeBunDir 'bun.zip'
        if (-not (Test-Path -LiteralPath $runtimeBunDir -PathType Container)) {
            New-Item -ItemType Directory -Path $runtimeBunDir -Force | Out-Null
        }
        $bunUrl = [string]$Config.pins.bun.url
        $bunVersion = [string]$Config.pins.bun.version
        $expected = [string]$Config.pins.bun.sha256
        $isPinMe = ($expected -eq 'PIN-ME')

        # Download only when the zip is missing: a PIN-ME run followed by a
        # pinned re-run (same staging dir) performs exactly ONE download,
        # and a retry after a hash failure does not re-fetch the same bytes.
        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
            Write-OSyncLog -Category 'runtime' -Level Info -Message "Downloading bun from '$bunUrl' -> '$zipPath'" -Config $Config | Out-Null
            $null = Invoke-OSyncDownload -Uri $bunUrl -OutFile $zipPath
        }
        else {
            Write-OSyncLog -Category 'runtime' -Level Info -Message "Reusing existing download '$zipPath'" -Config $Config | Out-Null
        }

        $actualHash = Get-OSyncFileSha256 -Path $zipPath

        if ($isPinMe) {
            # PIN-ME: print the actual hash and exit non-zero (prompt to pin).
            Write-Host "Export-OSyncRuntime: config.pins.bun.sha256 is 'PIN-ME'."
            Write-Host "Actual sha256 of '$zipPath' is: $actualHash"
            Write-Host 'Pin it into config\packagesync.json (pins.bun.sha256) and re-run.'
            Write-OSyncLog -Category 'runtime' -Level Error -Message "PIN-ME: actual bun sha256 is $actualHash - pin it into the config and re-run." -Data @{ actualSha256 = $actualHash } -Config $Config | Out-Null
            throw "Export-OSyncRuntime: config.pins.bun.sha256 is 'PIN-ME' - pin the real sha256 ($actualHash) into config\packagesync.json and re-run."
        }

        if ($actualHash -ne $expected) {
            Write-OSyncLog -Category 'runtime' -Level Error -Message "bun sha256 mismatch: expected '$expected', got '$actualHash'." -Data @{ expected = $expected; actual = $actualHash } -Config $Config | Out-Null
            throw "Export-OSyncRuntime: bun sha256 mismatch for '$zipPath': expected '$expected', got '$actualHash'. Aborting - the download is not the pinned artifact."
        }

        $bunExePath = Expand-OSyncBunZip -ZipPath $zipPath -Destination $runtimeBunDir
        $versionTxt = Join-Path $runtimeBunDir 'version.txt'
        # UTF8 with NO BOM (UTF8Encoding($false)): version.txt is the B-side
        # version-expectation source (the B config has no pins.bun).
        [System.IO.File]::WriteAllText($versionTxt, $bunVersion, (New-Object System.Text.UTF8Encoding($false)))
        Write-OSyncLog -Category 'runtime' -Level Info -Message "bun.exe extracted to '$bunExePath' (sha256 $actualHash, version $bunVersion)" -Data @{ sha256 = $actualHash; version = $bunVersion } -Config $Config | Out-Null

        $bunResult = [pscustomobject]@{
            version    = $bunVersion
            url        = $bunUrl
            sha256     = $actualHash
            zipPath    = $zipPath
            exePath    = $bunExePath
            versionTxt = $versionTxt
        }
    }
    else {
        Write-OSyncLog -Category 'runtime' -Level Info -Message 'bun payload skipped (pins.bun absent)' -Config $Config | Out-Null
    }

    # --- 4. runtime winget entries (reuse todo 6 download+rewrite) ---
    $entries = @(Read-OSyncWingetList -Path $runtimeWingetPath)
    $wingetResult = Invoke-OSyncRuntimeWingetExport -ParsedList $entries -StagingDir $StagingDir -Config $Config -WingetExePath $WingetExePath

    # --- 5. portable Verdaccio ---
    $verdaccioVersion = [string]$Config.pins.npm.verdaccioVersion
    if ([string]::IsNullOrWhiteSpace($verdaccioVersion) -or $verdaccioVersion -eq 'PIN-ME') {
        throw "Export-OSyncRuntime: config key 'pins.npm.verdaccioVersion' must be a pinned x.y.z version (got '$verdaccioVersion')."
    }
    # The npm install runs with a LOCAL --prefix: npm's arborist
    # 'realpathCached' infinitely recurses on UNC prefixes (RangeError:
    # Maximum call stack size exceeded, reproduced with a UNC stagingRoot).
    # <staging>\runtime\verdaccio is only ever written via robocopy below.
    $buildDir = Get-ORuntimeVerdaccioBuildDir
    $verdaccioDir = Join-Path $runtimeDir 'verdaccio'
    $npmExe = Get-ORuntimeNpmExe
    # consoleEcho is an in-memory-only flag pinned by the export orchestrator
    # (absent/false on B-side configs -> silent, same as WingetExport.ps1).
    $echoOn = ($null -ne $Config -and $Config.PSObject.Properties['consoleEcho'] -and [bool]$Config.consoleEcho)
    $installResult = Invoke-ORuntimeNpmInstall -NpmExe $npmExe -Version $verdaccioVersion -Prefix $buildDir -Echo $echoOn
    if ($installResult.ExitCode -ne 0) {
        $tail = ((@($installResult.Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5) -join '; ')
        throw "Export-OSyncRuntime: 'npm install verdaccio@$verdaccioVersion' failed (exit $($installResult.ExitCode)): $tail"
    }
    $null = Invoke-OSyncRobocopy -Source $buildDir -Destination $verdaccioDir -ExtraArgs @('/E')
    # Remove the LOCAL build dir. node_modules paths can exceed MAX_PATH (260
    # chars); delete via the \\?\ long-path prefix (verified, todo 8).
    if (Test-Path -LiteralPath $buildDir -PathType Container) {
        try {
            $longPath = '\\?\' + (Resolve-Path -LiteralPath $buildDir).Path
            [System.IO.Directory]::Delete($longPath, $true)
        }
        catch {
            Write-Warning "Export-OSyncRuntime: could not remove verdaccio build dir '$buildDir': $($_.Exception.Message)"
        }
    }
    $verdaccioBin = Join-Path $verdaccioDir 'node_modules\verdaccio\bin\verdaccio'
    if (-not (Test-Path -LiteralPath $verdaccioBin -PathType Leaf)) {
        throw "Export-OSyncRuntime: verdaccio entry script not found after install: '$verdaccioBin'."
    }
    Write-OSyncLog -Category 'runtime' -Level Info -Message "portable verdaccio@$verdaccioVersion staged at '$verdaccioDir' (bin: '$verdaccioBin')." -Config $Config | Out-Null

    # --- 6. copy runtime-winget.txt into the runtime payload ---
    $runtimeTxtTarget = Join-Path $runtimeDir 'runtime-winget.txt'
    Copy-Item -LiteralPath $runtimeWingetPath -Destination $runtimeTxtTarget -Force

    # --- 7. tool self-bootstrap snapshot ---
    if ([string]::IsNullOrWhiteSpace($ToolSourceDir)) {
        $ToolSourceDir = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    }
    $toolDir = Join-Path $runtimeDir 'tool'
    $toolSrcDir = Join-Path $toolDir 'src'
    $null = Invoke-OSyncRobocopy -Source (Join-Path $ToolSourceDir 'src') -Destination $toolSrcDir -ExtraArgs @('/E')
    $toolConfigPath = Join-Path $toolDir 'packagesync.b.json'
    Copy-Item -LiteralPath (Join-Path $ToolSourceDir 'config\packagesync.b.json') -Destination $toolConfigPath -Force
    $toolReadmePath = $null
    $readmeSource = Join-Path $ToolSourceDir 'README.md'
    if (Test-Path -LiteralPath $readmeSource -PathType Leaf) {
        $toolReadmePath = Join-Path $toolDir 'README.md'
        Copy-Item -LiteralPath $readmeSource -Destination $toolReadmePath -Force
    }

    # --- report ---
    $report = [pscustomobject]@{
        category = 'runtime'
        status   = 'ok'
        runtimeWinget = [pscustomobject]@{
            path     = $runtimeWingetPath
            python   = $pythonVersion
            node     = $nodeVersion
            exported = @($wingetResult.ok)
            failed   = @($wingetResult.failed)
        }
        pipCrossAssert = $cross
        appInstaller = [pscustomobject]@{
            dir    = $appInstallerDir
            pieces = @($pieceResults)
        }
        bun = $bunResult
        verdaccio = [pscustomobject]@{
            version = $verdaccioVersion
            dir     = $verdaccioDir
            bin     = $verdaccioBin
            launch  = 'node.exe <dir>\node_modules\verdaccio\bin\verdaccio --config <yml>'
        }
        runtimeWingetTxt = $runtimeTxtTarget
        tool = [pscustomobject]@{
            dir    = $toolDir
            src    = $toolSrcDir
            config = $toolConfigPath
            readme = $toolReadmePath
        }
    }

    Write-OSyncLog -Category 'runtime' -Level Info -Message ("runtime export complete: {0} winget entry(ies) exported, {1} failed, appInstaller piece(s) verified, verdaccio@{2} staged." -f $wingetResult.ok.Count, $wingetResult.failed.Count, $verdaccioVersion) -Config $Config | Out-Null

    return $report
}