#Requires -Version 5.1
<#
  Register-SyncTasks.ps1 - registers the PakageSync scheduled tasks.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Register-SyncTasks.ps1 -Role A [-ConfigPath <path>]

  -Role A: registers 'PakageSync-Export' - the daily 02:00 A-side export
    (Export-OfflineRepo.ps1). Runs as the current user with LogonType S4U
    (runs whether or not the user is logged on, no password needed) and
    RunLevel Highest (elevated - required for the winget.exe glob under
    C:\Program Files\WindowsApps and for robocopy /MIR on the landing dir).
    Command:
      powershell -NoProfile -ExecutionPolicy Bypass -File <abs>\src\Export-OfflineRepo.ps1 -ConfigPath <abs>\config\packagesync.json

  -Role B: NOT implemented yet - plan todo 17 adds the B-side apply tasks.
    The per-role functions below are the extension point: todo 17 fills in
    Register-OSyncTaskB without restructuring this file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('A', 'B')]
    [string]$Role = 'A',

    [Parameter(Mandatory = $false)]
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\packagesync.json'
}
$ConfigPath = [System.IO.Path]::GetFullPath($ConfigPath)

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
      Placeholder for the B-side apply tasks (plan todo 17). Kept as a
      separate per-role function so todo 17 can implement it without
      restructuring this file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    throw "Register-SyncTasks: -Role B is not implemented yet (plan todo 17 adds the B-side apply tasks)."
}

switch ($Role) {
    'A' { Register-OSyncTaskA -ConfigPath $ConfigPath }
    'B' { Register-OSyncTaskB -ConfigPath $ConfigPath }
}