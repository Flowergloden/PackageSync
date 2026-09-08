#Requires -Version 5.1
<#
  Util.Tests.ps1 - Pester 5 tests for src\lib\Util.ps1.

  Focus: the bounded retry with backoff in Invoke-OSyncDownload. Production
  hit transient HTTP 503s from the corporate proxy's CONNECT tunnel
  (github.com chezmoi zip, aka.ms/getwinget msixbundle) that cleared minutes
  later: one retry-less Invoke-WebRequest call aborted the whole export
  category on a blip. These tests pin the fix: 3 attempts total (initial + 2
  retries), 5s then 15s backoff, retry on ANY Invoke-WebRequest exception,
  and the ORIGINAL exception rethrown after the final failed attempt so
  callers/error messages are unchanged.

  Util.ps1 is dot-sourced (not module-imported) so Mock Invoke-WebRequest
  intercepts the real call - same pattern as tests\DotfilesExport.Tests.ps1.
  Start-Sleep is mocked to a no-op so the suite is fast; no network is ever
  touched; downloads land in a per-run temp root cleaned in AfterAll.

  Run:
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\Util.Tests.ps1 -PassThru"
    pwsh      -NoProfile -Command "Invoke-Pester tests\Util.Tests.ps1 -PassThru"
#>

Describe 'Invoke-OSyncDownload' {

    BeforeAll {
        # Dot-source the real utility library so the function under test IS the
        # production code; the mocks below land in this same scope and
        # intercept its internal Invoke-WebRequest / Start-Sleep calls.
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')

        # One shared temp root per run; every It writes its own file name.
        $script:UtilRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-util-tests-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:UtilRoot -Force | Out-Null
    }

    BeforeEach {
        # Per-It knob: how many leading Invoke-WebRequest calls must fail.
        $script:FailFirstAttempts = 0
        $script:DownloadAttempt = 0

        # Retry delays must not slow the suite down: sleep becomes a no-op.
        Mock Start-Sleep { }

        # Warnings are asserted for retry count, so route them through a mock
        # (the real function writes them on every retried attempt).
        Mock Write-Warning { }

        # Mock the download: fail the first N calls with the proxy tunnel 503
        # observed in production, then "download" by materializing OutFile
        # exactly like the real cmdlet would (the function under test
        # pre-creates the parent directory before the first attempt).
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            $script:DownloadAttempt++
            if ($script:DownloadAttempt -le $script:FailFirstAttempts) {
                throw 'The proxy tunnel request to proxy http://10.255.243.177:3128 failed with status code 503'
            }
            [System.IO.File]::WriteAllText($OutFile, 'downloaded payload')
        }
    }

    AfterAll {
        if (Test-Path -LiteralPath $script:UtilRoot) {
            Remove-Item -LiteralPath $script:UtilRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'succeeds on the 2nd attempt after one transient failure' {
        $script:FailFirstAttempts = 1
        $outFile = Join-Path $script:UtilRoot 'retry-once.bin'

        $result = Invoke-OSyncDownload -Uri 'https://github.com/twpayne/chezmoi/releases/download/v2.72.0/chezmoi_2.72.0_windows_amd64.zip' -OutFile $outFile

        $result | Should -BeOfType System.IO.FileInfo
        (Get-Content -LiteralPath $outFile -Raw) | Should -Be 'downloaded payload'
        Should -Invoke Invoke-WebRequest -Times 2
        Should -Invoke Start-Sleep -Times 1
        Should -Invoke Write-Warning -Times 1
    }

    It 'succeeds on the first attempt (single call, no retries)' {
        $script:FailFirstAttempts = 0
        $outFile = Join-Path $script:UtilRoot 'first-try.bin'

        $result = Invoke-OSyncDownload -Uri 'https://aka.ms/getwinget' -OutFile $outFile

        $result | Should -BeOfType System.IO.FileInfo
        (Get-Content -LiteralPath $outFile -Raw) | Should -Be 'downloaded payload'
        Should -Invoke Invoke-WebRequest -Times 1
        Should -Invoke Start-Sleep -Times 0
        Should -Invoke Write-Warning -Times 0
    }

    It 'rethrows the original exception after all 3 attempts fail' {
        $script:FailFirstAttempts = 99
        $outFile = Join-Path $script:UtilRoot 'always-fail.bin'

        { Invoke-OSyncDownload -Uri 'https://github.com/example/payload.bin' -OutFile $outFile } |
            Should -Throw -ExpectedMessage '*proxy tunnel*503*'

        Should -Invoke Invoke-WebRequest -Times 3
        Should -Invoke Start-Sleep -Times 2
        Should -Invoke Write-Warning -Times 2
    }
}
