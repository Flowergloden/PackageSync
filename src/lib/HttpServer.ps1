#Requires -Version 5.1
<#
.SYNOPSIS
    Self-contained static file HTTP server for the B side of the one-way
    package sync. Serves files from a single root directory on the loopback
    interface only.

.DESCRIPTION
    Uses System.Net.HttpListener (HTTP.sys) behind a background runspace.

    Supported behaviour (winget/curl downloader compatible):
      - GET / HEAD only, anything else -> 405 (with Allow header)
      - single-interval Range: bytes=start-end | bytes=start- | bytes=-N
        -> 206 with correct Content-Range; unparseable/multi-range/
        unsatisfiable -> 416 with Content-Range: bytes */<length>
      - Content-Type is always application/octet-stream
      - URL handling: the RAW request path is percent-decoded FIRST, then
        normalized segment-by-segment ('.'/'..', both '/' and '\' as
        separators). The resolved path MUST stay under Root, otherwise 400.
        This supports filenames containing spaces, '#' and '+' (they arrive
        percent-encoded from winget download URLs).
      - large files are streamed in 64 KB chunks (no whole-file load)

.NOTES
    - Never bind to 0.0.0.0. The -Bind parameter is validated to loopback
      addresses only.
    - Self-contained: no dependency on other src\lib modules (this task runs
      in parallel with the module manifest / Util / Logging work).
    - PS 5.1 compatible: plain [runspacefactory] + [powershell] API,
      NOT Start-ThreadJob.
#>

# Capture this file's own path at dot-source time so the background runspace
# can dot-source the same file and share the request-handling functions.
$script:OSyncHttpModulePath = $MyInvocation.MyCommand.Path

<#
.SYNOPSIS
    Starts the static file server in a background runspace and returns a
    handle object used later by Stop-OSyncHttpServer.
.PARAMETER Root
    Directory to serve. Must exist.
.PARAMETER Bind
    Loopback address to bind. Only 127.0.0.1 / localhost / ::1 are allowed.
.PARAMETER Port
    TCP port. If the port is already in use the function throws an error
    whose message contains the port number.
#>
function Start-OSyncHttpServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Root,

        [Parameter(Mandatory = $false)]
        [ValidateSet('127.0.0.1', 'localhost', '::1')]
        [string]$Bind = '127.0.0.1',

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root)
    if (-not [System.IO.Directory]::Exists($fullRoot)) {
        throw "OSync HTTP server root directory does not exist: $fullRoot"
    }

    # IPv6 literals must be wrapped in brackets inside the URL prefix.
    $hostPart = $Bind
    if ($hostPart.Contains(':') -and -not $hostPart.StartsWith('[')) {
        $hostPart = "[$hostPart]"
    }
    $prefix = "http://${hostPart}:${Port}/"

    # The listener is created and started in the CALLER runspace so that
    # "port already in use" surfaces synchronously as a plain error here.
    $listener = New-Object System.Net.HttpListener
    $listener.IgnoreWriteExceptions = $true
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    }
    catch {
        try { $listener.Close() } catch { }
        # Use the innermost exception message (stable English text from the
        # framework, no localized PowerShell wrapper noise).
        $reason = $_.Exception
        while ($null -ne $reason.InnerException) { $reason = $reason.InnerException }
        throw "Cannot start OSync HTTP server on port $Port ($prefix): $($reason.Message)"
    }

    # Background runspace runs the accept loop. Plain Runspace API (PS 5.1
    # compatible). The loop dot-sources this very file so the request
    # handling functions are shared - single source of truth.
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Name = "OSyncHttpServer-$Port"
    $runspace.Open()

    $serverScript = {
        param($pListener, $pRoot, $pModulePath)
        . $pModulePath
        Invoke-OSyncHttpLoop -Listener $pListener -Root $pRoot
    }

    $powerShell = [powershell]::Create()
    $powerShell.Runspace = $runspace
    $null = $powerShell.AddScript($serverScript.ToString())
    $null = $powerShell.AddArgument($listener)
    $null = $powerShell.AddArgument($fullRoot)
    $null = $powerShell.AddArgument($script:OSyncHttpModulePath)
    $async = $powerShell.BeginInvoke()

    return [pscustomobject]@{
        PSTypeName = 'OSync.HttpServerHandle'
        Listener   = $listener
        Runspace   = $runspace
        PowerShell = $powerShell
        Async      = $async
        Root       = $fullRoot
        Bind       = $Bind
        Port       = $Port
        Prefix     = $prefix
        IsStopped  = $false
    }
}

<#
.SYNOPSIS
    Stops a server started by Start-OSyncHttpServer. Idempotent.
#>
function Stop-OSyncHttpServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object]$Handle
    )

    if ($null -eq $Handle -or $Handle.IsStopped) { return }
    $Handle.IsStopped = $true

    # Stop() unblocks GetContext() in the background runspace.
    if ($null -ne $Handle.Listener) {
        try { if ($Handle.Listener.IsListening) { $Handle.Listener.Stop() } } catch { }
        try { $Handle.Listener.Close() } catch { }
    }

    if ($null -ne $Handle.PowerShell) {
        # Give the accept loop up to 10 seconds to notice and exit.
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ($Handle.PowerShell.InvocationStateInfo.State -eq 'Running' -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 50
        }
        try {
            if ($Handle.PowerShell.InvocationStateInfo.State -eq 'Running') {
                $Handle.PowerShell.Stop()
            }
        }
        catch { }
        try { $null = $Handle.PowerShell.EndInvoke($Handle.Async) } catch { }
        try { $Handle.PowerShell.Dispose() } catch { }
    }

    if ($null -ne $Handle.Runspace) {
        try { $Handle.Runspace.Dispose() } catch { }
    }
}

<#
.SYNOPSIS
    Accept loop executed inside the background runspace. Never call directly.
#>
function Invoke-OSyncHttpLoop {
    param(
        [System.Net.HttpListener]$Listener,
        [string]$Root
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root)

    while ($true) {
        $context = $null
        $method = 'GET'
        try {
            $context = $Listener.GetContext()
        }
        catch {
            # Listener was stopped/closed -> clean exit.
            break
        }

        $response = $context.Response
        try {
            $method = $context.Request.HttpMethod
            if ([string]::IsNullOrEmpty($method)) { $method = 'GET' }
            $method = $method.ToUpperInvariant()

            if ($method -ne 'GET' -and $method -ne 'HEAD') {
                Send-OSyncErrorResponse -Response $response -Status 405 -Method $method -AllowHeader $true
                continue
            }

            $resolved = Resolve-OSyncRequestPath -RawUrl $context.Request.RawUrl -Root $fullRoot
            if ($resolved.Status -eq 'badpath') {
                Send-OSyncErrorResponse -Response $response -Status 400 -Method $method
                continue
            }
            if ($resolved.Status -eq 'notfound') {
                Send-OSyncErrorResponse -Response $response -Status 404 -Method $method
                continue
            }

            Send-OSyncFileResponse -Response $response -FullPath $resolved.FullPath -Method $method -RangeHeader $context.Request.Headers['Range']
        }
        catch {
            # Best-effort 500; the client may already be gone.
            try { Send-OSyncErrorResponse -Response $response -Status 500 -Method $method } catch { }
        }
        finally {
            try { $response.Close() } catch { }
        }
    }
}

<#
.SYNOPSIS
    Maps a raw request path to a file under Root.

.DESCRIPTION
    Percent-decode FIRST, then normalize:
      1. strip query string
      2. Uri.UnescapeDataString (handles %20 space, %23 '#', %2B '+', %2E '.')
      3. split into segments on both '/' and '\'
      4. drop '.' segments; '..' pops the last safe segment (400 if it would
         escape above the root); reject segments containing ':' or NUL
      5. Join + GetFullPath + case-insensitive containment check under Root

    Returns a hashtable:
      Status 'ok'        -> FullPath points at an existing file
      Status 'notfound'  -> safe path but the file does not exist (404)
      Status 'badpath'   -> traversal / malformed (400)
#>
function Resolve-OSyncRequestPath {
    param(
        [string]$RawUrl,
        [string]$Root
    )

    try {
        $path = $RawUrl
        $qIdx = $path.IndexOf('?')
        if ($qIdx -ge 0) { $path = $path.Substring(0, $qIdx) }

        # Percent-decode FIRST (before any normalization).
        $decoded = [System.Uri]::UnescapeDataString($path)
        if ([string]::IsNullOrEmpty($decoded) -or -not $decoded.StartsWith('/')) {
            return @{ Status = 'badpath'; FullPath = $null }
        }

        $segments = $decoded -split '[\\/]'
        $safe = New-Object System.Collections.Generic.List[string]
        foreach ($seg in $segments) {
            if ($seg -eq '' -or $seg -eq '.') { continue }
            if ($seg -eq '..') {
                if ($safe.Count -eq 0) {
                    # '..' would escape above the root.
                    return @{ Status = 'badpath'; FullPath = $null }
                }
                $safe.RemoveAt($safe.Count - 1)
                continue
            }
            # ':' enables alternate data streams / drive-relative tricks,
            # NUL breaks the filesystem APIs. Neither appears in winget URLs.
            if ($seg.Contains(':') -or $seg.Contains([char]0)) {
                return @{ Status = 'badpath'; FullPath = $null }
            }
            $safe.Add($seg)
        }

        if ($safe.Count -eq 0) {
            return @{ Status = 'notfound'; FullPath = $null }
        }

        $rel = [string]::Join([System.IO.Path]::DirectorySeparatorChar, $safe)
        $full = [System.IO.Path]::GetFullPath((Join-Path $Root $rel))

        # Belt-and-braces containment check (Windows paths are
        # case-insensitive).
        $rootPrefix = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
        if (-not $full.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return @{ Status = 'badpath'; FullPath = $null }
        }

        if ([System.IO.File]::Exists($full)) {
            return @{ Status = 'ok'; FullPath = $full }
        }
        return @{ Status = 'notfound'; FullPath = $full }
    }
    catch {
        return @{ Status = 'badpath'; FullPath = $null }
    }
}

<#
.SYNOPSIS
    Parses a Range header against a known file length.

.DESCRIPTION
    Returns:
      $null                          -> no Range header (full 200 response)
      @{Start=;End=}                 -> satisfiable interval (206)
      @{Unsatisfiable=$true}         -> 416 (also for multi-range / garbage)
    Supports single intervals only: bytes=a-b, bytes=a-, bytes=-N.
#>
function Get-OSyncHttpRange {
    param(
        [string]$RangeHeader,
        [long]$Length
    )

    if ([string]::IsNullOrWhiteSpace($RangeHeader)) { return $null }

    $re = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

    # bytes=start-end | bytes=start-
    $m = [regex]::Match($RangeHeader, '^\s*bytes\s*=\s*(\d+)\s*-\s*(\d*)\s*$', $re)
    if ($m.Success) {
        $start = [long]$m.Groups[1].Value
        $endStr = $m.Groups[2].Value
        if ($Length -eq 0 -or $start -ge $Length) {
            return @{ Unsatisfiable = $true }
        }
        $end = $Length - 1
        if ($endStr -ne '') {
            $end = [Math]::Min([long]$endStr, $Length - 1)
        }
        if ($start -gt $end) {
            return @{ Unsatisfiable = $true }
        }
        return @{ Start = $start; End = $end }
    }

    # Suffix range bytes=-N (last N bytes). Common with download resumers.
    $m = [regex]::Match($RangeHeader, '^\s*bytes\s*=\s*-\s*(\d+)\s*$', $re)
    if ($m.Success) {
        $n = [long]$m.Groups[1].Value
        if ($Length -eq 0 -or $n -le 0) {
            return @{ Unsatisfiable = $true }
        }
        return @{ Start = [Math]::Max([long]0, $Length - $n); End = $Length - 1 }
    }

    # Multi-range or malformed -> reject (416).
    return @{ Unsatisfiable = $true }
}

<#
.SYNOPSIS
    Streams a file (or a range of it) into the response. HEAD sends headers
    only. Content-Type is always application/octet-stream.
#>
function Send-OSyncFileResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [string]$FullPath,
        [string]$Method,
        [string]$RangeHeader
    )

    $fileInfo = New-Object System.IO.FileInfo($FullPath)
    $length = $fileInfo.Length

    $Response.ContentType = 'application/octet-stream'
    $Response.Headers.Add('Accept-Ranges', 'bytes')

    $range = Get-OSyncHttpRange -RangeHeader $RangeHeader -Length $length

    if ($null -ne $range -and $range.ContainsKey('Unsatisfiable') -and $range.Unsatisfiable) {
        # 416: RFC 7233 requires a Content-Range header in this case.
        $Response.StatusCode = 416
        $Response.Headers.Add('Content-Range', "bytes */$length")
        $body = [System.Text.Encoding]::ASCII.GetBytes('Range not satisfiable')
        $Response.ContentLength64 = $body.Length
        if ($Method -ne 'HEAD') {
            $Response.OutputStream.Write($body, 0, $body.Length)
            $Response.OutputStream.Flush()
        }
        return
    }

    $start = [long]0
    $end = $length - 1
    if ($null -ne $range) {
        $Response.StatusCode = 206
        $Response.Headers.Add('Content-Range', "bytes $($range.Start)-$($range.End)/$length")
        $start = [long]$range.Start
        $end = [long]$range.End
    }
    else {
        $Response.StatusCode = 200
    }

    $count = $end - $start + 1
    if ($length -eq 0) { $count = 0 }
    $Response.ContentLength64 = $count

    # HEAD: advertise the length but send no body (HTTP.sys strips the body).
    if ($Method -eq 'HEAD') { return }

    # Stream the file (or slice) in chunks - no whole-file memory load.
    $stream = [System.IO.File]::Open(
        $FullPath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read)
    try {
        if ($start -gt 0) {
            $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
        }
        $buffer = New-Object byte[] 65536
        $remaining = $count
        while ($remaining -gt 0) {
            $toRead = [int][Math]::Min($remaining, [long]65536)
            $read = $stream.Read($buffer, 0, $toRead)
            if ($read -le 0) { break }
            $Response.OutputStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $Response.OutputStream.Flush()
    }
    finally {
        $stream.Dispose()
    }
}

<#
.SYNOPSIS
    Writes a minimal error response (400/404/405/416/500). Optional Allow
    header for 405. Content-Type stays application/octet-stream.
#>
function Send-OSyncErrorResponse {
    param(
        [System.Net.HttpListenerResponse]$Response,
        [int]$Status,
        [string]$Method = 'GET',
        [switch]$AllowHeader
    )

    if ($AllowHeader) {
        $Response.Headers.Add('Allow', 'GET, HEAD')
    }
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/octet-stream'

    $message = "Error $Status"
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($message)
    $Response.ContentLength64 = $bytes.Length
    if ($Method -ne 'HEAD') {
        $Response.OutputStream.Write($bytes, 0, $bytes.Length)
        $Response.OutputStream.Flush()
    }
}
