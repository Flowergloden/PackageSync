#Requires -Version 5.1
<#
  Export-OfflineRepo.ps1 - A-side export orchestrator entry point.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Export-OfflineRepo.ps1 [-ConfigPath <path>] [-Category winget,pip,npm,dotfiles]

  Thin wrapper around Invoke-OSyncExport (src\lib\ExportOrchestrator.ps1):
  imports the module relative to its own location, resolves the default
  config path (<repo>\config\packagesync.json), and maps the report's
  Success flag to the process exit code (0 = full export -> integrity ->
  publish chain OK, 1 = anything else).

  Registered as the daily 02:00 scheduled task 'PakageSync-Export' by
  src\Register-SyncTasks.ps1 -Role A.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$Category = 'winget,pip,npm,dotfiles'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'OfflineSync.psd1') -Force

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

try {
    $result = Invoke-OSyncExport -ConfigPath $ConfigPath -Category $Category
    if ($result.success) {
        exit 0
    }
    exit 1
}
catch {
    Write-Host "Export-OfflineRepo: FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}