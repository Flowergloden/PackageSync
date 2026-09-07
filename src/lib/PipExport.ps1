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
    4. Post-export assertion: <staging>\pip must contain NO *.tar.gz sdist
       unless config.pip.allowSdist is true (default false - an sdist fails
       the export and the error names the offending file).
    5. Records pip failures into <staging>\pip\export-report.json and logs
       via Write-OSyncLog; a pip failure rethrows (non-zero exit).

  Returns the export report as a PSCustomObject.

  Helpers (all auto-exported by the OfflineSync module's *-OSync* rule):
    Resolve-OSyncPython, Test-OSyncPythonInterpreter, Get-OSyncPipDownloadArgs,
    Invoke-OSyncPipDownload, Get-OSyncPipFailures, Assert-OSyncNoSdist,
    Write-OSyncPipReport
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
        [string[]]$DownloadArgs = @()
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
        $output = & $PythonPath @pipArgs 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
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

    # --- 2. requirements file (config.paths.* are repo-root-relative) ---
    $requirementsPath = Join-Path $Config.repoRoot $Config.paths.requirements
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
    $result = Invoke-OSyncPipDownload -PythonPath $pythonPath -Requirements $requirementsPath -Destination $pipDir -DownloadArgs $downloadArgs

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
        }
        Write-OSyncPipReport -Report $report -ReportPath $reportPath
        Write-OSyncLog -Category 'pip' -Level Error -Message "pip download failed (exit $($result.ExitCode)); report written to '$reportPath'." -Data $failures -Config $Config | Out-Null

        $failedNames = @($failures | ForEach-Object { $_.requirement }) -join ', '
        throw "Export-OSyncPip: pip download failed with exit code $($result.ExitCode) (failing requirement(s): $failedNames). Report written to '$reportPath'."
    }

    # --- 5. copy the requirements file into the wheel repo ---
    Copy-Item -LiteralPath $requirementsPath -Destination (Join-Path $pipDir 'requirements.txt') -Force
    Write-OSyncLog -Category 'pip' -Level Info -Message "Copied requirements file to '$($pipDir)\requirements.txt'" -Config $Config | Out-Null

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
    }
    Write-OSyncPipReport -Report $report -ReportPath $reportPath
    Write-OSyncLog -Category 'pip' -Level Info -Message "pip export complete: $($wheels.Count) wheel(s) in '$pipDir'." -Data @{ wheelCount = $wheels.Count } -Config $Config | Out-Null

    return [pscustomobject]$report
}
