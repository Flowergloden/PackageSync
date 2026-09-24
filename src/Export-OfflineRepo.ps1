#Requires -Version 5.1
<#
  Export-OfflineRepo.ps1 - A-side export orchestrator entry point.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Export-OfflineRepo.ps1 [-ConfigPath <path>] [-Category winget,pip,npm,dotfiles] [-Quiet] [-SkipRuntime]

  Thin wrapper around Invoke-OSyncExport (src\lib\ExportOrchestrator.ps1):
  imports the module relative to its own location, resolves the default
  config path (<repo>\config\packagesync.json), and maps the report's
  Success flag to the process exit code (0 = full export -> integrity ->
  publish chain OK, 1 = anything else).

  Before exporting, existing package manifests are refreshed non-interactively
  from locally installed versions. This also applies to scheduled runs.
  Runtime manifests are left unchanged when -SkipRuntime is used.

  Manual runs echo live progress to the console by default (milestone log
  lines plus throttled winget download output); -Quiet restores the old
  silent behavior (log files only).

  -SkipRuntime skips the runtime re-export (VC_redist/bun downloads,
  Python/Node winget downloads, portable Verdaccio build, tool snapshot)
  and reuses the payloads already published in <repoRoot> - the reused
  files are re-manifested into the new generation, so the trust chain is
  unchanged. Requires a previous full export; fails fast otherwise.

  Registered as the daily 02:00 scheduled task 'PakageSync-Export' by
  src\Register-SyncTasks.ps1 -Role A.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$Category = 'winget,pip,npm,dotfiles',

    [Parameter(Mandatory = $false)]
    [switch]$Quiet,

    # Skips the runtime re-export and reuses the payloads already published
    # in <repoRoot> (see Invoke-OSyncExport -SkipRuntime).
    [Parameter(Mandatory = $false)]
    [switch]$SkipRuntime
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'OfflineSync.psd1') -Force

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

try {
    $result = Invoke-OSyncExport -ConfigPath $ConfigPath -Category $Category -Quiet:$Quiet -SkipRuntime:$SkipRuntime
    if ($result.success) {
        exit 0
    }
    exit 1
}
catch {
    Write-Host "Export-OfflineRepo: FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}