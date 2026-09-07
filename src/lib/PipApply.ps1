#Requires -Version 5.1
<#
  PipApply.ps1 - B-side pip offline apply (--no-index wheel-repo install).
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncPipApply -WorkDir -Config [-PythonPath]

    1. Resolves the python interpreter EVERY RUN from the HKLM machine PATH
       (Oracle r3-B1: never trust state records - pythonExePath in state is
       record/diagnostic only, see State.ps1 header). The machine PATH is read
       fresh from the registry so a long-running process with a stale PATH
       cannot pick a wrong interpreter. Fallback: the pinned machine-wide
       Python 3.12 install (C:\Program Files\Python312\python.exe - the
       B-side target, PackageSync.md). Unresolvable -> explicit error telling
       the operator the bootstrap (Install-OfflineBootstrap) is incomplete.
    2. Runs:
         python -m pip install --no-index --find-links=<WorkDir>\pip
             -r <WorkDir>\pip\requirements.txt [--upgrade]
       --upgrade is appended when config.pip.upgradeOnApply = true. NO
       --index-url / --extra-index-url / any other network source parameter
       is ever added - --no-index strictly (PackageSync.md:51).
    3. On success: `python -m pip list --format=json` snapshot is written to
       state.pip via Add-OSyncStateRecord (name -> {version, sha256:''}).
       lastApplied is deliberately NOT touched - the orchestrator (todo 17)
       stamps it from the repository index.json exportedAtUtc.
    4. On failure: the pip error is captured and logged, state is NOT
       updated, and the function throws (non-zero exit propagates to the
       orchestrator; a failed category keeps its lastApplied so the next
       cycle retries).

  QA seam - interpreter selection: -PythonPath overrides the resolution.
  QA points it at a sandbox venv python (python -m venv) so the apply never
  touches the machine-wide interpreter; production (todo 17) never passes it
  and gets the HKLM machine PATH re-derivation. The override is verified with
  Test-OSyncPythonInterpreter (reused from PipExport.ps1) before use and is
  NOT silently ignored.

  Native-call pattern: `& $pythonPath @args 2>&1` with $ErrorActionPreference
  scoped to Continue around the call (PS 5.1 turns native stderr into a
  terminating NativeCommandError under EAP=Stop) and $LASTEXITCODE as the
  deciding signal - the same pattern as Invoke-OSyncPipDownload (todo 7).
  Start-Process -PassThru is NOT used: its ExitCode is always $null under
  powershell.exe 5.1 (PowerShell issue #3028, see learnings.md).

  Helpers (all auto-exported by the OfflineSync module's *-OSync* rule):
    Get-OSyncMachinePath, Resolve-OSyncApplyPython, Get-OSyncPipApplyArgs,
    Invoke-OSyncPipInstall, Invoke-OSyncPipList, ConvertFrom-OSyncPipListOutput
#>

function Get-OSyncMachinePath {
    <#
      Reads the CURRENT machine PATH from the HKLM environment (registry
      REG_EXPAND_SZ, expanded). [Environment]::GetEnvironmentVariable with
      the Machine target is the canonical reader: it expands %VAR% entries
      and is not affected by the 32/64-bit registry view redirection that
      Get-ItemProperty on HKLM:\SOFTWARE would be. Returns $null when the
      machine PATH is absent or empty.
    #>
    [CmdletBinding()]
    param()

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ([string]::IsNullOrWhiteSpace($machinePath)) { return $null }
    return ([string]$machinePath)
}

function Resolve-OSyncApplyPython {
    <#
      Resolves the python interpreter for the B-side pip apply, re-derived
      EVERY RUN (Oracle r3-B1: never trust state records):
        1. HKLM machine PATH (read fresh from the registry) - first directory
           whose python.exe passes the Test-OSyncPythonInterpreter probe
           (reused from PipExport.ps1; the probe rejects the WindowsApps
           store stub and any broken shim).
        2. Fallback: the pinned machine-wide Python 3.12 install
           (C:\Program Files\Python312\python.exe - the B-side target).
      Throws an explicit error mentioning the bootstrap when neither yields a
      working interpreter.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$FallbackPath = 'C:\Program Files\Python312\python.exe'
    )

    $machinePath = Get-OSyncMachinePath
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        foreach ($dir in ($machinePath -split ';')) {
            if ([string]::IsNullOrWhiteSpace($dir)) { continue }
            $candidate = Join-Path $dir.Trim() 'python.exe'
            if (Test-OSyncPythonInterpreter -PythonPath $candidate) {
                return $candidate
            }
        }
    }

    if (Test-OSyncPythonInterpreter -PythonPath $FallbackPath) {
        return $FallbackPath
    }

    throw "Resolve-OSyncApplyPython: no usable python interpreter found on the HKLM machine PATH (or the pinned fallback '$FallbackPath'). The B-side bootstrap (Install-OfflineBootstrap) may be incomplete - it registers Python on the machine PATH."
}

function Get-OSyncPipApplyArgs {
    <#
      Assembles the pip install arguments for the offline apply:
        -m pip install --no-index --find-links=<WorkDir>\pip
            -r <WorkDir>\pip\requirements.txt [--upgrade]
      --no-index is ALWAYS present and no --index-url / --extra-index-url /
      network source parameter is ever added (PackageSync.md:51 - the
      official offline mode). --upgrade is appended only when
      -UpgradeOnApply is true (config.pip.upgradeOnApply).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,

        [Parameter(Mandatory = $true)]
        [bool]$UpgradeOnApply
    )

    $pipDir = Join-Path $WorkDir 'pip'
    $args = @(
        '-m', 'pip', 'install',
        '--no-index',
        '--find-links', $pipDir,
        '-r', (Join-Path $pipDir 'requirements.txt')
    )
    if ($UpgradeOnApply) {
        $args += '--upgrade'
    }
    return $args
}

function Invoke-OSyncPipInstall {
    <#
      Runs `python -m pip install ...` with the given arguments. Returns
      [pscustomobject]@{ ExitCode; Output } - the merged stdout/stderr text
      is kept for logging. EAP is scoped to Continue around the native call
      (PS 5.1: native stderr under EAP=Stop becomes a terminating
      NativeCommandError) and restored in finally; $LASTEXITCODE is the
      deciding signal.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PythonPath @Arguments 2>&1 | Out-String
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

function Invoke-OSyncPipList {
    <#
      Runs `python -m pip list --format=json` - the post-install snapshot
      source. Same EAP-Continue native-call pattern as
      Invoke-OSyncPipInstall.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonPath
    )

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $PythonPath -m pip list --format=json 2>&1 | Out-String
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

function ConvertFrom-OSyncPipListOutput {
    <#
      Parses the `pip list --format=json` output into an array of
      {name, version} objects. pip emits ONE JSON array line on stdout; the
      merged 2>&1 capture may interleave stderr lines, so the JSON array line
      is located defensively before parsing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Output
    )

    $jsonLine = $Output -split "`r?`n" |
        Where-Object { $_.TrimStart().StartsWith('[') } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($jsonLine)) {
        throw "Invoke-OSyncPipApply: could not locate the JSON array in 'pip list --format=json' output."
    }
    try {
        $parsed = $jsonLine | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Invoke-OSyncPipApply: 'pip list --format=json' output is not valid JSON: $($_.Exception.Message)"
    }
    if ($null -eq $parsed) { return @() }
    return @($parsed)
}

function Invoke-OSyncPipApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,

        [Parameter(Mandatory = $true)]
        $Config,

        # QA seam: explicit interpreter override (e.g. a sandbox venv python).
        # Production never passes it - the interpreter is re-derived from the
        # HKLM machine PATH every run (Oracle r3-B1).
        [Parameter(Mandatory = $false)]
        [string]$PythonPath
    )

    # --- 0. work copy contract: the wheel repo + requirements file ---
    $requirementsPath = Join-Path (Join-Path $WorkDir 'pip') 'requirements.txt'
    if (-not (Test-Path -LiteralPath $requirementsPath -PathType Leaf)) {
        throw "Invoke-OSyncPipApply: requirements file not found in the work copy: '$requirementsPath'. The pip category of the work copy is incomplete."
    }

    # --- 1. python interpreter: explicit override (QA) or HKLM machine PATH ---
    if (-not [string]::IsNullOrWhiteSpace($PythonPath)) {
        if (-not (Test-OSyncPythonInterpreter -PythonPath $PythonPath)) {
            throw "Invoke-OSyncPipApply: the -PythonPath override '$PythonPath' is not a usable python interpreter."
        }
        $python = $PythonPath
    }
    else {
        $python = Resolve-OSyncApplyPython
    }
    # Write-OSyncLog RETURNS the JSONL path - pipe to Out-Null so the summary
    # object is the ONLY thing this function emits (same pattern as
    # WingetExport.ps1 / NpmExport.ps1 / PipExport.ps1).
    Write-OSyncLog -Category 'pip' -Level Info -Message "Using python interpreter: $python" -Config $Config | Out-Null

    # --- 2. assemble + run the offline install ---
    $installArgs = Get-OSyncPipApplyArgs -WorkDir $WorkDir -UpgradeOnApply ([bool]$Config.pip.upgradeOnApply)
    Write-OSyncLog -Category 'pip' -Level Info -Message "pip install args: $($installArgs -join ' ')" -Config $Config | Out-Null
    $result = Invoke-OSyncPipInstall -PythonPath $python -Arguments $installArgs

    if ($result.ExitCode -ne 0) {
        Write-OSyncLog -Category 'pip' -Level Error -Message "pip install failed (exit $($result.ExitCode)); state NOT updated." -Data @{ output = [string]$result.Output } -Config $Config | Out-Null
        throw "Invoke-OSyncPipApply: pip install failed with exit code $($result.ExitCode); state NOT updated. Output: $([string]$result.Output)"
    }
    Write-OSyncLog -Category 'pip' -Level Info -Message "pip install succeeded (exit 0)." -Data @{ output = [string]$result.Output } -Config $Config | Out-Null

    # --- 3. post-install snapshot: pip list --format=json -> state.pip ---
    $listResult = Invoke-OSyncPipList -PythonPath $python
    if ($listResult.ExitCode -ne 0) {
        Write-OSyncLog -Category 'pip' -Level Error -Message "pip list snapshot failed (exit $($listResult.ExitCode)); state NOT updated." -Data @{ output = [string]$listResult.Output } -Config $Config | Out-Null
        throw "Invoke-OSyncPipApply: 'pip list --format=json' failed with exit code $($listResult.ExitCode); state NOT updated."
    }

    $snapshot = ConvertFrom-OSyncPipListOutput -Output ([string]$listResult.Output)
    foreach ($pkg in $snapshot) {
        $null = Add-OSyncStateRecord -Category 'pip' -Name $pkg.name -Version $pkg.version -Sha256 '' -Config $Config
    }

    Write-OSyncLog -Category 'pip' -Level Info -Message "pip apply complete: $($snapshot.Count) package(s) recorded in state.pip." -Data @{ packageCount = $snapshot.Count } -Config $Config | Out-Null

    return [pscustomobject]@{
        status     = 'ok'
        pythonPath = $python
        packages   = $snapshot.Count
        workDir    = $WorkDir
    }
}