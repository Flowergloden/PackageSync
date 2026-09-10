#Requires -Version 5.1
<#
  PipExport.ps1 - A-side pip wheel-repo export for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Export-OSyncPip -Config -StagingDir

    1. Resolves the python interpreter: `python` from PATH first, falling back
       to the pinned machine-wide install C:\Program Files\Python312\python.exe
       (the B-side target is Python 3.12 - PackageSync.md pins it).
    2. Runs:
         python -m pip download -r <config.paths.requirements> -d <staging>\pip
       plus config.pip.downloadArgs. The platform args are NEVER omitted:
       A/B platform divergence requires explicit pinning to the B-side
       interpreter (PackageSync.md:46-48). Default pin:
         --only-binary=:all: --platform win_amd64 --python-version 3.12
         --implementation cp --abi cp312
3. Copies the requirements file to <staging>\pip\requirements.txt.
     4. Local wheel dirs (optional, presence-gated on config.paths.pipLocalDirs):
        operator-staged *.whl files are copied TOP-LEVEL-only into
        <staging>\pip and their pins appended (with a `# local: <file>`
        marker) to the STAGING requirements.txt copy - NEVER to the original
        manifest. Local *.tar.gz sdists are NEVER copied (the local-dir flow
        is wheels-only, regardless of pip.allowSdist) and are reported as
        skipped-sdist with a Warning; unparseable wheel names are skipped with
        a Warning; missing dirs are skipped with a Warning. An absent or empty
        paths.pipLocalDirs keeps the delivery byte-identical to the source
        manifest. The A-side `pip download -r` (step 2) always runs against
        the ORIGINAL manifest only - private packages never hit PyPI.
     5. Post-export assertion: <staging>\pip must contain NO *.tar.gz sdist
        unless config.pip.allowSdist is true (default false - an sdist fails
        the export and the error names the offending file).
     6. Records pip failures into <staging>\pip\export-report.json and logs
        via Write-OSyncLog; a pip failure rethrows (non-zero exit).

  Returns the export report as a PSCustomObject.

  Helpers (all auto-exported by the OfflineSync module's *-OSync* rule):
    Resolve-OSyncPython, Test-OSyncPythonInterpreter, Get-OSyncPipDownloadArgs,
    Invoke-OSyncPipDownload, Get-OSyncPipFailures, Assert-OSyncNoSdist,
    ConvertFrom-OSyncWheelFileName, Get-OSyncPipLocalWheelPlan,
    Add-OSyncRequirementsPins, Write-OSyncPipReport
#>

function Test-OSyncPythonInterpreter {
    <#
      Probes whether <PythonPath> is a usable python interpreter by running
      `--version` and requiring exit code 0 AND "Python x.y" output. The
      WindowsApps `python.exe` store stub either exits 9009 or prints nothing
      - both must be rejected so the resolver moves on to the real fallback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonPath
    )

    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }
    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) { return $false }

    try {
        $versionOutput = (& $PythonPath --version 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { return $false }
        return ($versionOutput -match 'Python \d')
    }
    catch {
        # A broken shim or unstartable stub: not a usable interpreter.
        return $false
    }
}

function Resolve-OSyncPython {
    <#
      Resolves the python interpreter for the pip export:
        1. `python` resolved from PATH (Application type only - no aliases),
           verified to actually run.
        2. Fallback to the pinned machine-wide Python 3.12 install
           (C:\Program Files\Python312\python.exe - the B-side target).
      Throws when neither yields a working interpreter.

      Get-Command can return MULTIPLE Application candidates - the real
      Python 3.12 install AND the WindowsApps store stub are both on PATH in
      the elevated production context. Force an array and probe each one in
      order; passing the array straight to the [string] -PythonPath parameter
      would throw a ParameterBindingException (todo-11 QA hit this).
    #>
    [CmdletBinding()]
    param(
        # Optional override for tests; defaults to the pinned B-side Python
        # 3.12 machine-wide install (plan todo 7 / PackageSync.md).
        [Parameter(Mandatory = $false)]
        [string]$FallbackPath = 'C:\Program Files\Python312\python.exe'
    )

    # @(...) forces an array even for a single/null result; a $null element
    # (PS 5.1: @($null).Count is 1) is skipped by the guard below.
    $candidates = @(Get-Command python -CommandType Application -ErrorAction SilentlyContinue)
    foreach ($cmd in $candidates) {
        if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
            if (Test-OSyncPythonInterpreter -PythonPath $cmd.Source) {
                return $cmd.Source
            }
        }
    }

    if (Test-OSyncPythonInterpreter -PythonPath $FallbackPath) {
        return $FallbackPath
    }

    throw "Resolve-OSyncPython: no usable python interpreter found (tried 'python' on PATH and fallback '$FallbackPath')."
}

function Get-OSyncPipDownloadArgs {
    <#
      Assembles the pip download arguments. Platform pinning is MANDATORY:
      A and B may diverge on Python version/architecture, so pip must always
      be told the exact B-side target (PackageSync.md:46-48). When the caller
      supplies no args, the pinned default below is used - the pin is never
      silently dropped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$DownloadArgs = @()
    )

    if ($null -eq $DownloadArgs -or $DownloadArgs.Count -eq 0) {
        return @(
            '--only-binary=:all:',
            '--platform', 'win_amd64',
            '--python-version', '3.12',
            '--implementation', 'cp',
            '--abi', 'cp312'
        )
    }
    return $DownloadArgs
}

function Invoke-OSyncPipDownload {
    <#
      Runs `python -m pip download -r <Requirements> -d <Destination>` with
      the given extra args. Returns [pscustomobject]@{ ExitCode; Output } -
      the merged stdout/stderr text is kept for the export report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonPath,

        [Parameter(Mandatory = $true)]
        [string]$Requirements,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [string[]]$DownloadArgs = @(),

        # Forward each output line to the console live (Write-Host only -
        # the pipeline still carries the captured objects untouched, so the
        # returned Output keeps its exact pre-echo shape). pip prints plain
        # progress lines when stdout is redirected (non-tty), so no
        # throttling is needed unlike winget's CR-redrawn progress bars.
        [Parameter(Mandatory = $false)]
        [bool]$Echo = $false
    )

    $pipArgs = @('-m', 'pip', 'download', '-r', $Requirements, '-d', $Destination) + @($DownloadArgs)

    # pip writes progress/warnings to STDERR; under $ErrorActionPreference =
    # 'Stop' (PS 5.1) a native stderr line becomes a TERMINATING
    # NativeCommandError with an empty message - the exit code must be the
    # deciding signal here, so scope the preference to Continue for the
    # invocation and restore it afterwards (Oracle m7-style guard).
    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = @(& $PythonPath @pipArgs 2>&1 | ForEach-Object {
            if ($Echo) {
                # PS 5.1 wraps native stderr lines in ErrorRecords; render the
                # exception message - "$_" on such a record can collapse to
                # the type name 'System.Management.Automation.RemoteException'.
                $line = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
                Write-Host ('  pip: ' + $line) -ForegroundColor DarkGray
            }
            $_
        })
        $exitCode = $LASTEXITCODE
        $output = ($raw | Out-String)
    }
    finally {
        $ErrorActionPreference = $savedEap
    }
    if ($null -eq $exitCode) { $exitCode = -1 }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

function Get-OSyncPipFailures {
    <#
      Best-effort extraction of failing requirement names from pip output.
      Shapes covered:
        ERROR: Could not find a version that satisfies the requirement X (from versions: ...)
        ERROR: The user requested X; ...
      Falls back to the raw ERROR lines when nothing parseable is found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PipOutput
    )

    $failures = @()

    $rx = [regex]"Could not find a version that satisfies the requirement (.+?) \(from versions"
    foreach ($m in $rx.Matches($PipOutput)) {
        $failures += [pscustomobject]@{
            requirement = $m.Groups[1].Value.Trim()
            error       = 'no matching version found (binary-only platform pin active)'
        }
    }

    if ($failures.Count -eq 0) {
        $rx2 = [regex]"The user requested (.+?);"
        foreach ($m in $rx2.Matches($PipOutput)) {
            $failures += [pscustomobject]@{
                requirement = $m.Groups[1].Value.Trim()
                error       = 'package is not available as a binary wheel for the pinned platform'
            }
        }
    }

    if ($failures.Count -eq 0) {
        $errorLines = @($PipOutput -split "`r?`n" | Where-Object { $_ -match '^\s*ERROR:' })
        if ($errorLines.Count -eq 0) { $errorLines = @('pip exited non-zero; no ERROR lines captured') }
        $failures += [pscustomobject]@{
            requirement = '<unknown>'
            error       = ($errorLines -join ' | ')
        }
    }

    # The comma operator keeps the collection a collection: PowerShell would
    # otherwise UNROLL a single-element array into the bare object, and
    # callers would lose .Count / array indexing (PS 5.1 gotcha).
    return ,$failures
}

function Write-OSyncPipReport {
    <#
      Writes the pip export report as UTF-8 WITH BOM JSON (PS 5.1 misreads
      BOM-less non-ASCII as ANSI - same convention as every other JSON
      artifact this tool writes).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Report,

        [Parameter(Mandatory = $true)]
        [string]$ReportPath
    )

    $json = ConvertTo-OSyncJson -InputObject $Report
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($ReportPath, $json, $utf8Bom)
}

function Assert-OSyncNoSdist {
    <#
      Post-export assertion: the wheel repo must contain no *.tar.gz source
      distributions. With --only-binary=:all: pip already excludes sdists;
      this is defense in depth - a stray sdist fails the export and the error
      names the offending file(s). Skipped entirely when -AllowSdist is true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PipDir,

        [Parameter(Mandatory = $false)]
        [bool]$AllowSdist = $false
    )

    if ($AllowSdist) { return $true }

    $sdists = @(Get-ChildItem -LiteralPath $PipDir -File -Filter '*.tar.gz' -ErrorAction SilentlyContinue)
    if ($sdists.Count -gt 0) {
        $names = ($sdists | ForEach-Object { $_.Name }) -join ', '
        throw "Assert-OSyncNoSdist: source distribution(s) found in '$PipDir': $names. sdists are forbidden for the B-side wheel repo (config.pip.allowSdist = false)."
    }
    return $true
}

function ConvertFrom-OSyncWheelFileName {
    <#
      PEP 427 wheel filename parse: {distribution}-{version}(-{build})?-
      {python tag}-{abi tag}-{platform tag}.whl. A naive split on '-' is safe
      because PEP 427 escapes any '-' inside the distribution/version to '_'
      (underscore names are kept verbatim - pip normalizes per PEP 503).
      Valid shapes:
        - exactly 5 parts (no build tag), or
        - exactly 6 parts where part[2] (the build tag) starts with a digit.
      No empty parts allowed. Returns
      [pscustomobject]@{ Name; Version; Pin = "Name==Version" } or $null when
      the name is not parseable (the caller buckets it as skipped-unparseable).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$FileName
    )

    if ([string]::IsNullOrWhiteSpace($FileName)) { return $null }
    # Basename only: callers may hand a full path; PEP 427 applies to the name.
    $leaf = Split-Path -Leaf $FileName
    if ($leaf -notmatch '(?i)\.whl$') { return $null }
    $stem = $leaf.Substring(0, $leaf.Length - 4)
    $parts = @($stem -split '-')
    if ($parts.Count -ne 5 -and $parts.Count -ne 6) { return $null }
    foreach ($part in $parts) {
        if ([string]::IsNullOrEmpty($part)) { return $null }
    }
    if ($parts.Count -eq 6 -and $parts[2] -notmatch '^\d') { return $null }

    return [pscustomobject]@{
        Name    = $parts[0]
        Version = $parts[1]
        Pin     = ('{0}=={1}' -f $parts[0], $parts[1])
    }
}

function Get-OSyncPipLocalWheelPlan {
    <#
      Scans the operator-staged local wheel dirs (config.paths.pipLocalDirs)
      and buckets what it finds. TOP-LEVEL only - a wheel in a subdirectory is
      NOT part of the delivery (the local dir is a staging area, not a tree).
      Per dir:
        - missing (not a container) -> MissingDirs entry,
        - *.whl files -> Wheels entries @{ Path; File; Name; Version; Pin }
          (a name ConvertFrom-OSyncWheelFileName rejects goes to the
          Unparseable bucket instead),
        - *.tar.gz files -> Sdists bucket @{ Dir; File } (never copied).
      Returns [pscustomobject]@{ Wheels=@(); Sdists=@(); Unparseable=@();
      MissingDirs=@() } - every bucket is an array even when empty.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$Dirs = @()
    )

    $wheels = @()
    $sdists = @()
    $unparseable = @()
    $missingDirs = @()

    foreach ($dir in @($Dirs)) {
        if ([string]::IsNullOrWhiteSpace([string]$dir)) { continue }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            $missingDirs += [pscustomobject]@{ Dir = [string]$dir }
            continue
        }

        # Top-level only: no -Recurse. Get-ChildItem -File -Filter '*.whl'
        # matches case-insensitively on Windows.
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.whl' -ErrorAction SilentlyContinue)) {
            $parsed = ConvertFrom-OSyncWheelFileName -FileName $file.Name
            if ($null -eq $parsed) {
                $unparseable += [pscustomobject]@{
                    Dir  = [string]$dir
                    Path = $file.FullName
                    File = $file.Name
                }
            }
            else {
                $wheels += [pscustomobject]@{
                    Path    = $file.FullName
                    File    = $file.Name
                    Name    = $parsed.Name
                    Version = $parsed.Version
                    Pin     = $parsed.Pin
                }
            }
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.tar.gz' -ErrorAction SilentlyContinue)) {
            $sdists += [pscustomobject]@{ Dir = [string]$dir; File = $file.Name }
        }
    }

    return [pscustomobject]@{
        Wheels      = $wheels
        Sdists      = $sdists
        Unparseable = $unparseable
        MissingDirs = $missingDirs
    }
}

function Get-OPep503Name {
    <#
      PEP 503 name normalization: lowercase, every run of '-', '_' or '.'
      collapses to a single '-'. pip treats 'my-pkg', 'my_pkg' and 'my.pkg'
      as the SAME distribution, so the local-pin dedup MUST compare normalized
      names - otherwise a distribution pinned in the manifest AND delivered as
      a local wheel would produce "Double requirement given" on the B side.
      Private helper (no *-OSync* suffix): only used inside this file.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return ([regex]::Replace($Name.Trim().ToLowerInvariant(), '[-_.]+', '-'))
}

function Add-OSyncRequirementsPins {
    <#
      Appends local-wheel pin lines (e.g. 'name==version  # local: file.whl')
      to the STAGING requirements.txt copy ONLY - the original manifest is
      never touched. Dedup: a pin whose distribution name (PEP 503 normalized)
      is already pinned in the file is skipped, and within one call the first
      occurrence of a name wins (both prevent "Double requirement given" on B).
      Byte-level fidelity (the delivery contract must stay exact):
        - UTF-8 BOM state preserved (read/write via [System.IO.File] bytes),
        - dominant EOL (CRLF vs LF) preserved; a file without a trailing
          newline gets the EOL separator inserted before the first appended
          line; a file with no newline at all defaults to CRLF,
        - when nothing is appended the file is NOT rewritten at all (stays
          byte-identical).
      Returns the actually-appended lines as an array (the comma operator
      keeps a single-element/empty result an array - PS 5.1 unrolls otherwise).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequirementsPath,

        [Parameter(Mandatory = $false)]
        [string[]]$PinLines = @()
    )

    if (-not (Test-Path -LiteralPath $RequirementsPath -PathType Leaf)) {
        throw "Add-OSyncRequirementsPins: requirements file not found: '$RequirementsPath'."
    }

    # --- read bytes; BOM is controlled by us, never by an encoding default ---
    $bytes = [System.IO.File]::ReadAllBytes($RequirementsPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if ($hasBom) {
        $content = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    else {
        $content = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    # --- dominant EOL (CRLF vs LF); single-line/no-newline files default CRLF ---
    $crlfCount = ([regex]::Matches($content, "`r`n")).Count
    $lfCount = ([regex]::Matches($content, "(?<!`r)`n")).Count
    if ($crlfCount -gt 0 -and $crlfCount -ge $lfCount) { $eol = "`r`n" }
    elseif ($lfCount -gt 0) { $eol = "`n" }
    else { $eol = "`r`n" }

    # --- existing pins: normalized names already pinned in the file ---
    $existing = @{}
    foreach ($line in ($content -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#')) { continue }
        $m = [regex]::Match($trimmed, '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*==')
        if ($m.Success) {
            $existing[(Get-OPep503Name -Name $m.Groups[1].Value)] = $true
        }
    }

    # --- select the lines that are actually new (file pins + intra-call dedup) ---
    $appended = @()
    foreach ($line in @($PinLines)) {
        if ($null -eq $line) { continue }
        $lineText = ([string]$line).Trim()
        if ($lineText.Length -eq 0) { continue }
        $namePart = ($lineText -split '==', 2)[0]
        $key = Get-OPep503Name -Name $namePart
        if ($key.Length -eq 0) { continue }
        if ($existing.ContainsKey($key)) { continue }
        $existing[$key] = $true
        $appended += $lineText
    }

    if ($appended.Count -eq 0) {
        # Nothing new: leave the file byte-identical (not even rewritten).
        return ,$appended
    }

    # --- append (EOL separator first when the file lacks a trailing newline) ---
    $newContent = $content
    if ($newContent.Length -gt 0 -and -not $newContent.EndsWith("`n")) {
        $newContent += $eol
    }
    foreach ($line in $appended) {
        $newContent += $line + $eol
    }

    $outBytes = [System.Text.Encoding]::UTF8.GetBytes($newContent)
    if ($hasBom) {
        $withBom = New-Object byte[] ($outBytes.Length + 3)
        [Array]::Copy($outBytes, 0, $withBom, 3, $outBytes.Length)
        $withBom[0] = 0xEF; $withBom[1] = 0xBB; $withBom[2] = 0xBF
        $outBytes = $withBom
    }
    [System.IO.File]::WriteAllBytes($RequirementsPath, $outBytes)

    return ,$appended
}

function Export-OSyncPip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$StagingDir
    )

    # --- 1. python interpreter (PATH -> pinned 3.12 fallback) ---
    $pythonPath = Resolve-OSyncPython
    # Write-OSyncLog RETURNS the JSONL path - pipe to Out-Null so the export
    # report object is the ONLY thing this function emits (same pattern as
    # WingetExport.ps1 / NpmExport.ps1).
    Write-OSyncLog -Category 'pip' -Level Info -Message "Using python interpreter: $pythonPath" -Config $Config | Out-Null

    # --- 2. requirements file (config.paths.* are tool-root-relative INPUT
    # manifests - never config.repoRoot, the output landing dir) ---
    $requirementsPath = Resolve-OSyncConfigPath -Config $Config -Path $Config.paths.requirements
    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        throw "Export-OSyncPip: requirements file not found: '$requirementsPath'."
    }

    # --- 3. staging target <staging>\pip ---
    $pipDir = Join-Path $StagingDir 'pip'
    if (-not (Test-Path -LiteralPath $pipDir -PathType Container)) {
        New-Item -ItemType Directory -Path $pipDir -Force | Out-Null
    }

    # --- 4. pip download (platform pin mandatory) ---
    $downloadArgs = Get-OSyncPipDownloadArgs -DownloadArgs $Config.pip.downloadArgs
    Write-OSyncLog -Category 'pip' -Level Info -Message "pip download -r '$requirementsPath' -> '$pipDir' args: $($downloadArgs -join ' ')" -Config $Config | Out-Null
    # consoleEcho is an in-memory-only flag pinned by the export orchestrator
    # (absent/false on B-side configs -> silent, same as WingetExport.ps1).
    $echoOn = ($null -ne $Config -and $Config.PSObject.Properties['consoleEcho'] -and [bool]$Config.consoleEcho)
    $result = Invoke-OSyncPipDownload -PythonPath $pythonPath -Requirements $requirementsPath -Destination $pipDir -DownloadArgs $downloadArgs -Echo $echoOn

    # Wheels that did make it before a failure (pip usually fails fast, but a
    # mid-download failure can leave partial artifacts) - reported truthfully.
    $wheels = @(Get-ChildItem -LiteralPath $pipDir -File -Filter '*.whl' -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.Name })
    $reportPath = Join-Path $pipDir 'export-report.json'

    if ($result.ExitCode -ne 0) {
        $failures = Get-OSyncPipFailures -PipOutput ([string]$result.Output)
        $report = [ordered]@{
            category     = 'pip'
            status       = 'failed'
            requirements = $Config.paths.requirements
            target       = $pipDir
            downloadArgs = $downloadArgs
            ok           = $wheels
            failed       = $failures
            wheelCount   = $wheels.Count
            pipExitCode  = $result.ExitCode
            local        = @()
        }
        Write-OSyncPipReport -Report $report -ReportPath $reportPath
        Write-OSyncLog -Category 'pip' -Level Error -Message "pip download failed (exit $($result.ExitCode)); report written to '$reportPath'." -Data $failures -Config $Config | Out-Null

        $failedNames = @($failures | ForEach-Object { $_.requirement }) -join ', '
        throw "Export-OSyncPip: pip download failed with exit code $($result.ExitCode) (failing requirement(s): $failedNames). Report written to '$reportPath'."
    }

    # --- 5. copy the requirements file into the wheel repo ---
    Copy-Item -LiteralPath $requirementsPath -Destination (Join-Path $pipDir 'requirements.txt') -Force
    Write-OSyncLog -Category 'pip' -Level Info -Message "Copied requirements file to '$($pipDir)\requirements.txt'" -Config $Config | Out-Null

    # --- 5b. local wheel dirs (optional, presence-gated) ---
    # config.paths.pipLocalDirs is NEVER required: an absent key OR an empty
    # array both mean OFF and the delivery stays byte-identical (the verbatim
    # copy above is the contract). Operator-staged local wheels are PRIVATE
    # packages that must never hit PyPI - the pip download in step 4 ran
    # against the ORIGINAL manifest only, and this flow only ever touches the
    # STAGING requirements copy.
    $localEntries = @()
    $localDirsRaw = Get-ONestedValue -Object $Config -Path 'paths.pipLocalDirs'
    if ($null -ne $localDirsRaw -and @($localDirsRaw).Count -gt 0) {
        $resolvedDirs = @()
        foreach ($rawDir in @($localDirsRaw)) {
            $resolved = Resolve-OSyncConfigPath -Config $Config -Path ([string]$rawDir)
            if (-not [string]::IsNullOrWhiteSpace($resolved)) { $resolvedDirs += $resolved }
        }
        $plan = Get-OSyncPipLocalWheelPlan -Dirs $resolvedDirs

        foreach ($m in $plan.MissingDirs) {
            Write-OSyncLog -Category 'pip' -Level Warning -Message "local wheel dir missing: '$($m.Dir)' - skipped (no wheels harvested)." -Config $Config | Out-Null
            $localEntries += [pscustomobject]@{ file = [string]$m.Dir; name = $null; version = $null; pin = $null; action = 'missing-dir' }
        }
        foreach ($s in $plan.Sdists) {
            Write-OSyncLog -Category 'pip' -Level Warning -Message "local sdist found: '$($s.File)' in '$($s.Dir)' - sdists are NEVER copied (the local-dir flow is wheels-only)." -Config $Config | Out-Null
            $localEntries += [pscustomobject]@{ file = $s.File; name = $null; version = $null; pin = $null; action = 'skipped-sdist' }
        }
        foreach ($u in $plan.Unparseable) {
            Write-OSyncLog -Category 'pip' -Level Warning -Message "local wheel name not PEP 427-parseable: '$($u.File)' in '$($u.Dir)' - skipped." -Config $Config | Out-Null
            $localEntries += [pscustomobject]@{ file = $u.File; name = $null; version = $null; pin = $null; action = 'skipped-unparseable' }
        }

        if ($plan.Wheels.Count -gt 0) {
            $pinLines = @()
            foreach ($w in $plan.Wheels) {
                $pinLines += ('{0}  # local: {1}' -f $w.Pin, $w.File)
            }
            $appendedPins = Add-OSyncRequirementsPins -RequirementsPath (Join-Path $pipDir 'requirements.txt') -PinLines $pinLines
            # Exact-line membership: a wheel whose pin was NOT appended (already
            # pinned in the manifest, or a same-name duplicate earlier in the
            # plan) is still copied but reported as copied-pin-exists.
            $appendedSet = @{}
            foreach ($line in $appendedPins) { $appendedSet[[string]$line] = $true }

            foreach ($w in $plan.Wheels) {
                Copy-Item -LiteralPath $w.Path -Destination (Join-Path $pipDir $w.File) -Force
                $pinLine = ('{0}  # local: {1}' -f $w.Pin, $w.File)
                $action = if ($appendedSet.ContainsKey($pinLine)) { 'copied' } else { 'copied-pin-exists' }
                $localEntries += [pscustomobject]@{
                    file = $w.File; name = $w.Name; version = $w.Version; pin = $w.Pin; action = $action
                }
            }
        }
    }

    # --- 6. no-sdist assertion (defense in depth) ---
    $null = Assert-OSyncNoSdist -PipDir $pipDir -AllowSdist ([bool]$Config.pip.allowSdist)

    # --- 7. success report ---
    $report = [ordered]@{
        category     = 'pip'
        status       = 'ok'
        requirements = $Config.paths.requirements
        target       = $pipDir
        downloadArgs = $downloadArgs
        ok           = $wheels
        failed       = @()
        wheelCount   = $wheels.Count
        local        = @($localEntries)
    }
    Write-OSyncPipReport -Report $report -ReportPath $reportPath
    Write-OSyncLog -Category 'pip' -Level Info -Message "pip export complete: $($wheels.Count) wheel(s) in '$pipDir'." -Data @{ wheelCount = $wheels.Count } -Config $Config | Out-Null

    return [pscustomobject]$report
}
