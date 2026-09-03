#Requires -Version 5.1
<#
  Winget.Common.ps1 - shared winget plumbing for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  $script:WingetSatisfiedExitCodes:
    winget "install" exit codes that mean the package is already satisfied
    (already installed / no applicable upgrade). The B-side apply flows
    (todo 12 / todo 13) treat these as idempotent success and ONLY READ this
    constant - it is the single source of truth (Momus r4-M3).

    Initial value @(0) per plan todo 1. TODO (todo 13 QA): extend this set
    after real double-install testing; each added entry must be documented
    with the observed scenario and the winget version it was observed on.

  Resolve-OSyncWingetExePath:
    Globs C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe
    and returns the full path of the newest version. Returns $null and writes
    a warning when no winget.exe is found.
#>

$script:WingetSatisfiedExitCodes = @(0)

function Resolve-OSyncWingetExePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # App Installer ships winget.exe inside the versioned package folder and
    # the package can be updated in place, so pick the newest version folder.
    $pattern = Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
    $items = @(Get-Item -Path $pattern -ErrorAction SilentlyContinue)
    if ($items.Count -eq 0) {
        Write-Warning "Resolve-OSyncWingetExePath: no winget.exe found matching '$pattern'."
        return $null
    }

    $entries = foreach ($item in $items) {
        $version = $null
        if ($item.Directory.Name -match '^Microsoft\.DesktopAppInstaller_(\d+(\.\d+)+)_.*$') {
            try {
                $version = [version]$Matches[1]
            }
            catch {
                $version = $null
            }
        }
        [pscustomobject]@{ FullName = $item.FullName; Version = $version }
    }

    $best = $entries |
        Sort-Object -Property @{ Expression = { $_.Version } } -Descending |
        Select-Object -First 1
    if ($null -eq $best) {
        Write-Warning "Resolve-OSyncWingetExePath: could not rank winget.exe candidates under '$pattern'."
        return $null
    }
    return $best.FullName
}
