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

    3. App Installer pieces + VC_redist (config.pins.appInstaller) into
       <staging>\runtime\appinstaller\ with the per-piece sha256 PIN-ME flow
       (same semantics as todo 9 / DotfilesExport):
         - any piece still 'PIN-ME' -> prints ALL real hashes and exits
           non-zero (the operator pins all four and re-runs),
         - hash mismatch -> aborts naming the file (expected vs actual),
         - match -> proceeds.
       The UI.Xaml piece is downloaded as the official nuget package
       (https://www.nuget.org/api/v2/package/Microsoft.UI.Xaml/2.8.6 - a
       nupkg IS a zip) and the Tools\AppX\x64\Release\Microsoft.UI.Xaml.2.8.appx
       entry is extracted; the pinned hash is the hash of the EXTRACTED appx
       (that is what gets installed on B).
       Static version-match fallback (Oracle m3): the msixbundle is a zip -
       its AppxManifest.xml PackageDependency MinVersion values are compared
       against the actual VCLibs/UI.Xaml appx Identity versions. The real
       install chain cannot execute on A, so this static check is the only
       verification available; the result is recorded in the report (a
       mismatch is a warning, not fatal - the B-side bootstrap has its own
       version gates).

    4. Runtime winget entries: REUSES todo 6's download+rewrite functions
       (Invoke-OSyncWingetDownload / ConvertTo-OSyncWingetYamlContent /
       Test-OSyncWingetYamlNoLeak / Resolve-OSyncWingetExePath from
       WingetExport.ps1) to export each runtime-winget.txt entry into
       <staging>\winget\<Id>\ - the same shape as the winget category, for
       the B-side bootstrap. NO packages.txt is written here: the runtime
       entries are tracked by <staging>\runtime\runtime-winget.txt and the
       winget category's packages.txt must keep only its own entries
       (todo 13 excludes the runtime IDs from it).

    5. Portable Verdaccio: npm install --prefix <temp build dir>
       verdaccio@<pins.npm.verdaccioVersion> -> robocopy to
       <staging>\runtime\verdaccio\ (the build dir is removed afterwards).
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

function Resolve-ORuntimePath {
    <#
      Resolves a config.paths.* value: used verbatim when it exists as a
      file (handles absolute test paths), otherwise resolved against the
      repo root derived from this module's location (src\lib -> two levels
      up). Same semantics as NpmExport's Resolve-OPathForConfig.
    #>
    param([string]$Configured)
    if ([string]::IsNullOrWhiteSpace($Configured)) { return $null }
    if (Test-Path -LiteralPath $Configured -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Configured).Path
    }
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    $candidate = Join-Path $repoRoot $Configured
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }
    return $candidate
}

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
      Returns the four appInstaller piece definitions (name, url, target
      file, optional zip-entry extraction source). The UI.Xaml piece is
      downloaded as the official nuget package (a nupkg IS a zip) and the
      appx entry is extracted from it; the pinned hash is the hash of the
      EXTRACTED appx.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $pins = $Config.pins.appInstaller
    return @(
        [pscustomobject]@{
            Name     = 'msixbundle'
            Url      = [string]$pins.msixbundleUrl
            File     = 'Microsoft.DesktopAppInstaller.msixbundle'
            Expected = [string]$pins.msixbundleSha256
            Extract  = $null
        },
        [pscustomobject]@{
            Name     = 'vclibs'
            Url      = [string]$pins.vcLibsUrl
            File     = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
            Expected = [string]$pins.vcLibsSha256
            Extract  = $null
        },
        [pscustomobject]@{
            Name     = 'uixaml'
            Url      = [string]$pins.uiXamlUrl
            File     = 'Microsoft.UI.Xaml.2.8.appx'
            Expected = [string]$pins.uiXamlSha256
            # Observed entry name in the Microsoft.UI.Xaml/2.8.6 nupkg
            # (2026-09-04 QA): 'tools/AppX/x64/Release/Microsoft.UI.Xaml.2.8.appx'
            # - FORWARD slashes, lowercase 'tools' (zip entry names always
            # use '/'; the -ieq comparison in Expand-OSyncZipEntry handles
            # case).
            Extract  = 'tools/AppX/x64/Release/Microsoft.UI.Xaml.2.8.appx'
        },
        [pscustomobject]@{
            Name     = 'vcredist'
            Url      = [string]$pins.vcRedistUrl
            File     = 'VC_redist.x64.exe'
            Expected = [string]$pins.vcRedistSha256
            Extract  = $null
        }
    )
}

function Expand-OSyncZipEntry {
    <#
      Extracts ONE entry from a zip to a target file (overwrite). Throws
      when the entry is missing. Used for the UI.Xaml appx inside the nuget
      package.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$EntryName,

        [Parameter(Mandatory = $true)]
        [string]$Target
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -ieq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) {
            throw "Expand-OSyncZipEntry: entry '$EntryName' not found in '$ZipPath'."
        }
        $parent = Split-Path -Parent $Target
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $Target, $true)
        return $Target
    }
    finally {
        $zip.Dispose()
    }
}

function Read-OSyncZipEntryText {
    <#
      Reads ONE entry of a zip as text (UTF-8). Returns $null when the entry
      is missing. Used for the AppxManifest.xml static version check.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ZipPath,

        [Parameter(Mandatory = $true)]
        [string]$EntryName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -ieq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) { return $null }
        $reader = New-Object System.IO.StreamReader($entry.Open())
        try {
            return $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Assert-OSyncAppInstallerHashes {
    <#
      Downloads (download-if-missing) all four appInstaller pieces into
      <Dir>, computes their sha256, and enforces the PIN-ME flow per piece
      (same semantics as todo 9):
        - any piece still 'PIN-ME' -> prints ALL real hashes and throws
          (non-zero exit; the operator pins all four and re-runs),
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
        $downloadTarget = $target
        if (-not [string]::IsNullOrWhiteSpace($piece.Extract)) {
            # The UI.Xaml piece: download the nupkg, extract the appx entry.
            $nupkg = Join-Path $Dir ('{0}.nupkg' -f [System.IO.Path]::GetFileNameWithoutExtension($piece.File))
            $downloadTarget = $nupkg
        }

        if (-not (Test-Path -LiteralPath $downloadTarget -PathType Leaf)) {
            Write-OSyncLog -Category 'runtime' -Level Info -Message ("Downloading appInstaller piece {0} from '{1}' -> '{2}'" -f $piece.Name, $piece.Url, $downloadTarget) -Config $Config | Out-Null
            $null = Invoke-OSyncDownload -Uri $piece.Url -OutFile $downloadTarget
        }
        else {
            Write-OSyncLog -Category 'runtime' -Level Info -Message ("Reusing existing download '{0}'" -f $downloadTarget) -Config $Config | Out-Null
        }

        if (-not [string]::IsNullOrWhiteSpace($piece.Extract)) {
            $null = Expand-OSyncZipEntry -ZipPath $downloadTarget -EntryName $piece.Extract -Target $target
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
        Write-Host 'Pin all four real sha256 values into config\packagesync.json (pins.appInstaller.*Sha256) and re-run.'
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

function Get-OSyncBundleManifestText {
    <#
      Reads the AppxManifest.xml of an App Installer msixbundle. Observed
      layout (2026-09-04 QA, App Installer 1.29.290.0): the bundle has NO
      AppxManifest.xml at its root - the manifest lives inside the inner
      architecture msix (AppInstaller_x64.msix, itself a zip). The root
      entry is tried first (older bundles carry it), then the inner x64 msix
      is extracted to a temp file and its manifest is read. Returns $null
      when neither exists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BundlePath
    )

    $root = Read-OSyncZipEntryText -ZipPath $BundlePath -EntryName 'AppxManifest.xml'
    if ($null -ne $root) { return $root }

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zip = [System.IO.Compression.ZipFile]::OpenRead($BundlePath)
    $inner = $null
    $tmp = $null
    try {
        $inner = $zip.Entries | Where-Object {
            $_.FullName -match '\.msix$' -and
            $_.FullName -match 'x64' -and
            $_.FullName -notmatch 'language'
        } | Sort-Object -Property FullName | Select-Object -First 1
        if ($null -eq $inner) { return $null }
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-bundle-' + [guid]::NewGuid().ToString('N') + '.msix')
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($inner, $tmp, $true)
    }
    finally {
        $zip.Dispose()
    }
    try {
        return (Read-OSyncZipEntryText -ZipPath $tmp -EntryName 'AppxManifest.xml')
    }
    finally {
        if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force }
    }
}

function Test-OSyncAppInstallerVersionMatch {
    <#
      Static version-match fallback (Oracle m3): the msixbundle is a zip -
      its AppxManifest.xml PackageDependency MinVersion values are compared
      against the actual VCLibs/UI.Xaml appx Identity versions. The real
      install chain cannot execute on A, so this static check is the only
      verification available. Returns { Ok, Checks[], Reason } - a mismatch
      is recorded (the caller logs a warning), not fatal: the B-side
      bootstrap has its own version gates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Dir
    )

    $bundlePath = Join-Path $Dir 'Microsoft.DesktopAppInstaller.msixbundle'
    $vclibsPath = Join-Path $Dir 'Microsoft.VCLibs.x64.14.00.Desktop.appx'
    $uixamlPath = Join-Path $Dir 'Microsoft.UI.Xaml.2.8.appx'

    if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Checks = @(); Reason = "msixbundle not found at '$bundlePath'" }
    }

    $bundleManifest = Get-OSyncBundleManifestText -BundlePath $bundlePath
    if ($null -eq $bundleManifest) {
        return [pscustomobject]@{ Ok = $false; Checks = @(); Reason = "no AppxManifest.xml found in the msixbundle '$bundlePath' (neither at the root nor inside an inner x64 msix)" }
    }

    # <PackageDependency Name="..." MinVersion="..." .../>
    $deps = @()
    foreach ($m in [regex]::Matches($bundleManifest, '<PackageDependency\b[^>]*>')) {
        $tag = $m.Value
        $nameM = [regex]::Match($tag, 'Name="([^"]+)"')
        $verM = [regex]::Match($tag, 'MinVersion="([^"]+)"')
        if ($nameM.Success -and $verM.Success) {
            $deps += [pscustomobject]@{ Name = $nameM.Groups[1].Value; MinVersion = $verM.Groups[1].Value }
        }
    }

    $checks = @()
    $ok = $true

    foreach ($piece in @(
            # Identity names observed on the real payloads (2026-09-04 QA):
            # the aka.ms VCLibs appx is the UWPDesktop variant; the nuget
            # UI.Xaml appx is Microsoft.UI.Xaml.2.8.
            [pscustomobject]@{ Name = 'Microsoft.VCLibs.140.00.UWPDesktop'; AppxPath = $vclibsPath; Label = 'vclibs' },
            [pscustomobject]@{ Name = 'Microsoft.UI.Xaml.2.8'; AppxPath = $uixamlPath; Label = 'uixaml' })) {

        $dep = $deps | Where-Object { $_.Name -ieq $piece.Name } | Select-Object -First 1
        if ($null -eq $dep) {
            $checks += [pscustomobject]@{
                Piece         = $piece.Label
                Dependency    = $piece.Name
                MinVersion    = $null
                ActualVersion = $null
                Match         = $null
                Note          = 'not listed as a dependency of the msixbundle'
            }
            continue
        }

        $actualVersion = $null
        if (Test-Path -LiteralPath $piece.AppxPath -PathType Leaf) {
            $appxManifest = Read-OSyncZipEntryText -ZipPath $piece.AppxPath -EntryName 'AppxManifest.xml'
            if ($null -ne $appxManifest) {
                $idM = [regex]::Match($appxManifest, '<Identity\b[^>]*Version="([^"]+)"')
                if ($idM.Success) { $actualVersion = $idM.Groups[1].Value }
            }
        }

        $match = $null
        if ($null -ne $actualVersion) {
            try {
                $match = ([version]$actualVersion -ge [version]$dep.MinVersion)
            }
            catch {
                $match = $null
            }
        }
        if ($match -eq $false) { $ok = $false }
        $checks += [pscustomobject]@{
            Piece         = $piece.Label
            Dependency    = $piece.Name
            MinVersion    = $dep.MinVersion
            ActualVersion = $actualVersion
            Match         = $match
            Note          = ''
        }
    }

    return [pscustomobject]@{ Ok = $ok; Checks = @($checks); Reason = '' }
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

        $result = Invoke-OSyncWingetDownload -WingetExe $wingetExe -Arguments $downloadArgs

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
        [string]$Prefix
    )

    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # --prefix is passed UNQUOTED: PowerShell 5.1 quotes native args with
        # spaces itself; pre-embedding quotes makes npm treat them as part of
        # the path (observed: 'CWD\"C:\path"' -> ENOENT). --prefix stays LAST
        # (contract for the fake npm used in unit tests).
        $output = @(& $NpmExe install "verdaccio@$Version" --no-audit --no-fund --loglevel error --prefix $Prefix 2>&1)
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

    # --- 1. validate manifests\runtime-winget.txt ---
    $runtimeWingetPath = Resolve-ORuntimePath -Configured $Config.paths.runtimeWhitelist
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

    # --- 3. App Installer pieces + VC_redist (PIN-ME flow) ---
    $runtimeDir = Join-Path $StagingDir 'runtime'
    $appInstallerDir = Join-Path $runtimeDir 'appinstaller'
    $pieceResults = Assert-OSyncAppInstallerHashes -Config $Config -Dir $appInstallerDir
    $versionMatch = Test-OSyncAppInstallerVersionMatch -Dir $appInstallerDir
    if (-not $versionMatch.Ok) {
        $detail = ($versionMatch.Checks | ForEach-Object { "{0}: min {1} vs actual {2} (match={3})" -f $_.Piece, $_.MinVersion, $_.ActualVersion, $_.Match }) -join '; '
        Write-OSyncLog -Category 'runtime' -Level Warning -Message "appInstaller static version-match: $detail" -Config $Config | Out-Null
    }
    else {
        Write-OSyncLog -Category 'runtime' -Level Info -Message 'appInstaller static version-match: all bundle dependencies satisfied by the shipped pieces.' -Config $Config | Out-Null
    }

    # --- 4. runtime winget entries (reuse todo 6 download+rewrite) ---
    $entries = @(Read-OSyncWingetList -Path $runtimeWingetPath)
    $wingetResult = Invoke-OSyncRuntimeWingetExport -ParsedList $entries -StagingDir $StagingDir -Config $Config -WingetExePath $WingetExePath

    # --- 5. portable Verdaccio ---
    $verdaccioVersion = [string]$Config.pins.npm.verdaccioVersion
    if ([string]::IsNullOrWhiteSpace($verdaccioVersion) -or $verdaccioVersion -eq 'PIN-ME') {
        throw "Export-OSyncRuntime: config key 'pins.npm.verdaccioVersion' must be a pinned x.y.z version (got '$verdaccioVersion')."
    }
    $buildDir = Join-Path $runtimeDir '.verdaccio-build'
    $verdaccioDir = Join-Path $runtimeDir 'verdaccio'
    $npmExe = Get-ORuntimeNpmExe
    $installResult = Invoke-ORuntimeNpmInstall -NpmExe $npmExe -Version $verdaccioVersion -Prefix $buildDir
    if ($installResult.ExitCode -ne 0) {
        $tail = ((@($installResult.Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5) -join '; ')
        throw "Export-OSyncRuntime: 'npm install verdaccio@$verdaccioVersion' failed (exit $($installResult.ExitCode)): $tail"
    }
    $null = Invoke-OSyncRobocopy -Source $buildDir -Destination $verdaccioDir -ExtraArgs @('/E')
    # Remove the build dir. node_modules paths can exceed MAX_PATH (260
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
            dir          = $appInstallerDir
            pieces       = @($pieceResults)
            versionMatch = $versionMatch
        }
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

    Write-OSyncLog -Category 'runtime' -Level Info -Message ("runtime export complete: {0} winget entry(ies) exported, {1} failed, appInstaller pieces verified, verdaccio@{2} staged." -f $wingetResult.ok.Count, $wingetResult.failed.Count, $verdaccioVersion) -Config $Config | Out-Null

    return $report
}