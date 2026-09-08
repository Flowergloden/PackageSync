#Requires -Version 5.1
<#
  Logging.ps1 - local logging for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Write-OSyncLog -Category -Level -Message [-Data] -Config [-LogDir]
    writes BOTH a human-readable line (osync-<yyyyMMdd>.log) and a JSONL event
    (osync-<yyyyMMdd>.jsonl) into the log directory. The directory is created
    automatically.

    Log directory resolution (can be overridden with -LogDir):
      role A -> <repoRoot>\logs
      role B -> <stateDir>\run\logs

    Returns the full path of the JSONL file that was appended to.
#>

function Get-OLogDirectory {
    param([Parameter(Mandatory = $true)]$Config)
    if ($Config.role -eq 'B') {
        return (Join-Path (Join-Path $Config.stateDir 'run') 'logs')
    }
    return (Join-Path $Config.repoRoot 'logs')
}

function Write-OSyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        $Data,

        [Parameter(Mandatory = $true)]
        $Config,

        # Optional override (mainly for tests / diagnostics).
        [Parameter(Mandatory = $false)]
        [string]$LogDir
    )

    if (-not [string]::IsNullOrWhiteSpace($LogDir)) {
        $dir = $LogDir
    }
    else {
        $dir = Get-OLogDirectory -Config $Config
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $stamp = [DateTime]::UtcNow

    # Human-readable line: 2026-09-03T06:45:00Z [INFO   ] [category] message
    $lineText = '{0} [{1,-7}] [{2}] {3}' -f $stamp.ToString('yyyy-MM-ddTHH:mm:ssZ'), $Level.ToUpper(), $Category, $Message

    # JSONL event: one JSON object per line, appended.
    $event = [ordered]@{
        time     = $stamp.ToString('o')
        category = $Category
        level    = $Level
        message  = $Message
    }
    if ($null -ne $Data) {
        $event['data'] = $Data
    }
    $jsonLine = ConvertTo-OSyncJson -InputObject $event -Compress

    $day = $stamp.ToString('yyyyMMdd')
    $txtPath = Join-Path $dir ('osync-{0}.log' -f $day)
    $jsonlPath = Join-Path $dir ('osync-{0}.jsonl' -f $day)

    # UTF-8 without BOM on both files; append semantics.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($txtPath, $lineText + [Environment]::NewLine, $utf8)
    [System.IO.File]::AppendAllText($jsonlPath, $jsonLine + [Environment]::NewLine, $utf8)

    # Optional console echo: gives an operator watching a manual run live
    # progress (the log files are the only output otherwise). Opt-in via the
    # in-memory config flag 'consoleEcho' (set by Invoke-OSyncExport unless
    # -Quiet; absent/false = silent, e.g. unattended scheduled tasks on the
    # B side). Write-Host is the HOST stream - it cannot pollute the success
    # pipeline, so the "report object is the only output" contract holds.
    $echo = $false
    if ($null -ne $Config) {
        if ($Config -is [System.Collections.IDictionary]) {
            if ($Config.Contains('consoleEcho')) { $echo = [bool]$Config['consoleEcho'] }
        }
        elseif ($Config.PSObject.Properties['consoleEcho']) {
            $echo = [bool]$Config.consoleEcho
        }
    }
    if ($echo) {
        $color = switch ($Level) {
            'Warning' { 'Yellow' }
            'Error'   { 'Red' }
            'Debug'   { 'DarkGray' }
            default   { 'Gray' }
        }
        Write-Host $lineText -ForegroundColor $color
    }

    return $jsonlPath
}
