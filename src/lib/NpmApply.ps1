#Requires -Version 5.1
<#
  NpmApply.ps1 - B-side npm apply: offline Verdaccio service + global npmrc.

  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncNpmApply -WorkDir -Config [-VerdaccioTaskName] [-SkipVerdaccioTask] [-VerdaccioEndpoint]

    1.  Assert <WorkDir>\npm\verdaccio-b.yml has NO uplinks/proxy keys and
        storage IS ./storage (reuses Test-OSyncVerdaccioBYaml from NpmExport).
    1.5 Refresh the LOCAL copy <stateDir>\verdaccio from the work copy with
        Invoke-OSyncRobocopy /MIR. STRICT ORDER (Oracle r5 watch-out): stop
        the Verdaccio task -> copy -> start the task. A running service's data
        dir must never be /MIR'd; the service reads ONLY the local copy
        (Momus M3 / Oracle M4).
    2.  Task management: when the scheduled task's State != Running,
        `schtasks /Run` it, then wait for 127.0.0.1:<config.verdaccioPort> to
        LISTEN (30 s timeout -> explicit error naming the port).
    3.  Registry config (Oracle B1): append
        registry=http://127.0.0.1:<config.verdaccioPort>/ to the BUILT-IN
        npmrc <nodeInstallDir>\node_modules\npm\npmrc (backup to .osyncbak
        FIRST; idempotent - never duplicate the line; preserve other lines)
        and set the MACHINE-level env var NPM_CONFIG_REGISTRY as
        belt-and-braces. nodeInstallDir is RE-DERIVED every run from the HKLM
        machine PATH (node.exe location; never from state, Oracle r3-B1).
    4.  Verify: `npm view <first entry of <WorkDir>\npm\packages.txt>
        --registry http://127.0.0.1:<port>` returns a version; a
        guaranteed-nonexistent package name FAILS FAST within 30 s (proves no
        uplink hang, Metis M4); and a NEW PROCESS WITHOUT FLAGS
        `npm config get registry` returns the local registry (flag-carrying
        checks cannot catch config fallback, Oracle B1).
    5.  state.npm = { registryOk: $true, at }.

  QA SEAM (documented): the real scheduled task 'PakageSync-Verdaccio' is
  registered by Install-OfflineBootstrap (plan todo 12) / Register-SyncTasks
  (todo 17) - it does NOT exist yet during todo-15 QA. The task step is
  injectable/overridable:
    -VerdaccioTaskName <name>   point at a differently-named task (QA uses a
                                clearly-named TEMPORARY task and deletes it in
                                the same run).
    -SkipVerdaccioTask          skip task stop/start AND the /MIR refresh
                                entirely (a running service's data dir must
                                never be /MIR'd - the strict order exists for
                                that reason). QA starts a portable Verdaccio
                                manually against the work copy; the apply only
                                waits for the port.
    -VerdaccioEndpoint <url>    full override: skip task management, the /MIR
                                refresh AND the port wait; all verification
                                runs against this already-listening endpoint.
                                The npmrc/env still point at
                                config.verdaccioPort.
  The unit tests mock the task functions (Get-OSyncVerdaccioTaskState /
  Start-OSyncVerdaccioTask / Stop-OSyncVerdaccioTask), the port checks and
  the npm CLI.

  Must NOT: never `npm install --offline` (cache semantics contradict the
  registry design); never write a user-level .npmrc.
#>

function Resolve-OSyncNodeInstallDir {
    <#
      Re-derives the node install dir from the HKLM machine PATH every run
      (Oracle r3-B1: never trust state). Returns the directory containing
      node.exe. -MachinePath is a test seam (defaults to the real machine
      PATH).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$MachinePath
    )

    # Only fall back to the real machine PATH when the caller did NOT pass
    # -MachinePath explicitly (an explicit empty string is a real empty PATH).
    if (-not $PSBoundParameters.ContainsKey('MachinePath')) {
        $MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    }
    if ([string]::IsNullOrWhiteSpace($MachinePath)) {
        throw "Invoke-OSyncNpmApply: the HKLM machine PATH is empty - cannot locate node.exe. Run Install-OfflineBootstrap first."
    }
    foreach ($dir in $MachinePath -split ';') {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $candidate = Join-Path $dir.Trim() 'node.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Split-Path -Parent $candidate)
        }
    }
    throw "Invoke-OSyncNpmApply: node.exe was not found in any HKLM machine PATH directory - run Install-OfflineBootstrap first."
}

function Set-OSyncNpmRegistryConfig {
    <#
      Oracle B1: npm's globalconfig on Windows resolves through the BUILT-IN
      npmrc <nodeInstallDir>\node_modules\npm\npmrc (the prefix=${APPDATA}\npm
      line routes it to the per-user dir; <nodeInstallDir>\etc\npmrc never
      takes effect). Appends registry=http://127.0.0.1:<port>/ to that file:
        - backup to .osyncbak FIRST (only once - the backup preserves the
          ORIGINAL file and is never overwritten),
        - idempotent: never duplicate the line,
        - preserve all other lines (a pre-existing different registry line is
          left untouched; npm's ini semantics make the LAST assignment win,
          so the appended line takes effect).
      Returns $true when the file was modified, $false when the line was
      already present.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NodeInstallDir,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port,

        [Parameter(Mandatory = $true)]
        $Config
    )

    $npmrc = Join-Path $NodeInstallDir 'node_modules\npm\npmrc'
    $registryLine = "registry=http://127.0.0.1:$Port/"
    $exists = Test-Path -LiteralPath $npmrc -PathType Leaf
    $content = if ($exists) { [System.IO.File]::ReadAllText($npmrc) } else { '' }

    # Idempotency: our exact line is already present -> nothing to do.
    $pattern = '(?m)^registry\s*=\s*http://127\.0\.0\.1:' + $Port + '/\s*$'
    if ($content -match $pattern) {
        Write-OSyncLog -Category 'npm' -Level Info -Message "built-in npmrc '$npmrc' already contains 'registry=http://127.0.0.1:$Port/' - no change." -Config $Config | Out-Null
        return $false
    }

    # Backup FIRST (only if not already backed up - preserves the ORIGINAL).
    $bak = $npmrc + '.osyncbak'
    if ($exists -and -not (Test-Path -LiteralPath $bak -PathType Leaf)) {
        Copy-Item -LiteralPath $npmrc -Destination $bak -Force
        Write-OSyncLog -Category 'npm' -Level Info -Message "backed up built-in npmrc to '$bak'." -Config $Config | Out-Null
    }

    # Append, preserving other lines and the trailing-newline state.
    $sep = ''
    if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $sep = "`n" }
    $newContent = $content + $sep + $registryLine + "`n"

    # Preserve the BOM state of the original file (house style).
    $bytes = if ($exists) { [System.IO.File]::ReadAllBytes($npmrc) } else { [byte[]]@() }
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $outBytes = [System.Text.Encoding]::UTF8.GetBytes($newContent)
    if ($hasBom) {
        $withBom = New-Object byte[] ($outBytes.Length + 3)
        [Array]::Copy($outBytes, 0, $withBom, 3, $outBytes.Length)
        $withBom[0] = 0xEF; $withBom[1] = 0xBB; $withBom[2] = 0xBF
        $outBytes = $withBom
    }
    [System.IO.File]::WriteAllBytes($npmrc, $outBytes)

    Write-OSyncLog -Category 'npm' -Level Info -Message "appended 'registry=http://127.0.0.1:$Port/' to built-in npmrc '$npmrc'." -Config $Config | Out-Null
    return $true
}

function Set-OSyncMachineEnvVar {
    <#
      Wrapper around [Environment]::SetEnvironmentVariable(..., 'Machine') so
      unit tests can mock it (a real call needs elevation). Value $null
      REMOVES the variable (QA cleanup).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$Value
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
}

function Get-OSyncVerdaccioTaskState {
    <#
      Returns the State of the scheduled task ('Running'/'Ready'/...) or $null
      when the task does not exist. Wrapper around Get-ScheduledTask so unit
      tests can mock it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return $null }
    return ([string]$task.State)
}

function Start-OSyncVerdaccioTask {
    <#
      `schtasks /Run` wrapper. Throws on a non-zero exit code. PS 5.1: native
      stderr under EAP=Stop becomes a terminating NativeCommandError - scope
      Continue around the native call.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & schtasks.exe /Run /TN $TaskName 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    if ($code -ne 0) {
        throw "Invoke-OSyncNpmApply: 'schtasks /Run /TN $TaskName' failed with exit code $code."
    }
}

function Stop-OSyncVerdaccioTask {
    <#
      `schtasks /End` wrapper. Throws on a non-zero exit code (same EAP
      pattern as Start-OSyncVerdaccioTask).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TaskName
    )
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & schtasks.exe /End /TN $TaskName 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldEap
    }
    if ($code -ne 0) {
        throw "Invoke-OSyncNpmApply: 'schtasks /End /TN $TaskName' failed with exit code $code."
    }
}

function Resolve-OSyncNpmExe {
    <#
      Resolves the npm executable (npm.cmd on Windows). npm.ps1 is
      deliberately NOT accepted: Invoke-ONpmCli runs npm through cmd.exe,
      which cannot execute a .ps1 file, and `Get-Command npm` prefers
      npm.ps1 over npm.cmd when Node ships both in the same directory.
      Throws when npm is not available - the apply cannot verify without it.
    #>
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($null -eq $cmd) {
        $cmd = Get-Command npm.exe -ErrorAction SilentlyContinue
    }
    if ($null -eq $cmd) {
        throw "Invoke-OSyncNpmApply: 'npm' was not found on PATH - npm is required for the registry verification."
    }
    return $cmd.Source
}

function Invoke-ONpmCli {
    <#
      Runs npm via cmd.exe (npm.cmd is a batch file - CreateProcess cannot
      execute it directly) with a hard timeout. Returns
      { ExitCode, Output (stdout+stderr lines), TimedOut }.
      The timeout path kills the whole process tree (taskkill /T) so a hung
      npm cannot leave an orphaned node.exe behind.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$NpmExe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSeconds = 120
    )

    $argText = ($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    # /d ignores AutoRun, /s strips the outer quotes so the inner quoted
    # npm.cmd path (which may contain spaces) is executed verbatim.
    $psi.Arguments = '/d /s /c ""' + $NpmExe + '" ' + $argText + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $exited = $proc.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & taskkill.exe /PID $proc.Id /T /F 2>&1
        }
        catch { }
        finally {
            $ErrorActionPreference = $oldEap
        }
        $proc.WaitForExit(5000) | Out-Null
        return [pscustomobject]@{ ExitCode = -1; Output = @(); TimedOut = $true }
    }

    $lines = @()
    $lines += ($outTask.Result -split "`r?`n")
    $lines += ($errTask.Result -split "`r?`n")
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = @($lines); TimedOut = $false }
}

function Invoke-OSyncNpmApply {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,

        [Parameter(Mandatory = $true)]
        $Config,

        # The scheduled task that runs the B-side Verdaccio service (registered
        # by Install-OfflineBootstrap, plan todo 12 / Register-SyncTasks todo
        # 17). Injectable so QA can point at a clearly-named temporary task.
        [Parameter(Mandatory = $false)]
        [string]$VerdaccioTaskName = 'PakageSync-Verdaccio',

        # QA seam: skip task stop/start AND the /MIR refresh (a running
        # service's data dir must never be /MIR'd - the strict order exists
        # for that reason). QA starts a portable Verdaccio manually against
        # the work copy; the apply only waits for the port.
        [Parameter(Mandatory = $false)]
        [switch]$SkipVerdaccioTask,

        # QA seam: full override - skip task management, the /MIR refresh and
        # the port wait; all verification runs against this already-listening
        # endpoint. The npmrc/env still point at config.verdaccioPort.
        [Parameter(Mandatory = $false)]
        [string]$VerdaccioEndpoint
    )

    $port = [int]$Config.verdaccioPort
    if ($port -lt 1 -or $port -gt 65535) {
        throw "Invoke-OSyncNpmApply: config.verdaccioPort must be 1-65535; got '$port'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.stateDir)) {
        throw "Invoke-OSyncNpmApply: config.stateDir is empty - the local Verdaccio copy has nowhere to live."
    }
    $registryUrl = if (-not [string]::IsNullOrWhiteSpace($VerdaccioEndpoint)) {
        $VerdaccioEndpoint.TrimEnd('/')
    }
    else {
        "http://127.0.0.1:$port"
    }

    Write-OSyncLog -Category 'npm' -Level Info -Message "npm apply starting (workDir='$WorkDir', port=$port, task='$VerdaccioTaskName', skipTask=$SkipVerdaccioTask)." -Config $Config | Out-Null

    # --- 1. assert verdaccio-b.yml (no uplinks/proxy, storage ./storage) ---
    $npmDir = Join-Path $WorkDir 'npm'
    $bYamlPath = Join-Path $npmDir 'verdaccio-b.yml'
    if (-not (Test-Path -LiteralPath $bYamlPath -PathType Leaf)) {
        throw "Invoke-OSyncNpmApply: '<WorkDir>\npm\verdaccio-b.yml' not found at '$bYamlPath' - the npm category export is incomplete."
    }
    $bYaml = [System.IO.File]::ReadAllText($bYamlPath)
    if (-not (Test-OSyncVerdaccioBYaml -Content $bYaml)) {
        throw "Invoke-OSyncNpmApply: '$bYamlPath' failed the offline assertion - it must contain NO uplinks/proxy keys and storage must be the relative path './storage' (a leaked uplink would hang offline requests)."
    }
    Write-OSyncLog -Category 'npm' -Level Info -Message "verdaccio-b.yml assertion passed (no uplinks/proxy, storage ./storage)." -Config $Config | Out-Null

    # --- 1.5 + 2. refresh the local copy and manage the service ---
    # STRICT ORDER (Oracle r5 watch-out): stop the task -> /MIR the local copy
    # -> start the task. The service reads ONLY the local copy
    # <stateDir>\verdaccio; a running service's data dir must never be /MIR'd.
    $localCopy = Join-Path $Config.stateDir 'verdaccio'
    $manageTask = (-not $SkipVerdaccioTask) -and [string]::IsNullOrWhiteSpace($VerdaccioEndpoint)
    if ($manageTask) {
        $taskState = Get-OSyncVerdaccioTaskState -TaskName $VerdaccioTaskName
        if ($null -eq $taskState) {
            throw "Invoke-OSyncNpmApply: scheduled task '$VerdaccioTaskName' was not found - it is registered by Install-OfflineBootstrap (plan todo 12) / Register-SyncTasks (todo 17). For QA against a manually-started Verdaccio pass -SkipVerdaccioTask."
        }
        if ($taskState -eq 'Running') {
            Stop-OSyncVerdaccioTask -TaskName $VerdaccioTaskName
            Write-OSyncLog -Category 'npm' -Level Info -Message "stopped task '$VerdaccioTaskName' (strict order: stop -> copy -> start)." -Config $Config | Out-Null
            # Wait for the port to be released so the /MIR never races the
            # still-running service (bounded; robocopy /R:3 /W:5 retries cover
            # transient locks).
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.Elapsed.TotalSeconds -lt 15 -and (Test-OSyncPortListening -Port $port)) {
                Start-Sleep -Milliseconds 250
            }
            if (Test-OSyncPortListening -Port $port) {
                Write-Warning "Invoke-OSyncNpmApply: port $port is still LISTENING 15 s after stopping task '$VerdaccioTaskName'."
            }
        }

        # Invoke-OSyncRobocopy RETURNS the robocopy exit code - pipe to
        # Out-Null so the apply report object is the ONLY thing this function
        # emits (same leak class as the Write-OSyncLog pattern, see learnings).
        Invoke-OSyncRobocopy -Source $npmDir -Destination $localCopy -ExtraArgs @('/MIR') | Out-Null
        if (-not (Test-Path -LiteralPath (Join-Path $localCopy 'verdaccio-b.yml') -PathType Leaf)) {
            throw "Invoke-OSyncNpmApply: the local copy refresh did not produce '$localCopy\verdaccio-b.yml'."
        }
        Write-OSyncLog -Category 'npm' -Level Info -Message "local copy refreshed: '$npmDir' -> '$localCopy' (/MIR)." -Config $Config | Out-Null

        # Port hygiene before /Run: something else already holding the port
        # would make the task's Verdaccio fail to bind.
        if (Test-OSyncPortListening -Port $port) {
            throw "Invoke-OSyncNpmApply: port $port is already in use by another process - cannot start the Verdaccio service. Stop the process occupying the port or change config.verdaccioPort."
        }
        Start-OSyncVerdaccioTask -TaskName $VerdaccioTaskName
        Write-OSyncLog -Category 'npm' -Level Info -Message "started task '$VerdaccioTaskName'." -Config $Config | Out-Null
    }

    # Wait for the registry to LISTEN (30 s timeout -> explicit error).
    if ([string]::IsNullOrWhiteSpace($VerdaccioEndpoint)) {
        if (-not (Wait-OSyncPortListening -Port $port -TimeoutSeconds 30)) {
            throw "Invoke-OSyncNpmApply: Verdaccio did not open port $port within 30 s - the registry is not reachable at http://127.0.0.1:$port/. Check the '$VerdaccioTaskName' task and the verdaccio logs."
        }
        Write-OSyncLog -Category 'npm' -Level Info -Message "registry is LISTENING on 127.0.0.1:$port." -Config $Config | Out-Null
    }

    # --- 3. registry config (Oracle B1) ---
    $nodeInstallDir = Resolve-OSyncNodeInstallDir
    $npmrcChanged = Set-OSyncNpmRegistryConfig -NodeInstallDir $nodeInstallDir -Port $port -Config $Config
    Set-OSyncMachineEnvVar -Name 'NPM_CONFIG_REGISTRY' -Value "http://127.0.0.1:$port/"
    Write-OSyncLog -Category 'npm' -Level Info -Message "machine env NPM_CONFIG_REGISTRY=http://127.0.0.1:$port/ set (belt-and-braces)." -Config $Config | Out-Null

    # --- 4. verification ---
    $npmExe = Resolve-OSyncNpmExe

    # 4a. npm view of the first packages.txt entry returns a version.
    $listPath = Join-Path $npmDir 'packages.txt'
    if (-not (Test-Path -LiteralPath $listPath -PathType Leaf)) {
        throw "Invoke-OSyncNpmApply: '<WorkDir>\npm\packages.txt' not found at '$listPath'."
    }
    $entries = @(Read-OSyncNpmList -Path $listPath)
    if ($entries.Count -eq 0) {
        throw "Invoke-OSyncNpmApply: '$listPath' contains no package entries."
    }
    $first = $entries[0]
    $spec = if ($null -ne $first.Version -and $first.Version.Length -gt 0) { "$($first.Name)@$($first.Version)" } else { $first.Name }

    $viewResult = Invoke-ONpmCli -NpmExe $npmExe -Arguments @('view', $spec, '--registry', $registryUrl) -TimeoutSeconds 60
    $viewText = ($viewResult.Output -join "`n")
    if ($viewResult.TimedOut -or $viewResult.ExitCode -ne 0) {
        $tail = ((@($viewResult.Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 5) -join '; ')
        throw "Invoke-OSyncNpmApply: 'npm view $spec --registry $registryUrl' failed (exit $($viewResult.ExitCode)): $tail"
    }
    if ($viewText -notmatch '\d+\.\d+\.\d+') {
        throw "Invoke-OSyncNpmApply: 'npm view $spec --registry $registryUrl' returned no version: $viewText"
    }
    Write-OSyncLog -Category 'npm' -Level Info -Message "npm view $spec hit the local registry (version found)." -Config $Config | Out-Null

    # 4b. a guaranteed-nonexistent package must FAIL FAST within 30 s (no
    # uplink hang, Metis M4).
    $ghost = 'osync-nonexistent-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ghostResult = Invoke-ONpmCli -NpmExe $npmExe -Arguments @('view', $ghost, '--registry', $registryUrl) -TimeoutSeconds 30
    $sw.Stop()
    if ($ghostResult.TimedOut) {
        throw "Invoke-OSyncNpmApply: 'npm view $ghost --registry $registryUrl' did not fail fast - it hung for 30 s. An uplink would hang forever; verdaccio-b.yml must have no uplinks."
    }
    if ($ghostResult.ExitCode -eq 0) {
        throw "Invoke-OSyncNpmApply: 'npm view $ghost --registry $registryUrl' unexpectedly succeeded - the registry served a nonexistent package."
    }
    Write-OSyncLog -Category 'npm' -Level Info -Message "nonexistent package '$ghost' failed fast in $([Math]::Round($sw.Elapsed.TotalSeconds, 2)) s (exit $($ghostResult.ExitCode)) - no uplink hang." -Config $Config | Out-Null

    # 4c. a NEW PROCESS WITHOUT FLAGS must resolve the local registry
    # (flag-carrying checks cannot catch config fallback, Oracle B1).
    $cfgResult = Invoke-ONpmCli -NpmExe $npmExe -Arguments @('config', 'get', 'registry') -TimeoutSeconds 30
    if ($cfgResult.TimedOut -or $cfgResult.ExitCode -ne 0) {
        throw "Invoke-OSyncNpmApply: 'npm config get registry' failed (exit $($cfgResult.ExitCode)) - the built-in npmrc rewrite or NPM_CONFIG_REGISTRY is not in effect."
    }
    $cfgLines = @($cfgResult.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $cfgValue = if ($cfgLines.Count -gt 0) { ([string]$cfgLines[$cfgLines.Count - 1]).Trim() } else { '' }
    $expected = $registryUrl + '/'
    if ($cfgValue -ne $expected) {
        throw "Invoke-OSyncNpmApply: 'npm config get registry' (new process, no flags) returned '$cfgValue' - expected '$expected'. The built-in npmrc rewrite or the machine NPM_CONFIG_REGISTRY is not in effect."
    }
    Write-OSyncLog -Category 'npm' -Level Info -Message "new-process 'npm config get registry' = '$cfgValue' (config fallback verified)." -Config $Config | Out-Null

    # --- 5. state.npm = { registryOk: $true, at } ---
    $state = Get-OSyncState -Category 'npm' -Config $Config
    if ($null -eq $state['npm'] -or $state['npm'] -isnot [System.Collections.IDictionary]) {
        $state['npm'] = [ordered]@{}
    }
    $at = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $state['npm']['registryOk'] = $true
    $state['npm']['at'] = $at
    Save-OSyncState -Category 'npm' -State $state -Config $Config | Out-Null
    Write-OSyncLog -Category 'npm' -Level Info -Message "state.npm = { registryOk: true, at: $at }." -Config $Config | Out-Null

    Write-OSyncLog -Category 'npm' -Level Info -Message "npm apply done (registry $registryUrl OK)." -Config $Config | Out-Null

    return [pscustomobject]@{
        category          = 'npm'
        registryUrl       = $registryUrl
        nodeInstallDir    = $nodeInstallDir
        npmrc             = (Join-Path $nodeInstallDir 'node_modules\npm\npmrc')
        npmrcChanged      = $npmrcChanged
        viewSpec          = $spec
        ghostName         = $ghost
        ghostElapsedSec   = [Math]::Round($sw.Elapsed.TotalSeconds, 2)
        configGetRegistry = $cfgValue
        registryOk        = $true
        at                = $at
    }
}