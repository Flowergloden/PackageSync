#Requires -Version 5.1
<#
  Winget.Common.ps1 - shared winget plumbing for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  $script:WingetSuccessfulInstallExitCodes:
    winget install exit codes that mean installation completed successfully.
    0x8A150109 wraps installer exit 3010 (success, reboot required).

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

$script:WingetSuccessfulInstallExitCodes = @(
    0,
    -1978334967 # 0x8A150109: installer returned 3010 (success, reboot required)
)

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

function Test-OSyncWingetNeedsUserScope {
    <#
    .SYNOPSIS
    Detects whether a downloaded manifest set must be installed with user scope.

    .DESCRIPTION
    MSIX/AppX installers cannot be installed with --scope machine.  Some
    traditional installers are also explicitly marked Scope: user (for
    example, a user-only NSIS package), and winget rejects those when the
    machine scope is forced.  Keep this decision in shared winget plumbing so
    export and apply use the same rule.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    if (-not [System.IO.Directory]::Exists($PackageDir)) { return $false }

    $yamls = @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    $userScopePattern = '(?im)^\s*Scope:\s*user\s*$'
    $msixPattern = '(?im)^\s*InstallerType:\s*(msix|appx)\b'

    foreach ($yaml in $yamls) {
        $text = [System.IO.File]::ReadAllText($yaml.FullName, [System.Text.Encoding]::UTF8)
        if ($text -match $userScopePattern -or $text -match $msixPattern) {
            return $true
        }
    }
    return $false
}

function Test-OSyncWingetDownloadRetryable {
    <#
    .SYNOPSIS
    Returns true for transient winget download failures worth retrying.

    .DESCRIPTION
    Deterministic selection failures (version not found / no applicable
    installer) are deliberately excluded. The retry set is limited to
    download/service failures that can clear after a network or service blip.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0,

        [Parameter(Mandatory = $false)]
        [switch]$TimedOut
    )

    if ($TimedOut) { return $false }
    return ($ExitCode -in @(
        -1978335224, # 0x8A150008 APPINSTALLER_CLI_ERROR_DOWNLOAD_FAILED
        -1978335125, # 0x8A15006B APPINSTALLER_CLI_ERROR_DOWNLOAD_DEPENDENCIES
        -1978335123, # 0x8A15006D APPINSTALLER_CLI_ERROR_SERVICE_UNAVAILABLE
        -1978335098  # 0x8A150086 APPINSTALLER_CLI_ERROR_INSTALLER_ZERO_BYTE_FILE
    ))
}
function Get-OSyncWingetDownloadFailureReason {
    <#
    .SYNOPSIS
    Maps a winget download result to an actionable report reason.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0,

        [Parameter(Mandatory = $false)]
        [switch]$TimedOut,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Output = ''
    )

    if ($TimedOut) { return 'timeout' }
    switch ($ExitCode) {
        -1978335123 { return 'winget service unavailable' }
        -1978335224 { return 'installer download failed' }
        -1978335216 { return 'no applicable installer' }
        -1978335209 { return 'version not found' }
    }
    if ($Output -match '(?i)no applicable installer|找不到适用的安装程序') {
        return 'no applicable installer'
    }
    if ($Output -match '(?i)no manifest found|找不到匹配的版本') {
        return 'version not found'
    }
    return 'download failed'
}
function Test-OSyncWingetNoApplicableInstaller {
    <#
    .SYNOPSIS
    Identifies winget's "no applicable installer" result.

    .DESCRIPTION
    The exit code is stable for the observed winget CLI, while the output is
    retained as a locale-tolerant fallback because winget can render native
    errors as localized text.  This is intentionally narrower than a generic
    download failure: only this result is eligible for the machine-to-user
    retry used by the exporter.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $false)]
        [int]$ExitCode = 0,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Output = ''
    )

    if ($ExitCode -eq -1978335216) { return $true }
    return ($Output -match '(?i)no applicable installer|找不到适用的安装程序')
}
