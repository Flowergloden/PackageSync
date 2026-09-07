#Requires -Version 5.1
<#
  NpmExport.ps1 - A-side npm export: one-shot Verdaccio warm-up + storage snapshot.

  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Export-OSyncNpm -Config -StagingDir [-ConfigPath]

    1. Version pinning (pin-in-place, Oracle m4): when config.pins.npm.verdaccioVersion
       is 'PIN-ME', the real latest version is resolved via `npm view verdaccio version`
       (A has internet) and written back into the config file before it is used.
    2. `npm install --prefix <stagingRoot>\.verdaccio-a verdaccio@<pinned>`.
    3. Generates verdaccio-a.yml next to that install (NOT under <staging>\npm, so the
       A-side-only config never ships to B): storage -> <staging>\npm\storage, uplink
       npmjs (https://registry.npmjs.org), listen 127.0.0.1:<npm.aVerdaccioPort>.
    4. Starts the one-shot instance, waits for the port to LISTEN (30 s timeout), then
       for every entry of the npm package list runs
       `npm install <name@ver> --registry http://127.0.0.1:<aPort> --prefix <temp dir>`
       with a FRESH --cache per export (so every tarball is really pulled through the
       one-shot registry into storage). The server is then stopped in a finally block
       so the snapshot is guaranteed still - we never reuse an operator's daily
       Verdaccio (Metis m7).
    5. Generates <staging>\npm\verdaccio-b.yml: storage is the RELATIVE path ./storage
       (Verdaccio resolves it against the config file location; the B-side local copy
       uses the same layout, Oracle M5). It MUST NOT contain uplinks/proxy keys,
       packages '**' has only access: $all, listen 127.0.0.1:<verdaccioPort>, web UI
       disabled. Copies manifests\npm-packages.txt -> <staging>\npm\packages.txt
       (delivery contract, the B-side health check reads it).
    6. Export-time assertion: verdaccio-b.yml content must not match uplinks|proxy and
       must contain a line matching ^\s*storage:\s*\./storage\s*$ (Oracle M5).
    7. Cross-assertion (fail-fast, before any heavy work): `npm view verdaccio@<pinned>
       engines` node requirement must be compatible with the pinned Node major in
       manifests\runtime-winget.txt. Mismatch -> export fails (Oracle r4-m4).

    Per-package failures are recorded in the report (failed array) and do not abort
    the remaining packages, mirroring the winget/pip export contract.

    Must NOT: never `npm pack` (no dependency tree), never `npm install --offline`.

  Returns a report object:
    category, verdaccioVersion, nodeEngines, nodeCompat, aPort, storageDir,
    bConfig, packagesTxt, warmed (array of ok entries), failed (array of failed
    entries with error text).
#>

function Get-ONpmExe {
    # Resolves the npm executable (npm.cmd on Windows). Throws when npm is
    # not available - the export cannot work without it (Oracle m7).
    $cmd = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        throw "Export-OSyncNpm: 'npm' was not found on PATH - npm is required for the Verdaccio warm-up."
    }
    return $cmd.Source
}

function Get-ONodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        throw "Export-OSyncNpm: 'node' was not found on PATH - node.exe is required to run the one-shot Verdaccio."
    }
    return $cmd.Source
}

function Resolve-OSyncNpmVerdaccioVersion {
    <#
      Returns the verdaccio version to install. A non-'PIN-ME' value is passed
      through untouched; 'PIN-ME' resolves the real latest version from npmjs
      (`npm view verdaccio version` - A has internet). Throws when npm fails
      or the output is not a x.y.z version.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ($Version -ne 'PIN-ME') { return $Version }

    $npmExe = Get-ONpmExe
    $output = @(& $npmExe view verdaccio version 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $tail = ((@($output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 3) -join '; ')
        throw "Export-OSyncNpm: 'npm view verdaccio version' failed (exit $LASTEXITCODE): $tail"
    }
    # Take the last non-empty line: npm prints progress/warnings on stderr.
    $lines = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) {
        throw "Export-OSyncNpm: 'npm view verdaccio version' returned no version output."
    }
    $resolved = ([string]$lines[$lines.Count - 1]).Trim()
    if ($resolved -notmatch '^\d+\.\d+\.\d+') {
        throw "Export-OSyncNpm: unexpected version output from 'npm view verdaccio version': '$resolved'."
    }
    return $resolved
}

function Write-OSyncNpmPin {
    <#
      Writes the resolved verdaccio version back into a packagesync JSON
      config (pin-in-place). A targeted text replacement keeps the file
      formatting byte-identical apart from the one value; when the literal
      key is not found it falls back to a full object round-trip through
      ConvertTo-OSyncJson (-Depth 10). The UTF-8 BOM state of the original
      file is preserved.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    if ($Version -notmatch '^\d+\.\d+\.\d+') {
        throw "Write-OSyncNpmPin: refusing to pin a non-semver verdaccio version: '$Version'."
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Write-OSyncNpmPin: config file not found: '$ConfigPath'."
    }

    $fullPath = (Resolve-Path -LiteralPath $ConfigPath).Path
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)

    if ($text.Contains('"verdaccioVersion"')) {
        # Targeted replace: '"verdaccioVersion": "PIN-ME"' -> real version.
        # Group 1 captures the key + colon + original spacing.
        $pattern = '("verdaccioVersion"\s*:\s*)"[^"]*"'
        $replacement = '${1}"' + $Version + '"'
        $newText = [regex]::Replace($text, $pattern, $replacement, 1)
    }
    else {
        # Fallback: full read-modify-write (acceptable formatting change).
        $obj = $text | ConvertFrom-Json
        if ($null -eq $obj.pins -or $null -eq $obj.pins.npm) {
            throw "Write-OSyncNpmPin: config '$ConfigPath' has no pins.npm section to update."
        }
        # Add-Member -Force: the parsed PSCustomObject cannot grow new
        # properties by plain assignment (PS 5.1 SetValueInvocationException).
        $obj.pins.npm | Add-Member -NotePropertyName verdaccioVersion -NotePropertyValue $Version -Force
        $newText = ConvertTo-OSyncJson -InputObject $obj
    }

    $outBytes = [System.Text.Encoding]::UTF8.GetBytes($newText)
    if ($hasBom) {
        $withBom = New-Object byte[] ($outBytes.Length + 3)
        [Array]::Copy($outBytes, 0, $withBom, 3, $outBytes.Length)
        $withBom[0] = 0xEF; $withBom[1] = 0xBB; $withBom[2] = 0xBF
        $outBytes = $withBom
    }
    [System.IO.File]::WriteAllBytes($fullPath, $outBytes)
}

function New-OSyncVerdaccioAYaml {
    <#
      Generates the one-shot warm-up registry config (A side, online).
      storage points at the export staging storage dir, npmjs uplink proxies
      everything, listen binds the one-shot A port (default 4874). The web UI
      is left at the default (bundled plugin, harmless for the one-shot).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StorageDir,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory = $false)]
        [string]$UplinkUrl = 'https://registry.npmjs.org'
    )

    # Forward slashes: js-yaml and Node both accept them on Windows and they
    # avoid any YAML escape pitfalls with backslashes.
    $storage = $StorageDir.Replace('\', '/')

    $yaml = @'
# PakageSync one-shot warm-up registry (A side, ONLINE).
# Generated by Export-OSyncNpm. This instance exists only for the duration of
# one export: it caches the full dependency tree into the storage dir below,
# then it is stopped so the storage snapshot is guaranteed still.
storage: __STORAGE__
uplinks:
  npmjs:
    url: __UPLINK__
packages:
  '@*/*':
    access: $all
    proxy: npmjs
  '**':
    access: $all
    proxy: npmjs
listen: __LISTEN__
'@
    return $yaml.Replace('__STORAGE__', $storage).Replace('__UPLINK__', $UplinkUrl).Replace('__LISTEN__', "127.0.0.1:$Port")
}

function New-OSyncVerdaccioBYaml {
    <#
      Generates the offline registry config for the B side. Storage is the
      RELATIVE path ./storage - Verdaccio resolves it against the directory
      containing this config file, and the B-side local copy keeps the same
      layout (<stateDir>\verdaccio\verdaccio-b.yml + .\storage, Oracle M5).
      There are NO uplinks and NO proxy entries on purpose: on an air-gapped
      B, a request for a package that is not in the snapshot must fail fast
      instead of hanging on an unreachable upstream. Web UI is disabled.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $yaml = @'
# PakageSync offline npm registry config (B side, OFFLINE).
# storage is RELATIVE to this file's location (Verdaccio resolves it against
# the directory containing the config), so this file and ./storage must
# travel together - the B-side local copy uses the same layout.
# No uplinks / no proxy keys by design: on an air-gapped B a request for a
# package that is not in the snapshot must fail fast, never hang upstream.
storage: ./storage
packages:
  '**':
    access: $all
listen: __LISTEN__
web:
  enable: false
'@
    return $yaml.Replace('__LISTEN__', "127.0.0.1:$Port")
}

function Test-OSyncVerdaccioBYaml {
    <#
      The export-time leak assertion (Oracle M5). Returns $true only when:
        - the content contains NO uplinks:/proxy: key (line-start match,
          case-insensitive; comments are not false positives), and
        - it contains a line matching ^\s*storage:\s*\./storage\s*$.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }
    if ($Content -match '(?im)^\s*(uplinks|proxy)\s*:') { return $false }
    if ($Content -notmatch '(?m)^\s*storage:\s*\./storage\s*$') { return $false }
    return $true
}

function Get-ONodeRangeCompat {
    <#
      Pure range check (no I/O): does the pinned node MAJOR version satisfy
      an engines.node range string? Conservative major-level semantics:
        '18' / '18.x' / '^18' / '~18.2' -> exactly major 18
        '>=18.5.0' -> lower 18 (no upper)
        '>=12 <25'  -> lower 12, upper 24
        '<24' -> upper 23 (strict), '<=24' -> upper 24
        '' or '*' -> no constraint (compatible)
      An unparsable non-empty range is INCOMPATIBLE (fail-safe direction,
      Oracle r4-m4: we must never silently bless an unknown constraint).
    #>
    param([string]$Range, [int]$Major)

    if ([string]::IsNullOrWhiteSpace($Range) -or $Range.Trim() -eq '*') {
        return [pscustomobject]@{ Compatible = $true; Reason = 'no node engine constraint' }
    }

    $range = $Range.Trim()
    $lower = -1
    $upper = [int]::MaxValue

    # Bare version ('18', '18.x', '18.x.x') or caret/tilde ('^18', '~18.2').
    if ($range -match '^[~^]?\s*(\d+)(\.([x*]|\d+))*(\.([x*]|\d+))?$') {
        $exact = [int]$Matches[1]
        $lower = $exact
        $upper = $exact
    }
    else {
        # >= / > (major-level: both mean "at least major N").
        foreach ($m in [regex]::Matches($range, '>=\s*(\d+)')) {
            $lower = [Math]::Max($lower, [int]$m.Groups[1].Value)
        }
        foreach ($m in [regex]::Matches($range, '(?<![>=])\s*>\s*(\d+)')) {
            $lower = [Math]::Max($lower, [int]$m.Groups[1].Value)
        }
        # <= / < (strict <N excludes major N -> upper N-1).
        foreach ($m in [regex]::Matches($range, '(?<op><=?)\s*(\d+)')) {
            $n = [int]$m.Groups[1].Value
            $bound = $n
            if ($m.Groups['op'].Value -eq '<') { $bound = $n - 1 }
            $upper = [Math]::Min($upper, $bound)
        }
    }

    if ($lower -eq -1) {
        return [pscustomobject]@{
            Compatible = $false
            Reason     = "cannot parse the node engine range '$Range'"
        }
    }
    if ($Major -lt $lower) {
        return [pscustomobject]@{ Compatible = $false; Reason = "node $Major < required major $lower" }
    }
    if ($Major -gt $upper) {
        return [pscustomobject]@{ Compatible = $false; Reason = "node $Major > allowed major $upper" }
    }
    return [pscustomobject]@{ Compatible = $true; Reason = 'ok' }
}

function Test-OSyncNpmNodeCompat {
    <#
      Cross-assertion (Oracle r4-m4): `npm view verdaccio@<version> engines`
      node requirement must be compatible with the pinned Node major version
      from manifests\runtime-winget.txt. Missing engine data counts as
      compatible (no constraint); an unparsable constraint counts as
      incompatible. Returns { Compatible, EnginesNode, PinnedNodeMajor,
      Reason } - the caller decides how to fail.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VerdaccioVersion,

        [Parameter(Mandatory = $true)]
        [int]$PinnedNodeMajor
    )

    $npmExe = Get-ONpmExe
    $output = @(& $npmExe view "verdaccio@$VerdaccioVersion" engines --json 2>&1)
    $candidates = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $jsonText = ($output -join "`n").Trim()

    $enginesNode = $null
    $parsed = $null
    $parsedOk = $false
    if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
        # npm prints the JSON on its own line; warnings (if any) come first.
        # Try the whole text, then fall back to scanning lines last-to-first.
        try {
            $parsed = $jsonText | ConvertFrom-Json
            $parsedOk = $true
        }
        catch {
            $parsedOk = $false
        }
        if (-not $parsedOk) {
            for ($k = $candidates.Count - 1; $k -ge 0; $k--) {
                try {
                    $parsed = ([string]$candidates[$k]) | ConvertFrom-Json
                    $parsedOk = $true
                    break
                }
                catch {
                    $parsedOk = $false
                }
            }
        }
        if (-not $parsedOk) {
            # Non-empty but unparsable engines output - fail-safe direction:
            # never silently bless an unknown node constraint (Oracle r4-m4).
            return [pscustomobject]@{
                Compatible      = $false
                EnginesNode     = ''
                PinnedNodeMajor = $PinnedNodeMajor
                Reason          = 'engines output is not parseable JSON'
            }
        }
        if ($null -ne $parsed -and $null -ne $parsed.node) {
            $enginesNode = [string]$parsed.node
        }
    }

    $compat = Get-ONodeRangeCompat -Range $enginesNode -Major $PinnedNodeMajor
    return [pscustomobject]@{
        Compatible      = $compat.Compatible
        EnginesNode     = if ($null -eq $enginesNode) { '' } else { $enginesNode }
        PinnedNodeMajor = $PinnedNodeMajor
        Reason          = $compat.Reason
    }
}

function Get-OPinnedNodeMajor {
    <#
      Parses the pinned Node major from manifests\runtime-winget.txt
      (OpenJS.NodeJS[.LTS]@<major>.<minor>.<patch>). Throws when the file is
      missing or has no such line - without it the engines cross-assertion
      cannot be made (fail-safe direction).
    #>
    param([Parameter(Mandatory = $true)]$Config)

    $path = Resolve-OSyncConfigPath -Config $Config -Path $Config.paths.runtimeWhitelist
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Export-OSyncNpm: runtime whitelist not found: '$path' (required for the Node engines cross-assertion)."
    }
    # Force an array: a single-line file would otherwise yield a scalar.
    $lines = @(Get-Content -LiteralPath $path -Encoding UTF8)
    foreach ($line in $lines) {
        if ([string]$line -match '^OpenJS\.NodeJS(?:\.LTS)?@(\d+)\.') {
            return [int]$Matches[1]
        }
    }
    throw "Export-OSyncNpm: '$path' contains no 'OpenJS.NodeJS[.LTS]@<ver>' entry - cannot assert verdaccio/Node engines compatibility."
}

function Test-OSyncPortListening {
    <#
      Returns $true when something is already LISTENING on the given port on
      the given bind address. Used for port hygiene: the one-shot A instance
      must never reuse a running registry (e.g. an operator's daily
      Verdaccio) and the B port (4873) is never touched by this export.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory = $false)]
        [string]$Bind = '127.0.0.1'
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($Bind, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne(300)) {
            try {
                $client.EndConnect($iar)
                return $true
            }
            catch {
                return $false
            }
        }
        return $false
    }
    finally {
        $client.Close()
    }
}

function Wait-OSyncPortListening {
    <#
      Polls the port until it LISTENS or the timeout expires. Returns $true
      when the port came up, $false on timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSeconds = 30,

        [Parameter(Mandatory = $false)]
        [string]$Bind = '127.0.0.1'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-OSyncPortListening -Port $Port -Bind $Bind) { return $true }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Get-OFileTail {
    # Last N non-empty lines of a text file (for diagnostics in errors).
    param([string]$Path, [int]$Count = 10)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    $nonEmpty = @($lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($nonEmpty.Count -le $Count) { return $nonEmpty }
    return $nonEmpty[($nonEmpty.Count - $Count)..($nonEmpty.Count - 1)]
}

function Start-OVerdaccioProcess {
    <#
      Starts the one-shot Verdaccio via node.exe and returns the process
      object (caller owns the stop). Each argument is pre-quoted so paths
      with spaces survive Start-Process. Output goes to the given log files.
    #>
    param(
        [string]$NodeExe,
        [string]$VerdaccioBin,
        [string]$ConfigPath,
        [string]$StdoutLog,
        [string]$StderrLog
    )

    if (-not (Test-Path -LiteralPath $VerdaccioBin -PathType Leaf)) {
        throw "Export-OSyncNpm: verdaccio entry script not found: '$VerdaccioBin'."
    }
    $quoted = @($VerdaccioBin, '--config', $ConfigPath) | ForEach-Object { '"' + $_ + '"' }
    $proc = Start-Process -FilePath $NodeExe -ArgumentList $quoted -PassThru `
        -WindowStyle Hidden -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog
    return $proc
}

function Stop-OVerdaccioProcess {
    <#
      Kills the one-shot Verdaccio reliably (tracked process id) and waits
      for the port to be released - the storage snapshot must be still before
      anything reads it. Idempotent: an already-exited process is a no-op.
    #>
    param($Process, [int]$Port)

    if ($null -eq $Process) { return }
    try {
        if (-not $Process.HasExited) {
            $Process.Kill()
            $Process.WaitForExit(10000) | Out-Null
        }
    }
    catch {
        # The process may have exited between HasExited and Kill - not an error.
    }
    if ($Port -gt 0) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt 10) {
            if (-not (Test-OSyncPortListening -Port $Port)) { break }
            Start-Sleep -Milliseconds 250
        }
        if (Test-OSyncPortListening -Port $Port) {
            Write-Warning "Export-OSyncNpm: port $Port still LISTENING after stopping the one-shot Verdaccio."
        }
    }
}

function Invoke-ONpmInstall {
    <#
      Runs `npm install <spec>` against the one-shot registry into a private
      temp prefix with a FRESH cache dir per export run. A fresh cache
      guarantees every tarball is really fetched through the registry (the
      global npm cache may already hold the same content-addressed tarballs
      from npmjs.org - registry-URL keying alone is not bulletproof).
      --ignore-scripts: the warm-up only needs the full dependency tree in
      storage; lifecycle scripts cannot change that tree and may fail.
      Returns @{ ExitCode = ...; Output = @(...) }.
    #>
    param(
        [string]$NpmExe,
        [string]$Spec,
        [string]$Registry,
        [string]$Prefix,
        [string]$CacheDir
    )

    # PS 5.1 gotcha: a native command writing to stderr creates an ErrorRecord
    # that THROWS under $ErrorActionPreference='Stop' (the orchestrator runs
    # with EAP=Stop). Temporarily drop to Continue so npm's stderr is captured
    # as output instead of aborting the export; the caller records it in the
    # report's failed list.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $NpmExe install $Spec --registry $Registry --prefix $Prefix --cache $CacheDir `
                --no-audit --no-fund --no-save --ignore-scripts --loglevel error 2>&1)
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = @($output)
    }
}

function Export-OSyncNpm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$StagingDir,

        # Optional: the config file to write the pin back into when
        # pins.npm.verdaccioVersion is 'PIN-ME' (pin-in-place flow).
        [Parameter(Mandatory = $false)]
        [string]$ConfigPath
    )

    $aPort = [int]$Config.npm.aVerdaccioPort
    $bPort = [int]$Config.verdaccioPort

    # Write-OSyncLog RETURNS the JSONL path - pipe to Out-Null so the export
    # report object is the ONLY thing this function emits (same pattern as
    # WingetExport.ps1).
    Write-OSyncLog -Category 'npm' -Level Info -Message "npm export starting (aPort=$aPort, bPort=$bPort)." -Config $Config | Out-Null

    # --- 1. version pinning (pin-in-place, Oracle m4) ---
    $pinned = [string]$Config.pins.npm.verdaccioVersion
    if ([string]::IsNullOrWhiteSpace($pinned)) {
        throw "Export-OSyncNpm: config key 'pins.npm.verdaccioVersion' is empty."
    }
    if ($pinned -eq 'PIN-ME') {
        $resolved = Resolve-OSyncNpmVerdaccioVersion -Version $pinned
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            Write-OSyncNpmPin -ConfigPath $ConfigPath -Version $resolved
            Write-OSyncLog -Category 'npm' -Level Info -Message "pinned pins.npm.verdaccioVersion to $resolved (written back to '$ConfigPath')." -Config $Config | Out-Null
        }
        else {
            Write-Warning "Export-OSyncNpm: pins.npm.verdaccioVersion is 'PIN-ME' and no -ConfigPath was supplied - using resolved version $resolved for this run only."
        }
        $pinned = $resolved
    }
    if ($pinned -notmatch '^\d+\.\d+\.\d+') {
        throw "Export-OSyncNpm: config key 'pins.npm.verdaccioVersion' is not a x.y.z version: '$pinned'."
    }

    # --- 7. cross-assertion: verdaccio engines vs pinned Node major (fail-fast) ---
    $pinnedNodeMajor = Get-OPinnedNodeMajor -Config $Config
    $nodeCompat = Test-OSyncNpmNodeCompat -VerdaccioVersion $pinned -PinnedNodeMajor $pinnedNodeMajor
    Write-OSyncLog -Category 'npm' -Level Info -Message ("verdaccio@{0} engines.node='{1}'; pinned Node major {2} -> compatible={3} ({4})." -f $pinned, $nodeCompat.EnginesNode, $pinnedNodeMajor, $nodeCompat.Compatible, $nodeCompat.Reason) -Config $Config | Out-Null
    if (-not $nodeCompat.Compatible) {
        throw "Export-OSyncNpm: cross-assertion failed - verdaccio@$pinned requires node '$($nodeCompat.EnginesNode)' which is incompatible with the pinned Node major version $pinnedNodeMajor from '$($Config.paths.runtimeWhitelist)'. $($nodeCompat.Reason)"
    }

    # --- package list (config.paths.* are tool-root-relative INPUT manifests) ---
    $listPath = Resolve-OSyncConfigPath -Config $Config -Path $Config.paths.npmList
    $entries = @(Read-OSyncNpmList -Path $listPath)
    if ($entries.Count -eq 0) {
        throw "Export-OSyncNpm: npm package list '$listPath' is empty - nothing to warm."
    }

    # --- layout ---
    $npmDir = Join-Path $StagingDir 'npm'
    $storageDir = Join-Path $npmDir 'storage'
    $workDir = Join-Path $npmDir 'work'
    foreach ($dir in @($npmDir, $storageDir, $workDir)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    # --- 2. install the one-shot Verdaccio (A has internet) ---
    # Lives under <stagingRoot>\.verdaccio-a - OUTSIDE the per-generation
    # staging dir - so the A-side-only tool and config never ship to B.
    $aToolDir = Join-Path $Config.stagingRoot '.verdaccio-a'
    $npmExe = Get-ONpmExe
    $nodeExe = Get-ONodeExe
    $installOut = @(& $npmExe install --prefix $aToolDir "verdaccio@$pinned" --no-audit --no-fund --loglevel error 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $tail = ((@($installOut) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5) -join '; ')
        throw "Export-OSyncNpm: 'npm install verdaccio@$pinned' failed (exit $LASTEXITCODE): $tail"
    }
    $verdaccioBin = Join-Path $aToolDir 'node_modules\verdaccio\bin\verdaccio'
    if (-not (Test-Path -LiteralPath $verdaccioBin -PathType Leaf)) {
        throw "Export-OSyncNpm: verdaccio entry script not found after install: '$verdaccioBin'."
    }
    Write-OSyncLog -Category 'npm' -Level Info -Message "verdaccio@$pinned installed at '$aToolDir'." -Config $Config | Out-Null

    # --- 3. verdaccio-a.yml ---
    $aYamlPath = Join-Path $aToolDir 'verdaccio-a.yml'
    $aYaml = New-OSyncVerdaccioAYaml -StorageDir $storageDir -Port $aPort -UplinkUrl 'https://registry.npmjs.org'
    [System.IO.File]::WriteAllText($aYamlPath, $aYaml, (New-Object System.Text.UTF8Encoding($false)))

    # Port hygiene: never reuse a running registry (Metis m7); the one-shot
    # instance uses aVerdaccioPort (4874) and never the B port (4873).
    if (Test-OSyncPortListening -Port $aPort) {
        throw "Export-OSyncNpm: port $aPort is already LISTENING - refusing to reuse an existing Verdaccio instance. Stop it or free the port."
    }

    # --- 4. start -> warm -> stop (stop guaranteed via finally) ---
    $server = $null
    $ok = @()
    $failed = @()
    try {
        $server = Start-OVerdaccioProcess -NodeExe $nodeExe -VerdaccioBin $verdaccioBin `
            -ConfigPath $aYamlPath `
            -StdoutLog (Join-Path $workDir 'verdaccio-a.out.log') `
            -StderrLog (Join-Path $workDir 'verdaccio-a.err.log')
        Write-OSyncLog -Category 'npm' -Level Info -Message "one-shot Verdaccio started (pid $($server.Id)) on 127.0.0.1:$aPort." -Config $Config | Out-Null

        if (-not (Wait-OSyncPortListening -Port $aPort -TimeoutSeconds 30)) {
            $tail = Get-OFileTail -Path (Join-Path $workDir 'verdaccio-a.err.log') -Count 10
            $detail = if ($tail.Count -gt 0) { ($tail -join '; ') } else { 'no output captured' }
            throw "Export-OSyncNpm: one-shot Verdaccio did not open port $aPort within 30 s. Diagnostics: $detail"
        }

        $cacheDir = Join-Path $workDir 'npm-cache'
        $registryUrl = "http://127.0.0.1:$aPort"
        $i = 0
        foreach ($entry in $entries) {
            $i++
            $spec = if ($null -ne $entry.Version -and $entry.Version.Length -gt 0) {
                "$($entry.Name)@$($entry.Version)"
            }
            else {
                $entry.Name
            }
            $installDir = Join-Path $workDir ("install-{0}" -f $i)
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null

            Write-OSyncLog -Category 'npm' -Level Info -Message "warming $spec through 127.0.0.1:$aPort ..." -Config $Config | Out-Null
            $result = Invoke-ONpmInstall -NpmExe $npmExe -Spec $spec -Registry $registryUrl `
                -Prefix $installDir -CacheDir $cacheDir
            if ($result.ExitCode -eq 0) {
                $ok += [pscustomobject]@{ Name = $entry.Name; Version = $entry.Version; Spec = $spec }
                Write-OSyncLog -Category 'npm' -Level Info -Message "warmed $spec." -Config $Config | Out-Null
            }
            else {
                $tail = ((@($result.Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5) -join '; ')
                $failed += [pscustomobject]@{ Name = $entry.Name; Version = $entry.Version; Spec = $spec; Error = $tail }
                Write-OSyncLog -Category 'npm' -Level Error -Message "failed to warm $spec (exit $($result.ExitCode)): $tail" -Config $Config | Out-Null
            }
        }

        # Give verdaccio a moment to flush any async storage writes before
        # the stop - the snapshot must be still.
        Start-Sleep -Seconds 2
    }
    finally {
        Stop-OVerdaccioProcess -Process $server -Port $aPort
        Write-OSyncLog -Category 'npm' -Level Info -Message "one-shot Verdaccio stopped (snapshot still)." -Config $Config | Out-Null
    }

    # --- 5. verdaccio-b.yml + packages.txt (delivery contract) ---
    $bYamlPath = Join-Path $npmDir 'verdaccio-b.yml'
    $bYaml = New-OSyncVerdaccioBYaml -Port $bPort
    [System.IO.File]::WriteAllText($bYamlPath, $bYaml, (New-Object System.Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $listPath -Destination (Join-Path $npmDir 'packages.txt') -Force

    # --- 6. export-time leak assertion (Oracle M5) ---
    if (-not (Test-OSyncVerdaccioBYaml -Content $bYaml)) {
        throw "Export-OSyncNpm: verdaccio-b.yml failed the leak assertion - it must not contain uplinks/proxy keys and storage must be the relative path './storage'."
    }

    # --- cleanup of the temp work dir (install scratch + logs) ---
    # The npm cache uses content-addressed files whose paths exceed MAX_PATH
    # (260 chars); Remove-Item -Recurse fails on them under PS 5.1. Delete via
    # the \\?\ long-path prefix instead (verified on this machine).
    if (Test-Path -LiteralPath $workDir -PathType Container) {
        try {
            $longPath = '\\?\' + (Resolve-Path -LiteralPath $workDir).Path
            [System.IO.Directory]::Delete($longPath, $true)
        }
        catch {
            Write-Warning "Export-OSyncNpm: could not remove work dir '$workDir': $($_.Exception.Message)"
        }
    }

    $tarballCount = @(Get-ChildItem -LiteralPath $storageDir -Recurse -Filter '*.tgz' -File -ErrorAction SilentlyContinue).Count
    $summary = "npm export done: $($ok.Count) warmed, $($failed.Count) failed, $tarballCount tarball(s) in storage."
    Write-OSyncLog -Category 'npm' -Level $(if ($failed.Count -gt 0) { 'Warning' } else { 'Info' }) -Message $summary -Config $Config | Out-Null

    return [pscustomobject]@{
        category          = 'npm'
        verdaccioVersion  = $pinned
        nodeEngines       = $nodeCompat.EnginesNode
        nodeCompat        = $nodeCompat.Compatible
        aPort             = $aPort
        storageDir        = $storageDir
        bConfig           = $bYamlPath
        packagesTxt       = (Join-Path $npmDir 'packages.txt')
        warmed            = @($ok)
        failed            = @($failed)
        tarballCount      = $tarballCount
    }
}
