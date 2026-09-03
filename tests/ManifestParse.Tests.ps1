# ManifestParse.Tests.ps1
#
# Pester 5 tests for src\lib\ManifestParse.ps1.
#
# The library is dot-sourced DIRECTLY (not via the OfflineSync module) so
# this suite runs standalone while the module manifest (todo 1) may not
# exist yet. Run with:
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\ManifestParse.Tests.ps1 -PassThru"

BeforeAll {
    $libPath = Join-Path $PSScriptRoot '..\src\lib\ManifestParse.ps1'
    . $libPath

    $fixtures = Join-Path $PSScriptRoot 'fixtures'
}

Describe 'Read-OSyncWingetList' {
    It 'parses Id and Id@version entries into objects with Id/Version/Line fields' {
        $result = @(Read-OSyncWingetList -Path (Join-Path $fixtures 'winget-list.txt'))
        $result.Count | Should -Be 4
        $result[0].Id | Should -Be '7zip.7zip'
        $result[0].Version | Should -Be '24.08'
        $result[1].Id | Should -Be 'Python.Python.3.12'
        $result[1].Version | Should -BeNullOrEmpty
        $result[2].Id | Should -Be 'OpenJS.NodeJS.LTS'
        $result[2].Version | Should -Be '22.17.0'
        $result[3].Id | Should -Be 'Microsoft.PowerToys'
        $result[3].Version | Should -BeNullOrEmpty
        # Line numbers point at the source lines (1-based).
        $result[0].Line | Should -Be 4
        $result[3].Line | Should -Be 7
    }

    It 'skips comments and blank lines and de-duplicates by Id (case-insensitive, first wins)' {
        $file = Join-Path $TestDrive 'dup.txt'
        @('# comment', '', 'A.B@1.0', 'a.b@2.0', 'C.D') | Set-Content -LiteralPath $file -Encoding UTF8
        $result = @(Read-OSyncWingetList -Path $file)
        $result.Count | Should -Be 2
        $result[0].Id | Should -Be 'A.B'
        $result[0].Version | Should -Be '1.0'
        $result[1].Id | Should -Be 'C.D'
    }

    It 'rejects a single-segment Id with an error message containing the line number' {
        $file = Join-Path $TestDrive 'badid.txt'
        @('7zip.7zip@24.08', 'Foo.Bar', 'single-segment') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncWingetList -Path $file } | Should -Throw -ExpectedMessage '*line 3*'
    }

    It 'rejects an empty version (Id@) with an error containing the line number' {
        $file = Join-Path $TestDrive 'emptyver.txt'
        @('Foo.Bar@') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncWingetList -Path $file } | Should -Throw -ExpectedMessage '*line 1*'
    }

    It 'throws when the file does not exist' {
        { Read-OSyncWingetList -Path (Join-Path $TestDrive 'missing.txt') } | Should -Throw -ExpectedMessage '*not found*'
    }
}

Describe 'Read-OSyncNpmList' {
    It 'parses name, name@version and @scope/name[@version] into Name/Version objects' {
        $result = @(Read-OSyncNpmList -Path (Join-Path $fixtures 'npm-list.txt'))
        $result.Count | Should -Be 4
        $result[0].Name | Should -Be 'lodash'
        $result[0].Version | Should -BeNullOrEmpty
        $result[1].Name | Should -Be 'is-odd'
        $result[1].Version | Should -Be '3.0.1'
        $result[2].Name | Should -Be '@babel/core'
        $result[2].Version | Should -Be '7.26.0'
        $result[3].Name | Should -Be '@types/node'
        $result[3].Version | Should -BeNullOrEmpty
    }

    It 'rejects a malformed scoped name with an error containing the line number' {
        $file = Join-Path $TestDrive 'badscope.txt'
        @('lodash', '@babel') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncNpmList -Path $file } | Should -Throw -ExpectedMessage '*line 2*'
    }

    It 'rejects an uppercase package name with an error containing the line number' {
        $file = Join-Path $TestDrive 'badname.txt'
        @('Lodash') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncNpmList -Path $file } | Should -Throw -ExpectedMessage '*line 1*'
    }

    It 'rejects an empty version (name@) with an error containing the line number' {
        $file = Join-Path $TestDrive 'emptyver.txt'
        @('lodash@') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncNpmList -Path $file } | Should -Throw -ExpectedMessage '*line 1*'
    }
}

Describe 'Read-OSyncRequirements' {
    It 'passes the original text through unchanged for a pinned file' {
        $file = Join-Path $fixtures 'requirements.txt'
        $result = Read-OSyncRequirements -Path $file
        $result | Should -Be ([System.IO.File]::ReadAllText($file))
        $result | Should -Match 'six==1\.16\.0'
        $result | Should -Match 'requests==2\.32\.3'
    }

    It 'throws for an empty (comment-only) requirements file' {
        $file = Join-Path $TestDrive 'empty.txt'
        @('# nothing here', '') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncRequirements -Path $file } | Should -Throw -ExpectedMessage '*empty*'
    }

    It 'throws for a -e (editable) line and names the line number' {
        $file = Join-Path $TestDrive 'editable.txt'
        @('six==1.16.0', '-e ..\localpkg') | Set-Content -LiteralPath $file -Encoding UTF8
        { Read-OSyncRequirements -Path $file } | Should -Throw -ExpectedMessage '*line 2*'
    }

    It 'throws for -r / -c / --requirement / --constraint lines and names the line number' {
        $cases = @(
            @('-r other.txt'),
            @('--requirement=other.txt'),
            @('-c constraints.txt'),
            @('--constraint constraints.txt'),
            @('--editable .')
        )
        foreach ($case in $cases) {
            $file = Join-Path $TestDrive 'opts.txt'
            @('six==1.16.0') + $case | Set-Content -LiteralPath $file -Encoding UTF8
            { Read-OSyncRequirements -Path $file } | Should -Throw -ExpectedMessage '*line 2*'
        }
    }

    It 'warns about unpinned lines (naming the line) but still returns the text' {
        $file = Join-Path $TestDrive 'unpinned.txt'
        @('six==1.16.0', 'requests') | Set-Content -LiteralPath $file -Encoding UTF8
        $warnings = @()
        $result = Read-OSyncRequirements -Path $file -WarningVariable warnings
        $result | Should -Match 'requests'
        @($warnings).Count | Should -Be 1
        ($warnings -join '') | Should -Match 'line 2'
    }
}
