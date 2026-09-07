#Requires -Version 5.1
<#
  Install-OfflineBootstrap.ps1 - B-side runtime bootstrap entry point.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Install-OfflineBootstrap.ps1 [-ConfigPath <path>] [-WhatIf]

  Thin wrapper around Invoke-OSyncBootstrap (src\lib\Bootstrap.ps1): imports
  the module relative to its own location, resolves the default config path
  (<repo>\config\packagesync.b.json), acquires the shared apply.lock (the
  lock is taken ONLY by the entry scripts - todo 12 and todo 17, Momus
  r7-m3), and maps the result to the process exit code:
      0 = bootstrap completed (bootstrapped set / all steps skipped or done)
      1 = any failure (a failed step leaves state.bootstrapped = false)

  -WhatIf performs ZERO changes: the repository is only read, every step is
  detected and reported as "would ...", and no state / work copy / tasks /
  C:\PakageSync are touched.

  The operator runs this ONCE, elevated, on the B machine after the first
  repository sync. Every step is detect-then-execute, so re-running is
  idempotent (a full second run = all skips).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    # QA seams (production uses the defaults): a QA run must use clearly
    # temp-named scheduled tasks and delete them in the same run so A's task
    # store is never polluted with B-side service names.
    [Parameter(Mandatory = $false)]
    [string]$VerdaccioTaskName = 'PakageSync-Verdaccio',

    [Parameter(Mandatory = $false)]
    [string]$WingetSettingsTaskName = 'PakageSync-WingetSettings-OneShot'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'OfflineSync.psd1') -Force

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.b.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

$config = Get-OSyncConfig -Path $ConfigPath
if ($config.role -ne 'B') {
    throw "Install-OfflineBootstrap: config role must be 'B' (got '$($config.role)') - the bootstrap is a B-side operation."
}

$stateDir = [string]$config.stateDir

if (-not $WhatIf) {
    # The lock file needs run\ to exist.
    New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
    if (-not (Test-OSyncAcquireBootstrapLock -StateDir $stateDir -TimeoutSeconds 60)) {
        Write-Host "Install-OfflineBootstrap: another apply/bootstrap holds '<stateDir>\run\apply.lock' - skipping this run."
        exit 0
    }
}

try {
    $result = Invoke-OSyncBootstrap -Config $config -WhatIf:$WhatIf `
        -VerdaccioTaskName $VerdaccioTaskName -WingetSettingsTaskName $WingetSettingsTaskName
    if ($result.Success) {
        Write-Host "Install-OfflineBootstrap: SUCCESS (bootstrapped=$($result.Bootstrapped), repo exportedAtUtc=$($result.ExportedAtUtc))."
        foreach ($step in $result.Steps) {
            Write-Host ("  [{0}] {1}: {2}" -f $step.Step, $step.Status, $step.Message)
        }
        exit 0
    }
    Write-Host "Install-OfflineBootstrap: FAILED (step '$($result.Steps[-1].Step)'): $($result.Error)" -ForegroundColor Red
    exit 1
}
catch {
    Write-Host "Install-OfflineBootstrap: FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    if (-not $WhatIf) {
        Remove-OSyncBootstrapLock -StateDir $stateDir
    }
}
