#Requires -Version 5.1
<#
  Winget.Common.ps1 - shared winget plumbing for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  $script:WingetSatisfiedExitCodes:
    winget "install" exit codes that mean the package is already satisfied
    (already installed / no applicable upgrade). The B-side apply flows
    (todo 12 / todo 13) treat these as idempotent success and ONLY READ this
    constant - it is the single source of truth (Momus r4-M3).

    OBSERVED (winget v1.29.290, QA 2026-09-04, todo 13):
      `winget install --manifest <dir>` on an already-installed package does
      NOT return a non-zero "already installed" code. Verified scenarios:
        * same-version reinstall (7zip.7zip 26.02 installed, 26.02 manifest)
          -> exit 0, winget re-runs the installer (repair) and reports success
        * older-version manifest (26.01 manifest while 26.02 installed)
          -> exit 0, winget runs the installer regardless
      The classic `winget install --id` path DOES return a non-zero
      "no applicable upgrade" code (observed -1978335189 / 0x8A15002B), but
      the apply flows use --manifest exclusively, so that code is NOT added.
      Conclusion: @(0) is the complete satisfied set for the --manifest path;
      the satisfied branch below is kept as a defensive extension point for
      future winget versions that may return dedicated satisfied codes.

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
