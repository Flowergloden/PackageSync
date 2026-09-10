#Requires -Version 5.1
<#
  Invoke-OfflineApply.ps1 - B-side apply entry point.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Invoke-OfflineApply.ps1 [-ConfigPath <path>] [-Category winget,pip,npm,dotfiles] [-WhatIf] [-SkipRuntime]

  Thin wrapper around Invoke-OSyncApply (src\lib\ApplyOrchestrator.ps1):
  imports the module relative to its own location, resolves the default
  config path (<repo>\config\packagesync.json - the B-LOCAL config on the
  landed tool copy at C:\PakageSync), acquires the shared apply.lock (the
  lock is taken ONLY by the entry scripts - todo 12 and todo 17, Momus
  r7-m3), and maps the result to the process exit code:
      0 = round completed or skipped (nothing pending / index invalid / lock
          held - all normal "retry next cycle" conditions)
      1 = any hard failure (fatal config/role error, or a round outcome of
          'failed' - e.g. a work-copy re-verification failure)

  Mode (Momus r5-m2): -Category containing ONLY 'dotfiles' runs the
  USER-context dotfiles round (no work-copy creation, consume the newest
  .verified generation, never bootstrap/refresh/cleanup); anything else
  (incl. omitting -Category) runs the PACKAGES/SYSTEM round. The two
  scheduled tasks pin their -Category accordingly (todo 17).

  -WhatIf performs ZERO changes: the repository and state are only read, a
  per-category "would install/update" report is produced, and no bootstrap /
  work copy / apply / self-refresh / cleanup happens (the log directory is
  created as an operational artifact - same convention as the bootstrap).

  -SkipRuntime suppresses ONLY the runtime-drift-triggered bootstrap
  self-heal in the packages round: a drifted runtime payload
  (runtimeWingetHash / runtimeFilesHash vs system-state) is not reinstalled
  this round, the categories still apply. A machine that never bootstrapped
  is unaffected and always bootstraps (it has no Python/Node/Verdaccio and
  could not apply anything otherwise).

  QA seams (production uses the defaults): -VerdaccioTaskName /
  -WingetSettingsTaskName let a QA run use clearly temp-named scheduled
  tasks so the A-side task store is never polluted with B-side service
  names (same convention as Install-OfflineBootstrap).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$Category,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    # Suppresses ONLY the runtime-drift-triggered bootstrap self-heal (a
    # never-bootstrapped machine still bootstraps - see Invoke-OSyncApply).
    [Parameter(Mandatory = $false)]
    [switch]$SkipRuntime,

    [Parameter(Mandatory = $false)]
    [string]$VerdaccioTaskName = 'PakageSync-Verdaccio',

    [Parameter(Mandatory = $false)]
    [string]$WingetSettingsTaskName = 'PakageSync-WingetSettings-OneShot',

    # QA seam: shorten the apply.lock wait (production always waits the full
    # 60 s before skipping a round, Momus m6).
    [Parameter(Mandatory = $false)]
    [int]$LockTimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'OfflineSync.psd1') -Force

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

$categoryList = @()
if (-not [string]::IsNullOrWhiteSpace($Category)) {
    $categoryList = @($Category -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

try {
    $config = Get-OSyncConfig -Path $ConfigPath
    if ($config.role -ne 'B') {
        throw "Invoke-OfflineApply: config role must be 'B' (got '$($config.role)') - the apply is a B-side operation."
    }
    $mode = Get-OSyncApplyMode -Category $categoryList
    $stateDir = [string]$config.stateDir
    if ([string]::IsNullOrWhiteSpace($stateDir)) {
        throw 'Invoke-OfflineApply: config.stateDir is empty.'
    }

    if (-not $WhatIf) {
        # The lock file needs run\ to exist (UsersModify - both the SYSTEM
        # packages task and the user dotfiles task may take it).
        New-Item -ItemType Directory -Path (Join-Path $stateDir 'run') -Force | Out-Null
        if (-not (Test-OSyncAcquireBootstrapLock -StateDir $stateDir -TimeoutSeconds $LockTimeoutSeconds)) {
            Write-Host "Invoke-OfflineApply: another apply/bootstrap holds '<stateDir>\run\apply.lock' - skipping this run."
            exit 0
        }
    }

    try {
        $result = Invoke-OSyncApply -Config $config -Category $categoryList -WhatIf:$WhatIf -SkipRuntime:$SkipRuntime `
            -VerdaccioTaskName $VerdaccioTaskName -WingetSettingsTaskName $WingetSettingsTaskName
        Write-Host ("Invoke-OfflineApply: mode={0} outcome={1}" -f $result.mode, $result.outcome)
        if (-not [string]::IsNullOrWhiteSpace($result.skipReason)) {
            Write-Host ("  skip: {0}" -f $result.skipReason)
        }
        if (-not [string]::IsNullOrWhiteSpace($result.error)) {
            Write-Host ("  error: {0}" -f $result.error) -ForegroundColor Red
        }
        foreach ($catName in @('winget', 'pip', 'npm', 'dotfiles')) {
            if ($result.categories.Contains($catName)) {
                $cr = $result.categories[$catName]
                Write-Host ("  [{0}] {1}: {2}" -f $cr.category, $cr.status, $cr.message)
            }
        }
        if ($result.mode -eq 'packages') {
            if ($result.generation) { Write-Host ("  generation: {0} (verified={1})" -f $result.generation, $result.verified) }
            Write-Host ("  self-refresh: refreshed={0} {1}" -f $result.refreshed, $result.refreshSkippedReason)
            Write-Host ("  work cleanup: removed={0} generation(s)" -f $result.cleaned)
        }
        if ($result.outcome -eq 'failed') { exit 1 }
        exit 0
    }
    finally {
        if (-not $WhatIf) {
            Remove-OSyncBootstrapLock -StateDir $stateDir
        }
    }
}
catch {
    Write-Host "Invoke-OfflineApply: FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
