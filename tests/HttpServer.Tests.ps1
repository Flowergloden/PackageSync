#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 INTEGRATION tests for src\lib\HttpServer.ps1.

.DESCRIPTION
    Starts a real server on a free loopback port, exercises GET / HEAD /
    Range / traversal / method rejection over real sockets, then stops it.
    The module file is dot-sourced directly (this task is parallel with the
    module manifest work - no dependency on the .psd1).

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\HttpServer.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes, so the module is
    dot-sourced and helper functions are defined INSIDE BeforeAll, and data
    shared with the It blocks uses $script: scope.
#>

Describe 'OSync HttpServer integration' {

    BeforeAll {
        # Dot-source the module into this scope.
        . (Join-Path $PSScriptRoot '..\src\lib\HttpServer.ps1')

        # PS 5.1 needs the System.Net.Http assembly loaded explicitly.
        Add-Type -AssemblyName System.Net.Http

        # Discovers a free TCP port by binding to port 0 and releasing it.
        function Get-OsyncFreePort {
            $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $probe.Start()
            $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port
            $probe.Stop()
            return $port
        }

        # Sends a raw HTTP/1.1 request over a TcpClient, returns the status line.
        function Send-OsyncRawRequest {
            param([int]$Port, [string]$RequestText)
            $client = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
            try {
                $stream = $client.GetStream()
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($RequestText)
                $stream.Write($bytes, 0, $bytes.Length)
                $stream.Flush()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII)
                $firstLine = $reader.ReadLine()
                while ($reader.ReadLine() -ne $null) { }   # drain response
                $reader.Dispose()
                return $firstLine
            }
            finally {
                $client.Close()
            }
        }

        # Extracts the integer status code from an HTTP status line.
        function ConvertTo-OsyncStatusCode {
            param([string]$StatusLine)
            if ($StatusLine -match '^HTTP/\d\.\d\s+(\d{3})') {
                return [int]$Matches[1]
            }
            return -1
        }

        $script:port = Get-OsyncFreePort
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-http-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null

        # ~5 MB file filled with cryptographically random bytes.
        $size = 5 * 1024 * 1024
        $random = New-Object byte[] $size
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($random)
        $rng.Dispose()
        [System.IO.File]::WriteAllBytes((Join-Path $script:root 'big.bin'), $random)
        $script:bigSha = (Get-FileHash -Path (Join-Path $script:root 'big.bin') -Algorithm SHA256).Hash
        $script:bigLength = $size
        $script:bigFirst100 = $random[0..99]

        # File whose name contains a space, '#' and '+' - arrives percent-encoded.
        $specialName = 'winget pk g#1+v2.bin'
        $script:specialContent = [System.Text.Encoding]::ASCII.GetBytes('special-content-with space # and + chars!')
        [System.IO.File]::WriteAllBytes((Join-Path $script:root $specialName), $script:specialContent)

        $script:server = Start-OSyncHttpServer -Root $script:root -Bind 127.0.0.1 -Port $script:port
        $script:baseUrl = "http://127.0.0.1:$($script:port)/"
    }

    AfterAll {
        if ($null -ne $script:server) { Stop-OSyncHttpServer -Handle $script:server }
        if ($null -ne $script:root -and (Test-Path -LiteralPath $script:root)) {
            Remove-Item -Recurse -Force -LiteralPath $script:root
        }
    }

    It 'Start returns a handle with listener metadata' {
        $script:server.Port | Should -Be $script:port
        $script:server.Root | Should -Be ([System.IO.Path]::GetFullPath($script:root))
        $script:server.Prefix | Should -Be "http://127.0.0.1:$($script:port)/"
        $script:server.IsStopped | Should -BeFalse
        $script:server.Listener.IsListening | Should -BeTrue
    }

    It 'GET of a ~5MB file returns 200, octet-stream, identical sha256' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $resp = $client.GetAsync($script:baseUrl + 'big.bin').Result
            [int]$resp.StatusCode | Should -Be 200
            $resp.Content.Headers.ContentType.MediaType | Should -Be 'application/octet-stream'
            $resp.Content.Headers.ContentLength | Should -Be $script:bigLength
            $data = $resp.Content.ReadAsByteArrayAsync().Result
            $data.Length | Should -Be $script:bigLength
            $hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($data)) -Algorithm SHA256).Hash
            $hash | Should -Be $script:bigSha
        }
        finally {
            $client.Dispose()
        }
    }

    It 'HEAD returns 200 with correct Content-Length and empty body' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, $script:baseUrl + 'big.bin')
            $resp = $client.SendAsync($req).Result
            [int]$resp.StatusCode | Should -Be 200
            $resp.Content.Headers.ContentLength | Should -Be $script:bigLength
            $data = $resp.Content.ReadAsByteArrayAsync().Result
            $data.Length | Should -Be 0
        }
        finally {
            $client.Dispose()
        }
    }

    It 'Range bytes=0-99 returns 206 with exactly 100 correct bytes' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $script:baseUrl + 'big.bin')
            $req.Headers.Add('Range', 'bytes=0-99')
            $resp = $client.SendAsync($req).Result
            [int]$resp.StatusCode | Should -Be 206
            $resp.Content.Headers.ContentLength | Should -Be 100
            $resp.Content.Headers.ContentRange.From | Should -Be 0
            $resp.Content.Headers.ContentRange.To | Should -Be 99
            $data = $resp.Content.ReadAsByteArrayAsync().Result
            $data.Length | Should -Be 100
            [Convert]::ToBase64String($data) | Should -Be ([Convert]::ToBase64String($script:bigFirst100))
        }
        finally {
            $client.Dispose()
        }
    }

    It 'Range bytes=100- (open-ended) returns 206 with the remaining bytes' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $script:baseUrl + 'big.bin')
            $req.Headers.Add('Range', 'bytes=100-')
            $resp = $client.SendAsync($req).Result
            [int]$resp.StatusCode | Should -Be 206
            $resp.Content.Headers.ContentLength | Should -Be ($script:bigLength - 100)
        }
        finally {
            $client.Dispose()
        }
    }

    It 'Range bytes=-100 (suffix) returns the last 100 bytes' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $script:baseUrl + 'big.bin')
            $req.Headers.Add('Range', 'bytes=-100')
            $resp = $client.SendAsync($req).Result
            [int]$resp.StatusCode | Should -Be 206
            $resp.Content.Headers.ContentLength | Should -Be 100
            $data = $resp.Content.ReadAsByteArrayAsync().Result
            $expected = [System.IO.File]::ReadAllBytes((Join-Path $script:root 'big.bin'))
            $tail = $expected[($expected.Length - 100)..($expected.Length - 1)]
            [Convert]::ToBase64String($data) | Should -Be ([Convert]::ToBase64String($tail))
        }
        finally {
            $client.Dispose()
        }
    }

    It 'Range beyond EOF returns 416' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $script:baseUrl + 'big.bin')
            $req.Headers.Add('Range', 'bytes=99999999-')
            $resp = $client.SendAsync($req).Result
            [int]$resp.StatusCode | Should -Be 416
        }
        finally {
            $client.Dispose()
        }
    }

    It 'dot-segment traversal attempts are rejected (400 guard / 403 HTTP.sys edge)' {
        # Literal and percent-encoded dot segments are rejected by HTTP.sys
        # itself with 403 before HttpListener ever delivers the request to us.
        # Our own guard returns 400 for anything that does reach it. Both are
        # rejections; the file must never be served.
        $requests = @(
            "GET /../secret.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n",
            "GET /%2e%2e%2fsecret.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n",
            "GET /..%5C..%5Csecret.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n",
            "GET /%2e%2e%5csecret.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n",
            "GET /%2e%2e%2f%2e%2e%2fsecret.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
        )
        foreach ($reqText in $requests) {
            $statusLine = Send-OsyncRawRequest -Port $script:port -RequestText $reqText
            ConvertTo-OsyncStatusCode -StatusLine $statusLine | Should -BeIn @(400, 403)
        }
    }

    It 'decoded escape sequences (colon / drive letter) return 400 from the guard' {
        # These forms pass HTTP.sys but decode to paths that escape the root
        # (ADS separator, drive-relative path) - our handler must answer 400.
        $requests = @(
            "GET /%3A%5Cevil.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n",
            "GET /nested%3A..%5Csecret.txt HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n",
            "GET /C:%5CWindows%5Cwin.ini HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n"
        )
        foreach ($reqText in $requests) {
            $statusLine = Send-OsyncRawRequest -Port $script:port -RequestText $reqText
            ConvertTo-OsyncStatusCode -StatusLine $statusLine | Should -Be 400
        }
    }

    It 'non-GET/HEAD methods return 405' {
        foreach ($m in @('POST', 'PUT', 'DELETE')) {
            $reqText = "$m /big.bin HTTP/1.1`r`nHost: 127.0.0.1`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
            $statusLine = Send-OsyncRawRequest -Port $script:port -RequestText $reqText
            ConvertTo-OsyncStatusCode -StatusLine $statusLine | Should -Be 405
        }
    }

    It 'percent-encoded filename containing space, # and + resolves correctly' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $url = $script:baseUrl + 'winget%20pk%20g%231%2Bv2.bin'
            $resp = $client.GetAsync($url).Result
            [int]$resp.StatusCode | Should -Be 200
            $data = $resp.Content.ReadAsByteArrayAsync().Result
            [Convert]::ToBase64String($data) | Should -Be ([Convert]::ToBase64String($script:specialContent))
        }
        finally {
            $client.Dispose()
        }
    }

    It 'missing file returns 404' {
        $client = [System.Net.Http.HttpClient]::new()
        try {
            $resp = $client.GetAsync($script:baseUrl + 'nope.bin').Result
            [int]$resp.StatusCode | Should -Be 404
        }
        finally {
            $client.Dispose()
        }
    }

    It 'Start fails with the port number in the message when the port is already in use' {
        $blocker = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $blocker.Start()
        $busyPort = ([System.Net.IPEndPoint]$blocker.LocalEndpoint).Port
        try {
            { Start-OSyncHttpServer -Root $script:root -Port $busyPort } |
                Should -Throw -ExpectedMessage "*$busyPort*"
        }
        finally {
            $blocker.Stop()
        }
    }

    It 'rejects non-loopback bind addresses' {
        { Start-OSyncHttpServer -Root $script:root -Port 12345 -Bind 0.0.0.0 } | Should -Throw
    }

    It 'rejects a non-existent root directory' {
        { Start-OSyncHttpServer -Root (Join-Path $script:root 'does-not-exist') -Port 12345 } | Should -Throw
    }

    It 'Stop is idempotent and leaves no listener behind' {
        Stop-OSyncHttpServer -Handle $script:server
        Stop-OSyncHttpServer -Handle $script:server
        $script:server.IsStopped | Should -BeTrue
        $script:server.Listener.IsListening | Should -BeFalse

        # A second server can immediately take the same port.
        $again = Start-OSyncHttpServer -Root $script:root -Bind 127.0.0.1 -Port $script:port
        try {
            $again.Listener.IsListening | Should -BeTrue
        }
        finally {
            Stop-OSyncHttpServer -Handle $again
            # Restart the original for any remaining tests; AfterAll stops it.
            $script:server = Start-OSyncHttpServer -Root $script:root -Bind 127.0.0.1 -Port $script:port
        }
    }
}
