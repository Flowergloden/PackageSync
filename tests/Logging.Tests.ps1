#Requires -Version 5.1
# Logging.Tests.ps1 - Pester 5 tests for src\lib\Logging.ps1 (Write-OSyncLog).

Describe 'OfflineSync logging (Write-OSyncLog)' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $repoRoot 'src\OfflineSync.psd1') -Force

        $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-log-' + [Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

        $configA = [pscustomobject]@{
            role     = 'A'
            repoRoot = Join-Path $testRoot 'repoA'
            stateDir = Join-Path $testRoot 'stateA'
        }
        $configB = [pscustomobject]@{
            role     = 'B'
            repoRoot = Join-Path $testRoot 'repoB'
            stateDir = Join-Path $testRoot 'stateB'
        }

        # Reads the last non-empty line of a JSONL file as an object.
        function Get-LastJsonlEvent {
            param([string]$JsonlPath)
            $line = Get-Content -LiteralPath $JsonlPath | Where-Object { $_ } | Select-Object -Last 1
            return ($line | ConvertFrom-Json)
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context 'role A' {
        It 'writes one JSONL event under <repoRoot>\logs containing the message' {
            $jsonlPath = Write-OSyncLog -Category 'test' -Level 'Info' -Message 'osync happy smoke message' -Config $configA
            $jsonlPath | Should -Not -BeNullOrEmpty
            $jsonlPath | Should -BeLike (Join-Path $configA.repoRoot 'logs\*')
            Test-Path -LiteralPath $jsonlPath | Should -BeTrue

            $content = Get-Content -LiteralPath $jsonlPath -Raw
            $content | Should -BeLike '*osync happy smoke message*'

            $event = Get-LastJsonlEvent -JsonlPath $jsonlPath
            $event.category | Should -Be 'test'
            $event.level | Should -Be 'Info'
            $event.message | Should -Be 'osync happy smoke message'
        }

        It 'also writes a human-readable line file with the same message' {
            $jsonlPath = Write-OSyncLog -Category 'test' -Level 'Info' -Message 'human readable line probe' -Config $configA
            $txtPath = $jsonlPath -replace '\.jsonl$', '.log'
            Test-Path -LiteralPath $txtPath | Should -BeTrue
            (Get-Content -LiteralPath $txtPath -Raw) | Should -BeLike '*human readable line probe*'
        }
    }

    Context 'role B' {
        It 'writes under <stateDir>\run\logs' {
            $jsonlPath = Write-OSyncLog -Category 'test' -Level 'Warning' -Message 'b role probe' -Config $configB
            $jsonlPath | Should -BeLike (Join-Path $configB.stateDir 'run\logs\*')
            Test-Path -LiteralPath $jsonlPath | Should -BeTrue
            (Get-Content -LiteralPath $jsonlPath -Raw) | Should -BeLike '*b role probe*'
        }
    }

    Context 'structured data' {
        It 'round-trips the -Data payload inside the JSONL event' {
            $data = [pscustomobject]@{
                foo    = 'bar'
                nested = [pscustomobject]@{ number = 42 }
            }
            $jsonlPath = Write-OSyncLog -Category 'test' -Level 'Error' -Message 'data round trip' -Data $data -Config $configA
            $event = Get-LastJsonlEvent -JsonlPath $jsonlPath
            $event.data.foo | Should -Be 'bar'
            $event.data.nested.number | Should -Be 42
        }

        It 'logs the message without a data field when -Data is omitted' {
            $jsonlPath = Write-OSyncLog -Category 'test' -Level 'Debug' -Message 'no data probe' -Config $configA
            $event = Get-LastJsonlEvent -JsonlPath $jsonlPath
            $event.PSObject.Properties.Name -contains 'data' | Should -BeFalse
        }
    }
}
