#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\DotfilesExport.ps1 - the A-side dotfiles
    source-state export + chezmoi.exe payload.

.DESCRIPTION
    The download is MOCKED (Mock Invoke-OSyncDownload) - unit tests never hit
    the network; the real download happens once in the QA evidence run.
    Everything runs under $TestDrive; the real config/manifests are never
    touched.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\DotfilesExport.Tests.ps1 -PassThru"
      pwsh      -NoProfile -Command "Invoke-Pester tests\DotfilesExport.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files are
    dot-sourced and helper functions are defined INSIDE BeforeAll; data shared
    with the It blocks uses $script: scope (same pattern as the other test
    files in this plan). The download mock is defined in BeforeEach so every
    It gets a fresh invocation history for Should -Invoke -Times assertions.
#>

Describe 'DotfilesExport' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')

        # --- fake chezmoi release zip (a real zip containing chezmoi.exe) ---
        $script:FakeExeDir = Join-Path $TestDrive 'fakeexe'
        New-Item -ItemType Directory -Path $script:FakeExeDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeExeDir 'chezmoi.exe') -Value 'fake chezmoi binary payload' -Encoding ASCII
        $script:FakeZip = Join-Path $TestDrive 'fake-chezmoi.zip'
        Compress-Archive -Path (Join-Path $script:FakeExeDir '*') -DestinationPath $script:FakeZip -Force
        $script:FakeZipHash = Get-OSyncFileSha256 -Path $script:FakeZip

        # --- test repo with a dotfiles source state (paths.* are repo-root-relative) ---
        $script:RepoRoot = Join-Path $TestDrive 'repo'
        $script:DotfilesSource = Join-Path $script:RepoRoot 'manifests\dotfiles'
        New-Item -ItemType Directory -Path $script:DotfilesSource -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:DotfilesSource 'dot_testfile.txt') -Value 'hello from the dotfiles fixture' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:DotfilesSource 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:DotfilesSource 'sub\nested.txt') -Value 'nested content' -Encoding UTF8

        # Minimal valid config shape consumed by Export-OSyncDotfiles
        # (Get-OSyncConfig validation is todo-11 territory).
        function New-OTestConfig {
            param(
                [string]$RepoRoot = $script:RepoRoot,
                [string]$SourceDir = 'manifests\dotfiles',
                [string]$Sha256 = $script:FakeZipHash
            )
            return [pscustomobject]@{
                role     = 'A'
                repoRoot = $RepoRoot
                stateDir = Join-Path $RepoRoot 'state'
                paths    = [pscustomobject]@{ dotfilesSource = $SourceDir }
                pins     = [pscustomobject]@{
                    chezmoi = [pscustomobject]@{
                        version = '2.72.0'
                        url     = 'https://github.com/twpayne/chezmoi/releases/download/v2.72.0/chezmoi_2.72.0_windows_amd64.zip'
                        sha256  = $Sha256
                    }
                }
            }
        }

        # Recursive relative-path -> sha256 map for comparing two trees.
        function Get-OTestTreeHashes {
            param([string]$Dir)
            $map = [ordered]@{}
            Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object {
                $rel = $_.FullName.Substring($Dir.Length).TrimStart('\')
                $map[$rel] = Get-OSyncFileSha256 -Path $_.FullName
            }
            return $map
        }

        # Captures a throwing call: returns the ErrorRecord or $null.
        function Invoke-OTestThrowing {
            param([scriptblock]$ScriptBlock)
            $caught = $null
            try { & $ScriptBlock }
            catch { $caught = $_ }
            return $caught
        }
    }

    BeforeEach {
        # Fresh mock per test: copies the pre-built fake zip to the requested
        # OutFile, exactly like a real download would (parent dir creation
        # included - the real Invoke-OSyncDownload creates it too).
        Mock Invoke-OSyncDownload {
            $parent = Split-Path -Parent $OutFile
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            Copy-Item -LiteralPath $script:FakeZip -Destination $OutFile -Force
        }
    }

    Context 'Assert-OSyncDotfilesSource - source state validation' {
        It 'accepts a plain source state' {
            Assert-OSyncDotfilesSource -SourceDir $script:DotfilesSource | Should -BeTrue
        }

        It 'throws for a missing directory' {
            $err = Invoke-OTestThrowing { Assert-OSyncDotfilesSource -SourceDir (Join-Path $TestDrive 'nope') }
            $err.Exception.Message | Should -Match 'not found'
        }

        It 'rejects a root-level .chezmoiexternal.toml naming the file' {
            $dir = Join-Path $TestDrive 'ext-root'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir '.chezmoiexternal.toml') -Value 'x' -Encoding ASCII
            $err = Invoke-OTestThrowing { Assert-OSyncDotfilesSource -SourceDir $dir }
            $err.Exception.Message | Should -Match 'offline does not support externals'
            $err.Exception.Message | Should -Match '\.chezmoiexternal\.toml'
        }

        It 'rejects a NESTED .chezmoiexternal.json naming the file' {
            $dir = Join-Path $TestDrive 'ext-nested'
            New-Item -ItemType Directory -Path (Join-Path $dir 'deep\deeper') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'deep\deeper\.chezmoiexternal.json') -Value '{}' -Encoding ASCII
            $err = Invoke-OTestThrowing { Assert-OSyncDotfilesSource -SourceDir $dir }
            $err.Exception.Message | Should -Match 'offline does not support externals'
            $err.Exception.Message | Should -Match '\.chezmoiexternal\.json'
        }

        It 'rejects a bare .chezmoiexternal file (no extension)' {
            $dir = Join-Path $TestDrive 'ext-bare'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir '.chezmoiexternal') -Value 'x' -Encoding ASCII
            $err = Invoke-OTestThrowing { Assert-OSyncDotfilesSource -SourceDir $dir }
            $err.Exception.Message | Should -Match 'offline does not support externals'
        }

        It 'accepts a file named chezmoiexternal.toml WITHOUT the leading dot' {
            $dir = Join-Path $TestDrive 'ext-nodot'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'chezmoiexternal.toml') -Value 'x' -Encoding ASCII
            Assert-OSyncDotfilesSource -SourceDir $dir | Should -BeTrue
        }
    }

    Context 'Get-OSyncChezmoiTomlContent - generated template' {
        It 'contains an empty [data] section and commented examples' {
            $content = Get-OSyncChezmoiTomlContent
            $content | Should -Match '\[data\]'
            $content | Should -Match 'name = "user"'
            $content | Should -Match 'email = "user@example.com"'
        }

        It 'never enables the symlink feature' {
            (Get-OSyncChezmoiTomlContent) | Should -Not -Match '(?i)symlink'
        }
    }

    Context 'Get-OSyncFileSha256' {
        It 'computes the known sha256 of a small file' {
            $f = Join-Path $TestDrive 'abc.txt'
            Set-Content -LiteralPath $f -Value 'abc' -NoNewline -Encoding ASCII
            Get-OSyncFileSha256 -Path $f | Should -Be 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
        }

        It 'throws for a missing file' {
            $err = Invoke-OTestThrowing { Get-OSyncFileSha256 -Path (Join-Path $TestDrive 'missing.bin') }
            $err.Exception.Message | Should -Match 'not found'
        }
    }

    Context 'Expand-OSyncChezmoiZip' {
        It 'extracts chezmoi.exe from the zip' {
            $dest = Join-Path $TestDrive 'extract-ok'
            $target = Expand-OSyncChezmoiZip -ZipPath $script:FakeZip -Destination $dest
            Test-Path -LiteralPath $target -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $target -Raw) | Should -Be (Get-Content -LiteralPath (Join-Path $script:FakeExeDir 'chezmoi.exe') -Raw)
        }

        It 'throws when the zip has no chezmoi.exe entry' {
            $dir = Join-Path $TestDrive 'noexe-dir'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $dir 'readme.txt') -Value 'hi' -Encoding ASCII
            $zip = Join-Path $TestDrive 'noexe.zip'
            Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zip -Force
            $err = Invoke-OTestThrowing { Expand-OSyncChezmoiZip -ZipPath $zip -Destination (Join-Path $TestDrive 'extract-bad') }
            $err.Exception.Message | Should -Match 'chezmoi\.exe'
        }
    }

    Context 'Export-OSyncDotfiles - happy path (mocked download)' {
        It 'exports the source state identical and lands chezmoi.exe on hash match' {
            $staging = Join-Path $TestDrive 'staging-happy'
            $report = Export-OSyncDotfiles -Config (New-OTestConfig) -StagingDir $staging

            $report.status | Should -Be 'ok'
            $report.category | Should -Be 'dotfiles'
            $report.chezmoi.sha256 | Should -Be $script:FakeZipHash

            # source state exported byte-identical (recursive)
            $src = Get-OTestTreeHashes -Dir $script:DotfilesSource
            $dst = Get-OTestTreeHashes -Dir (Join-Path $staging 'dotfiles\source')
            $src.Count | Should -Be $dst.Count
            foreach ($k in $src.Keys) {
                $dst[$k] | Should -Be $src[$k]
            }

            # chezmoi.toml generated (fixture has no manifests\dotfiles.toml)
            Test-Path -LiteralPath (Join-Path $staging 'dotfiles\chezmoi.toml') | Should -BeTrue

            # chezmoi.exe landed at runtime\chezmoi\chezmoi.exe
            $exe = Join-Path $staging 'runtime\chezmoi\chezmoi.exe'
            Test-Path -LiteralPath $exe -PathType Leaf | Should -BeTrue
            (Get-Content -LiteralPath $exe -Raw) | Should -Be (Get-Content -LiteralPath (Join-Path $script:FakeExeDir 'chezmoi.exe') -Raw)
            $report.chezmoi.exePath | Should -Be $exe
        }

        It 'downloads the zip when it is missing from staging' {
            $staging = Join-Path $TestDrive 'staging-dl'
            $null = Export-OSyncDotfiles -Config (New-OTestConfig) -StagingDir $staging
            Should -Invoke Invoke-OSyncDownload -Times 1 -Exactly
        }

        It 'reuses an existing zip - no second download' {
            $staging = Join-Path $TestDrive 'staging-reuse'
            $null = Export-OSyncDotfiles -Config (New-OTestConfig) -StagingDir $staging
            # If the second run tried to download, this mock throws and the
            # test fails - behavior-based proof of the reuse path.
            Mock Invoke-OSyncDownload { throw 'Invoke-OSyncDownload must not be called again' }
            $report = Export-OSyncDotfiles -Config (New-OTestConfig) -StagingDir $staging
            $report.status | Should -Be 'ok'
        }

        It 'copies manifests\dotfiles.toml when present (byte-identical)' {
            $repo = Join-Path $TestDrive 'repo-toml'
            New-Item -ItemType Directory -Path (Join-Path $repo 'manifests\dotfiles') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $repo 'manifests\dotfiles\dot_testfile.txt') -Value 'x' -Encoding UTF8
            $toml = Join-Path $repo 'manifests\dotfiles.toml'
            Set-Content -LiteralPath $toml -Value @('[data]', 'name = "fixture"') -Encoding UTF8

            $staging = Join-Path $TestDrive 'staging-toml'
            $null = Export-OSyncDotfiles -Config (New-OTestConfig -RepoRoot $repo) -StagingDir $staging

            $copied = Join-Path $staging 'dotfiles\chezmoi.toml'
            Test-Path -LiteralPath $copied | Should -BeTrue
            (Get-Content -LiteralPath $copied -Raw) | Should -Be (Get-Content -LiteralPath $toml -Raw)
        }

        It 'returns a SINGLE report object - no leaked log paths in the pipeline' {
            $staging = Join-Path $TestDrive 'staging-leak'
            $report = Export-OSyncDotfiles -Config (New-OTestConfig) -StagingDir $staging
            $report -is [System.Array] | Should -BeFalse
            $report.GetType().Name | Should -Be 'PSCustomObject'
            @($report).Count | Should -Be 1
            @($report | Where-Object { $_ -is [string] }).Count | Should -Be 0
        }
    }

    Context 'Export-OSyncDotfiles - hash gate paths' {
        It 'PIN-ME prints the actual hash and exits non-zero (no exe extracted)' {
            $staging = Join-Path $TestDrive 'staging-pinme'
            $err = Invoke-OTestThrowing { Export-OSyncDotfiles -Config (New-OTestConfig -Sha256 'PIN-ME') -StagingDir $staging }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -Match 'PIN-ME'
            $err.Exception.Message | Should -Match $script:FakeZipHash
            Test-Path -LiteralPath (Join-Path $staging 'runtime\chezmoi\chezmoi.exe') | Should -BeFalse
        }

        It 'mismatched hash aborts naming expected AND actual (no exe extracted)' {
            $staging = Join-Path $TestDrive 'staging-mismatch'
            $wrong = ('a' * 64)
            $err = Invoke-OTestThrowing { Export-OSyncDotfiles -Config (New-OTestConfig -Sha256 $wrong) -StagingDir $staging }
            $err | Should -Not -BeNullOrEmpty
            $err.Exception.Message | Should -Match 'mismatch'
            $err.Exception.Message | Should -Match $wrong
            $err.Exception.Message | Should -Match $script:FakeZipHash
            Test-Path -LiteralPath (Join-Path $staging 'runtime\chezmoi\chezmoi.exe') | Should -BeFalse
        }
    }

    Context 'Export-OSyncDotfiles - source validation failures' {
        It 'fails when the source directory is missing' {
            $staging = Join-Path $TestDrive 'staging-missing'
            $err = Invoke-OTestThrowing { Export-OSyncDotfiles -Config (New-OTestConfig -SourceDir 'manifests\does-not-exist') -StagingDir $staging }
            $err.Exception.Message | Should -Match 'not found'
        }

        It 'rejects a source state containing .chezmoiexternal.toml with an explicit error' {
            $repo = Join-Path $TestDrive 'repo-ext'
            $src = Join-Path $repo 'manifests\dotfiles'
            New-Item -ItemType Directory -Path $src -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $src 'dot_testfile.txt') -Value 'x' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $src '.chezmoiexternal.toml') -Value 'x' -Encoding UTF8

            $staging = Join-Path $TestDrive 'staging-ext'
            $err = Invoke-OTestThrowing { Export-OSyncDotfiles -Config (New-OTestConfig -RepoRoot $repo) -StagingDir $staging }
            $err.Exception.Message | Should -Match 'offline does not support externals'
            $err.Exception.Message | Should -Match '\.chezmoiexternal\.toml'
        }
    }
}