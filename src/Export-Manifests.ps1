#Requires -Version 5.1
<#
  Export-Manifests.ps1 - A-side interactive manifest generator entry point.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Export-Manifests.ps1 [-ConfigPath <path>] [-Category winget,pip,npm,bun]

  Thin wrapper around Invoke-OSyncManifestGenerate (src\lib\ManifestGenerate.ps1):
  imports the module relative to its own location, resolves the default
  config path (<repo>\config\packagesync.json), and maps success to the
  process exit code (0 = all requested categories processed, 1 = anything
  else).

  This is a MANUAL operator tool: it collects the installed packages from
  the A machine (winget export / pip freeze / npm ls -g / bun pm ls -g),
  lets the operator pick entries at the console (numbered multi-select)
  and writes them back into the manifests pinned to the installed
  versions. The bun category is opt-in (not in the default -Category
  list) and presence-gated: it is skipped when the config has no
  paths.bunList key. The tool requires an interactive console session
  (never registered as a scheduled task) and an A-role config.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$Category = 'winget,pip,npm'
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'OfflineSync.psd1') -Force

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

try {
    $config = Get-OSyncConfig -Path $ConfigPath
    if ($config.role -ne 'A') {
        throw "Export-Manifests: config role must be 'A' (got '$($config.role)') - this script generates manifests on the A-side machine."
    }

    if (-not [Environment]::UserInteractive) {
        Write-Host "Export-Manifests: interactive manifest generation requires an interactive console session (not available under a scheduled task or non-interactive session)." -ForegroundColor Red
        exit 1
    }

    $requested = @($Category -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    $invalid = @($requested | Where-Object { $_ -notin @('winget', 'pip', 'npm', 'bun') })
    if ($invalid.Count -gt 0) {
        throw "Export-Manifests: unknown -Category value(s): '$($invalid -join ', ')' - valid values: winget,pip,npm,bun."
    }

    $null = Invoke-OSyncManifestGenerate -Config $config -Category $requested
    exit 0
}
catch {
    Write-Host "Export-Manifests: FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}