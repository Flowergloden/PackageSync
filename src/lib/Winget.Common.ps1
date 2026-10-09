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
    Prefers the current user's App Execution Alias resolved by
    `Get-Command winget`.  Launching the versioned binary directly from
    C:\Program Files\WindowsApps can fail with Access Denied in a normal
    (non-elevated) A-side shell even though winget is installed.  When the
    alias is unavailable (for example under SYSTEM), the resolver falls back
    to the newest versioned package binary under
    C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe.
    Returns $null and writes a warning when neither form is found.
#>

$script:WingetSuccessfulInstallExitCodes = @(
    0,
    -1978334967 # 0x8A150109: installer returned 3010 (success, reboot required)
)

$script:WingetSatisfiedExitCodes = @(0)

function Get-OSyncWingetExecutionAliasPath {
    <#
      Returns the App Execution Alias path exposed by the current Windows
      identity, when one is available.  Restrict the accepted path to the
      WindowsApps alias directory so an unrelated winget.exe earlier on PATH
      cannot silently replace the App Installer binary used by PakageSync.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $commands = @(Get-Command winget -CommandType Application -All -ErrorAction SilentlyContinue)
    foreach ($command in $commands) {
        if ($null -eq $command) { continue }

        $candidate = $null
        foreach ($propertyName in @('Source', 'Path', 'Definition')) {
            $property = $command.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $candidate = [string]$property.Value
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }

        try {
            $candidate = [System.IO.Path]::GetFullPath($candidate)
        }
        catch {
            continue
        }

        # Do not accept the versioned package path here: that is exactly the
        # path which can be denied to a non-elevated A-side shell.  The
        # resolver below still uses it as the fallback for identities without
        # an alias (notably SYSTEM tasks).
        if ($candidate -notmatch '(?i)\\Microsoft\\WindowsApps\\winget\.exe$') { continue }
        if ($candidate -match '(?i)\\Program Files\\WindowsApps\\') { continue }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }

        return $candidate
    }

    return $null
}

function Resolve-OSyncWingetExePath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # Prefer the per-user App Execution Alias.  The alias is the supported
    # launch surface for an interactive A-side user and avoids the WindowsApps
    # ACL failure that occurs when ProcessStartInfo targets the package binary
    # directly.
    $alias = Get-OSyncWingetExecutionAliasPath
    if (-not [string]::IsNullOrWhiteSpace($alias)) {
        return $alias
    }

    # App Installer ships winget.exe inside the versioned package folder and
    # the package can be updated in place, so pick the newest version folder.
    # This is primarily the SYSTEM/non-interactive fallback where the current
    # identity has no per-user App Execution Alias.
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

function Test-OSyncWingetIsPortable {
    <#
    .SYNOPSIS
    Returns true when a package directory's *.yaml declares a portable installer.

    .DESCRIPTION
    winget expresses portable packaging as `InstallerType: portable`, or as an
    archive installer (`InstallerType: zip`) whose nested payload is portable
    (`NestedInstallerType: portable`).  Both forms are matched at any
    indentation, mirroring Test-OSyncWingetNeedsUserScope's line-based scan.

    This drives the B-side reactive machine->user scope fallback, so the gate is
    deliberately narrow: every non-portable installer type (wix/msi/exe/inno/
    burn/nullsoft/msix/appx/...) returns $false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageDir
    )

    if (-not [System.IO.Directory]::Exists($PackageDir)) { return $false }

    $yamls = @(Get-ChildItem -LiteralPath $PackageDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
    $portablePattern = '(?im)^\s*(?:InstallerType|NestedInstallerType):\s*portable\b'

    foreach ($yaml in $yamls) {
        $text = [System.IO.File]::ReadAllText($yaml.FullName, [System.Text.Encoding]::UTF8)
        if ($text -match $portablePattern) { return $true }
    }
    return $false
}

function Test-OSyncWingetNeedsUserScopeRetry {
    <#
    .SYNOPSIS
    Returns true when a failed winget install is worth retrying with user scope.

    .DESCRIPTION
    Only permission / portable-class failures qualify:

        -2147024891  0x80070005  E_ACCESSDENIED
        -1978335150  0x8A150052  PORTABLE_INSTALL_FAILED
        -1978335148  0x8A150054  PORTABLE_PACKAGE_ALREADY_EXISTS
        -1978335145  0x8A150057  PORTABLE_UNINSTALL_FAILED

    The signed exit code is the primary signal.  A locale-tolerant text
    fallback recognises the same conditions when winget renders a localized
    message, because the CLI can emit localized text instead of the stable
    code.  Deterministic failures (version not found / no applicable
    installer) are deliberately NOT matched - retrying those with user scope
    would only add a second meaningless failure.
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

    if ($ExitCode -in @(
            -2147024891, # 0x80070005 E_ACCESSDENIED
            -1978335150, # 0x8A150052 PORTABLE_INSTALL_FAILED
            -1978335148, # 0x8A150054 PORTABLE_PACKAGE_ALREADY_EXISTS
            -1978335145  # 0x8A150057 PORTABLE_UNINSTALL_FAILED
        )) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace($Output)) { return $false }

    # Access denied (English / Chinese) or an explicit hex code in the text.
    if ($Output -match '(?i)access is denied|拒绝访问|0x80070005') { return $true }
    if ($Output -match '(?i)0x8a150052|0x8a150054|0x8a150057') { return $true }

    # Portable install/uninstall failure rendered as localized prose.
    if ($Output -match '(?i)portable' -and $Output -match '(?i)fail|失败|错误') { return $true }

    return $false
}
