#Requires -Version 5.1
<#
  Register-SyncTasks.ps1 - registers the PakageSync scheduled tasks.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Register-SyncTasks.ps1 -Role A [-ConfigPath <path>]
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Register-SyncTasks.ps1 -Role B [-ConfigPath <path>] [-PackagesTaskPrincipal SYSTEM|User] [-DotfilesUser <name>]

  -Role A: registers 'PakageSync-Export' - the daily 02:00 A-side export
    (Export-OfflineRepo.ps1). Runs as the current user with LogonType S4U
    (runs whether or not the user is logged on, no password needed) and
    RunLevel Highest (elevated - required for the winget.exe glob under
    C:\Program Files\WindowsApps and for robocopy /MIR on the landing dir).
    Command:
      powershell -NoProfile -ExecutionPolicy Bypass -File <abs>\src\Export-OfflineRepo.ps1 -ConfigPath <abs>\config\packagesync.json

  -Role B (plan todo 17): registers the two B-side apply tasks. Both point
    at the never-renamed micro launcher <stateDir>\bin\launch-apply.ps1
    (placed once by Install-OfflineBootstrap into a SYSTEM/admin-writable,
    Users-RX bin\ - Momus r6-B1), which self-heals the C:\PakageSync
    current/.new/.old family and then runs the real entry script under
    C:\PakageSync\src (Oracle r5-M3). Both tasks use the neutral working
    directory <stateDir>\work.

    'PakageSync-Apply-Packages': SYSTEM (or -PackagesTaskPrincipal User),
    AtStartup + every 4 h, highest privilege, -Category winget,pip,npm.
    The SYSTEM auto bootstrap self-heal path also lives on this task.
    'PakageSync-Apply-Dotfiles': current user (or -DotfilesUser),
    AtLogon + every 4 h, -Category dotfiles (USER-context apply - never
    creates work copies, only consumes the newest .verified generation).

    -PackagesTaskPrincipal User fallback (documented; used when the SYSTEM
    context proves unusable for winget): the principal is the ADMIN account
    performing the registration, LogonType S4U, RunLevel Highest (Oracle m3).

    The 'every 4 h' repetition uses the pinned trigger shape
    (New-ScheduledTaskTrigger -Once -At <start> -RepetitionInterval 4h
    -RepetitionDuration 3650d - PS 5.1 defaults repetition to 1 h when the
    duration is omitted, Oracle m3).

  Requires the bootstrap to have run first: <stateDir>\bin\launch-apply.ps1
  must exist (the tasks point at it) and the config's stateDir must resolve.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('A', 'B')]
    [string]$Role = 'A',

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [ValidateSet('SYSTEM', 'User')]
    [string]$PackagesTaskPrincipal = 'SYSTEM',

    # Explicit dotfiles-task user. Defaults to the account performing the
    # registration; when B's daily user is NOT an administrator this must be
    # specified explicitly (single-user premise, Oracle m7).
    [Parameter(Mandatory = $false)]
    [string]$DotfilesUser
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $scriptDir 'OfflineSync.psd1') -Force

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

# ---- shared B-side helpers --------------------------------------------------

function New-OSyncFourHourlyTrigger {
    # The pinned 'every 4 h' trigger shape (Oracle m3): a Once trigger at the
    # given start with a 4-hour repetition for 3650 days. PS 5.1 would
    # otherwise default the repetition window to 1 hour.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [datetime]$At = (Get-Date).Date
    )
    return (New-ScheduledTaskTrigger -Once -At $At -RepetitionInterval (New-TimeSpan -Hours 4) -RepetitionDuration (New-TimeSpan -Days 3650))
}

function Get-OSyncApplyLauncherPath {
    # <stateDir>\bin\launch-apply.ps1 - the never-renamed micro launcher the
    # B tasks point at (Momus r6-B1). Throws when it is missing so the
    # operator knows to run Install-OfflineBootstrap first.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir)
    $launcher = Join-Path (Join-Path $StateDir 'bin') 'launch-apply.ps1'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
        throw "Register-SyncTasks -Role B: the micro launcher was not found at '$launcher'. Run Install-OfflineBootstrap.ps1 first (it places the launcher and lands the tool copy at C:\PakageSync)."
    }
    return $launcher
}

function Register-OSyncTaskA {
    <#
      Registers 'PakageSync-Export': daily 02:00, current user, LogonType
      S4U, RunLevel Highest, StartWhenAvailable (a missed 02:00 run - e.g.
      the machine was off - is executed at the next opportunity).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $exportScript = Join-Path $scriptDir 'Export-OfflineRepo.ps1'
    if (-not (Test-Path -LiteralPath $exportScript -PathType Leaf)) {
        throw "Register-SyncTasks: export script not found: '$exportScript'."
    }
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Register-SyncTasks: config file not found: '$ConfigPath'."
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $exportScript, $ConfigPath)
    $trigger = New-ScheduledTaskTrigger -Daily -At '02:00'
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew

    Register-ScheduledTask -TaskName 'PakageSync-Export' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

    $task = Get-ScheduledTask -TaskName 'PakageSync-Export'
    Write-Host "Registered scheduled task 'PakageSync-Export':"
    Write-Host "  State:     $($task.State)"
    Write-Host "  Trigger:   $($task.Triggers[0].StartBoundary) (daily)"
    Write-Host "  Principal: $($task.Principal.UserId) / $($task.Principal.LogonType) / $($task.Principal.RunLevel)"
    Write-Host "  Action:    $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
    return $task
}

function Register-OSyncTaskB {
    <#
      Registers the two B-side apply tasks (plan todo 17). Both point at the
      micro launcher <stateDir>\bin\launch-apply.ps1, which resolves
      C:\PakageSync (self-healing the current/.new/.old family) and runs the
      real entry script C:\PakageSync\src\Invoke-OfflineApply.ps1 with the
      given -Category and -ConfigPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [ValidateSet('SYSTEM', 'User')]
        [string]$PackagesTaskPrincipal = 'SYSTEM',

        [Parameter(Mandatory = $false)]
        [string]$DotfilesUser
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Register-SyncTasks: config file not found: '$ConfigPath'."
    }
    $config = Get-OSyncConfig -Path $ConfigPath
    if ($config.role -ne 'B') {
        throw "Register-SyncTasks -Role B: config role must be 'B' (got '$($config.role)') - pass a B-side config."
    }
    $stateDir = [string]$config.stateDir
    if ([string]::IsNullOrWhiteSpace($stateDir)) {
        throw 'Register-SyncTasks -Role B: config.stateDir is empty.'
    }
    $launcher = Get-OSyncApplyLauncherPath -StateDir $stateDir

    $workDir = Join-Path $stateDir 'work'
    if (-not (Test-Path -LiteralPath $workDir -PathType Container)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew

    # --- PakageSync-Apply-Packages (SYSTEM or User fallback) ----------------
    # The launcher's -ScriptArgs is ValueFromRemainingArguments: the args are
    # passed UNNAMED after -ScriptRel so they bind as separate tokens (naming
    # -ScriptArgs makes PowerShell merge the comma-list into one token).
    $packagesAction = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $workDir -Argument (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScriptRel "Invoke-OfflineApply.ps1" "-ConfigPath" "{1}" "-Category" "winget,pip,npm"' -f $launcher, $ConfigPath)
    $packagesTriggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-OSyncFourHourlyTrigger)
    )
    if ($PackagesTaskPrincipal -eq 'SYSTEM') {
        $packagesPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    }
    else {
        # Fallback (Oracle m3): the ADMIN account performing the registration,
        # S4U (runs whether or not the admin is logged on), RunLevel Highest.
        $packagesPrincipal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
    }
    Register-ScheduledTask -TaskName 'PakageSync-Apply-Packages' -Action $packagesAction -Trigger $packagesTriggers -Principal $packagesPrincipal -Settings $settings -Force | Out-Null

    # --- PakageSync-Apply-Dotfiles (current user / -DotfilesUser) -----------
    if ([string]::IsNullOrWhiteSpace($DotfilesUser)) {
        $DotfilesUser = "$env:USERDOMAIN\$env:USERNAME"
    }
    $dotfilesAction = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $workDir -Argument (
        '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ScriptRel "Invoke-OfflineApply.ps1" "-ConfigPath" "{1}" "-Category" "dotfiles"' -f $launcher, $ConfigPath)
    $dotfilesTriggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $DotfilesUser),
        (New-OSyncFourHourlyTrigger)
    )
    $dotfilesPrincipal = New-ScheduledTaskPrincipal -UserId $DotfilesUser -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName 'PakageSync-Apply-Dotfiles' -Action $dotfilesAction -Trigger $dotfilesTriggers -Principal $dotfilesPrincipal -Settings $settings -Force | Out-Null

    # --- report --------------------------------------------------------------
    foreach ($taskName in @('PakageSync-Apply-Packages', 'PakageSync-Apply-Dotfiles')) {
        $task = Get-ScheduledTask -TaskName $taskName
        Write-Host "Registered scheduled task '$taskName':"
        Write-Host "  State:     $($task.State)"
        Write-Host "  Principal: $($task.Principal.UserId) / $($task.Principal.LogonType) / $($task.Principal.RunLevel)"
        Write-Host "  WorkingDir: $($task.Actions[0].WorkingDirectory)"
        Write-Host "  Action:    $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
        Write-Host "  Triggers:  $($task.Triggers.Count)"
    }
    return $null
}

switch ($Role) {
    'A' { Register-OSyncTaskA -ConfigPath $ConfigPath }
    'B' { Register-OSyncTaskB -ConfigPath $ConfigPath -PackagesTaskPrincipal $PackagesTaskPrincipal -DotfilesUser $DotfilesUser }
}
