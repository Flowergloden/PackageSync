#Requires -Version 5.1
<#
  Util.ps1 - small shared utilities for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncDownload : TLS 1.2 first, then Invoke-WebRequest -UseBasicParsing.
                        Retry policy: 3 attempts total (initial + 2 retries),
                        5s then 15s backoff, on ANY Invoke-WebRequest exception;
                        original exception rethrown after the final failure.
  Invoke-OSyncRobocopy : robocopy wrapper with fixed /R:3 /W:5; exit <= 7 OK, >= 8 error.
  ConvertTo-OSyncJson  : ConvertTo-Json with -Depth 10 always (PS 5.1 defaults to 2).
#>

function Invoke-OSyncDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$OutFile
    )

    # Enable TLS 1.2 BEFORE any network call (Oracle m3). PS 5.1 defaults the
    # ServicePointManager to TLS 1.0/SSLv3; Tls12 must be OR-ed in so that
    # GitHub/aka.ms/nuget.org downloads work from Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $parent = Split-Path -Parent $OutFile
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Bounded retry with simple backoff: production observed transient HTTP
    # 503s from the corporate proxy's CONNECT tunnel (github.com, aka.ms)
    # that cleared minutes later - one un-retried request aborted the whole
    # export category on a blip. 3 attempts total (initial + 2 retries),
    # 5s then 15s delay, retried on ANY Invoke-WebRequest exception; after
    # the final failed attempt the ORIGINAL exception is rethrown so error
    # messages and caller behavior are unchanged. Warnings go to the warning
    # stream so the output stream still carries ONLY the Get-Item result.
    $retryDelays = @(5, 15)
    $attempt = 1
    while ($true) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
            break
        }
        catch {
            if ($attempt -gt $retryDelays.Count) {
                throw
            }
            Write-Warning ("Invoke-OSyncDownload: attempt {0} of {1} failed downloading '{2}': {3} - retrying in {4}s." -f $attempt, ($retryDelays.Count + 1), $Uri, $_.Exception.Message, $retryDelays[$attempt - 1])
            Start-Sleep -Seconds $retryDelays[$attempt - 1]
            $attempt++
        }
    }

    return (Get-Item -LiteralPath $OutFile)
}

function Invoke-OSyncRobocopy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        # Extra robocopy switches (e.g. /MIR, /E) passed through verbatim.
        [Parameter(Mandatory = $false)]
        [string[]]$ExtraArgs = @()
    )

    # Fixed retry policy /R:3 /W:5: three retries, five seconds apart, so a
    # briefly locked file does not hang an unattended run (Oracle m2/r3-M3).
    $robocopyArgs = @($Source, $Destination, '/R:3', '/W:5') + @($ExtraArgs)
    # Capture the banner instead of letting it pollute the output stream -
    # callers must get ONLY the exit code back; on failure the banner is
    # re-emitted via Write-Warning for diagnostics.
    $robocopyOutput = & robocopy.exe @robocopyArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        foreach ($line in $robocopyOutput) {
            Write-Warning ("[robocopy] {0}" -f $line)
        }
    }

    # robocopy exit codes 0-7 all mean success (0 = nothing to do,
    # 1 = files copied, 2 = extras present, 3 = 1+2, 4 = mismatches, ...);
    # anything >= 8 is a real error.
    if ($exitCode -ge 8) {
        throw "Invoke-OSyncRobocopy: robocopy failed with exit code $exitCode copying '$Source' to '$Destination'."
    }
    return $exitCode
}

function ConvertTo-OSyncJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowNull()]
        $InputObject,

        [Parameter(Mandatory = $false)]
        [switch]$Compress
    )

    # -Depth 10 always: PS 5.1 ConvertTo-Json defaults to depth 2 and silently
    # truncates deeper objects (Oracle m1). All JSON writing in the tool goes
    # through this function.
    if ($null -eq $InputObject) {
        return 'null'
    }
    return (ConvertTo-Json -InputObject $InputObject -Depth 10 -Compress:$Compress)
}
