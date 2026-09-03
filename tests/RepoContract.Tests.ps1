#Requires -Version 5.1
<#
  RepoContract.Tests.ps1 - Pester 5 tests for src\lib\RepoContract.ps1.

  Exercises the repository trust root end-to-end on temporary directory
  trees: files.json generation (streaming SHA256, forward-slash keys,
  files.json exclusion), index.json publishing (only existing categories,
  ISO8601-basic exportedAtUtc), and strict integrity validation in the
  mandated order (index -> per-category files.json hash -> per-file hash).

  Also proves the >2 MB manifest path: PS 5.1's ConvertFrom-Json dies on
  JSON above ~2 MB (JavaScriptSerializer default MaxJsonLength), so the
  suite feeds the integrity checker a >2 MB files.json and asserts it is
  parsed and verified instead of reported as Missing.

  Run:
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\RepoContract.Tests.ps1 -PassThru"
    pwsh      -NoProfile -Command "Invoke-Pester tests\RepoContract.Tests.ps1 -PassThru"
#>

BeforeAll {
    # Import the real module: it dot-sources every lib\*.ps1 (incl.
    # RepoContract.ps1 and its Util.ps1 dependency) and exports *-OSync*.
    Import-Module (Join-Path $PSScriptRoot '..\src\OfflineSync.psd1') -Force

    # One shared temp root per run; every test builds its own subtree.
    $script:rcRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-rc-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:rcRoot -Force | Out-Null

    # --- helpers (Pester 5 runs It blocks in child scopes of BeforeAll,
    # --- so functions must be defined here, not at file top level) ---

    function New-RcTestDir {
        $d = Join-Path $script:rcRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        return $d
    }

    # Builds a category tree. Keys are forward-slash relative paths,
    # values are file contents (UTF-8).
    function New-RcCategoryTree {
        param([string]$Root, [string]$Category, [hashtable]$Files)
        $catDir = Join-Path $Root $Category
        New-Item -ItemType Directory -Path $catDir -Force | Out-Null
        foreach ($kv in $Files.GetEnumerator()) {
            $p = Join-Path $catDir ($kv.Key -replace '/', '\')
            $parent = Split-Path -Parent $p
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [System.IO.File]::WriteAllBytes($p, [System.Text.Encoding]::UTF8.GetBytes([string]$kv.Value))
        }
        return $catDir
    }

    # Builds a complete, valid repository (winget + pip categories) with
    # generated files.json manifests and a published index.json.
    function New-RcFullRepo {
        param([string]$Root)
        New-RcCategoryTree -Root $Root -Category 'winget' -Files @{
            'installer.exe'     = 'WINGET-BINARY-PAYLOAD'
            'sub/manifest.yaml' = 'yaml: 1'
            'has space.bin'     = 'spaced'
        } | Out-Null
        New-RcCategoryTree -Root $Root -Category 'pip' -Files @{
            'six-1.17.0.whl' = 'WHL-PAYLOAD'
            'requirements.txt' = 'six==1.17.0'
        } | Out-Null
        New-OSyncFilesManifest -Dir (Join-Path $Root 'winget') | Out-Null
        New-OSyncFilesManifest -Dir (Join-Path $Root 'pip') | Out-Null
        Publish-OSyncIndex -StagingDir $Root | Out-Null
        return $Root
    }

    # Test-side JSON reader - only for SMALL manifests (the module itself
    # has the >2 MB-proof reader; this helper is never fed big payloads).
    function Read-RcJsonFile {
        param([string]$Path)
        return (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path)))
    }
}

AfterAll {
    if (Test-Path -LiteralPath $script:rcRoot) {
        Remove-Item -LiteralPath $script:rcRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-OSyncFilesManifest' {

    It 'writes files.json with forward-slash keys, sha256+bytes, excluding files.json itself' {
        $dir = New-RcTestDir
        New-RcCategoryTree -Root $dir -Category 'x' -Files @{
            'a.txt'          = 'hello'
            'sub/b.bin'      = 'world'
            'with space.cfg' = 'x y z'
        } | Out-Null
        $catDir = Join-Path $dir 'x'

        # A stale files.json must be overwritten AND excluded from the manifest.
        [System.IO.File]::WriteAllText((Join-Path $catDir 'files.json'), 'JUNK-NOT-JSON')

        $out = New-OSyncFilesManifest -Dir $catDir
        $out.FullName | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $catDir 'files.json')))

        $m = Read-RcJsonFile -Path $out.FullName
        $names = @($m.PSObject.Properties.Name | Sort-Object)
        ($names -join '|') | Should -Be 'a.txt|sub/b.bin|with space.cfg'
        $names | Should -Not -Contain 'files.json'

        $m.'sub/b.bin'.sha256 | Should -Be (
            (Get-FileHash -LiteralPath (Join-Path $catDir 'sub\b.bin') -Algorithm SHA256).Hash.ToLowerInvariant())
        $m.'sub/b.bin'.bytes | Should -Be ([System.IO.File]::ReadAllBytes((Join-Path $catDir 'sub\b.bin')).Length)
        $m.'with space.cfg'.bytes | Should -Be 5
    }

    It 'is deterministic across runs' {
        $dir = New-RcTestDir
        New-RcCategoryTree -Root $dir -Category 'x' -Files @{ 'f.bin' = 'payload' } | Out-Null
        $catDir = Join-Path $dir 'x'
        New-OSyncFilesManifest -Dir $catDir | Out-Null
        $first = Get-FileHash -LiteralPath (Join-Path $catDir 'files.json') -Algorithm SHA256
        New-OSyncFilesManifest -Dir $catDir | Out-Null
        $second = Get-FileHash -LiteralPath (Join-Path $catDir 'files.json') -Algorithm SHA256
        $second.Hash | Should -Be $first.Hash
    }

    It 'writes an empty manifest object for an empty directory' {
        $dir = New-RcTestDir
        $catDir = Join-Path $dir 'emptycat'
        New-Item -ItemType Directory -Path $catDir -Force | Out-Null
        New-OSyncFilesManifest -Dir $catDir | Out-Null
        $m = Read-RcJsonFile -Path (Join-Path $catDir 'files.json')
        @($m.PSObject.Properties).Count | Should -Be 0
    }

    It 'throws when the directory does not exist' {
        { New-OSyncFilesManifest -Dir (Join-Path $script:rcRoot 'does-not-exist') } |
            Should -Throw -ExpectedMessage '*directory not found*'
    }
}

Describe 'Publish-OSyncIndex' {

    It 'indexes only categories that exist, with files path, sha256 and count' {
        $staging = New-RcTestDir
        New-RcCategoryTree -Root $staging -Category 'winget' -Files @{ 'a.exe' = 'A'; 'b.exe' = 'B' } | Out-Null
        New-RcCategoryTree -Root $staging -Category 'pip' -Files @{ 'x.whl' = 'X' } | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $staging 'dotfiles') -Force | Out-Null
        New-OSyncFilesManifest -Dir (Join-Path $staging 'winget') | Out-Null
        New-OSyncFilesManifest -Dir (Join-Path $staging 'pip') | Out-Null
        New-OSyncFilesManifest -Dir (Join-Path $staging 'dotfiles') | Out-Null

        $out = Publish-OSyncIndex -StagingDir $staging
        $out.FullName | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $staging 'index.json')))

        $idx = Read-RcJsonFile -Path $out.FullName
        [int]$idx.schemaVersion | Should -Be 1
        $idx.tool | Should -Be 'ab-one-way-sync'
        $idx.exportedAtUtc | Should -Match '^\d{8}T\d{6}Z$'
        # Parsable as the exact ISO8601-basic pattern it was written with.
        { [datetime]::ParseExact($idx.exportedAtUtc, 'yyyyMMddTHHmmssZ', $null) | Out-Null } |
            Should -Not -Throw

        # npm and runtime dirs do not exist -> excluded; dotfiles (empty) included.
        (@($idx.categories.PSObject.Properties.Name | Sort-Object) -join '|') |
            Should -Be 'dotfiles|pip|winget'

        $idx.categories.winget.files | Should -Be 'winget/files.json'
        $idx.categories.winget.sha256 | Should -Be (
            (Get-FileHash -LiteralPath (Join-Path $staging 'winget\files.json') -Algorithm SHA256).Hash.ToLowerInvariant())
        [int]$idx.categories.winget.count | Should -Be 2
        [int]$idx.categories.pip.count | Should -Be 1
        [int]$idx.categories.dotfiles.count | Should -Be 0
    }

    It 'throws when a category dir exists without files.json and names the category' {
        $staging = New-RcTestDir
        New-RcCategoryTree -Root $staging -Category 'winget' -Files @{ 'a.exe' = 'A' } | Out-Null
        { Publish-OSyncIndex -StagingDir $staging } |
            Should -Throw -ExpectedMessage '*winget*'
    }

    It 'throws when the staging directory does not exist' {
        { Publish-OSyncIndex -StagingDir (Join-Path $script:rcRoot 'no-staging') } |
            Should -Throw -ExpectedMessage '*staging directory not found*'
    }
}

Describe 'Test-OSyncRepoIntegrity' {

    It 'happy path: complete repository reports overall OK with every category OK' {
        $repo = New-RcFullRepo -Root (New-RcTestDir)
        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'OK'
        $r.ExportedAtUtc | Should -Match '^\d{8}T\d{6}Z$'
        $r.Categories.Count | Should -Be 2
        $r.Categories.winget.Status | Should -Be 'OK'
        $r.Categories.pip.Status | Should -Be 'OK'
        $r.Categories.winget.MissingFiles.Count | Should -Be 0
        $r.Categories.winget.CorruptFiles.Count | Should -Be 0
        $r.Categories.pip.CorruptFiles.Count | Should -Be 0
        $r.Categories.winget.Count | Should -Be 3
    }

    It 'a flipped byte makes the owning category Incomplete and names the corrupt file' {
        $repo = New-RcFullRepo -Root (New-RcTestDir)
        $target = Join-Path $repo 'winget\installer.exe'
        $bytes = [System.IO.File]::ReadAllBytes($target)
        $bytes[0] = $bytes[0] -bxor 0xFF
        [System.IO.File]::WriteAllBytes($target, $bytes)

        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Incomplete'
        $r.Categories.winget.Status | Should -Be 'Incomplete'
        $r.Categories.winget.CorruptFiles | Should -Contain 'installer.exe'
        $r.Categories.winget.MissingFiles.Count | Should -Be 0
        $r.Categories.pip.Status | Should -Be 'OK'
    }

    It 'a deleted payload file is reported as missing, not corrupt' {
        $repo = New-RcFullRepo -Root (New-RcTestDir)
        Remove-Item -LiteralPath (Join-Path $repo 'winget\sub\manifest.yaml') -Force

        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Incomplete'
        $r.Categories.winget.Status | Should -Be 'Incomplete'
        $r.Categories.winget.MissingFiles | Should -Contain 'sub/manifest.yaml'
        $r.Categories.winget.CorruptFiles.Count | Should -Be 0
        $r.Categories.pip.Status | Should -Be 'OK'
    }

    It 'a deleted files.json makes that category Missing while others stay OK' {
        $repo = New-RcFullRepo -Root (New-RcTestDir)
        Remove-Item -LiteralPath (Join-Path $repo 'winget\files.json') -Force

        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Incomplete'
        $r.Categories.winget.Status | Should -Be 'Missing'
        $r.Categories.winget.Reason | Should -Match 'files.json not found'
        $r.Categories.pip.Status | Should -Be 'OK'
    }

    It 'a truncated index.json invalidates the whole repository and trusts nothing' {
        $repo = New-RcFullRepo -Root (New-RcTestDir)
        $indexPath = Join-Path $repo 'index.json'
        $bytes = [System.IO.File]::ReadAllBytes($indexPath)
        $half = [int]($bytes.Length / 2)
        [System.IO.File]::WriteAllBytes($indexPath, [byte[]]$bytes[0..($half - 1)])

        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Invalid'
        $r.IndexError | Should -Match 'not valid JSON'
        $r.Categories.Count | Should -Be 0
    }

    It 'a missing index.json makes the repository Invalid' {
        $repo = New-RcTestDir
        New-RcCategoryTree -Root $repo -Category 'winget' -Files @{ 'a.exe' = 'A' } | Out-Null
        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Invalid'
        $r.IndexError | Should -Match 'index.json not found'
        $r.Categories.Count | Should -Be 0
    }

    It 'a non-object index.json makes the repository Invalid' {
        $repo = New-RcTestDir
        [System.IO.File]::WriteAllText((Join-Path $repo 'index.json'), '[1,2,3]')
        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Invalid'
        $r.IndexError | Should -Match 'not a JSON object'
    }

    It 'a tampered index sha256 for files.json marks that category Missing' {
        $repo = New-RcFullRepo -Root (New-RcTestDir)
        $indexPath = Join-Path $repo 'index.json'
        $idx = Read-RcJsonFile -Path $indexPath
        $idx.categories.winget.sha256 = ('0' * 64)
        [System.IO.File]::WriteAllText($indexPath, (ConvertTo-Json -InputObject $idx -Depth 10))

        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Incomplete'
        $r.Categories.winget.Status | Should -Be 'Missing'
        $r.Categories.winget.Reason | Should -Match 'sha256 mismatch'
        $r.Categories.pip.Status | Should -Be 'OK'
    }

    It 'parses and verifies a files.json larger than 2 MB (MaxJsonLength lifted)' {
        # PS 5.1's ConvertFrom-Json caps out at ~2 MB (JavaScriptSerializer
        # default MaxJsonLength). The module's reader must lift that cap, or
        # this category would come back 'Missing' instead of 'Incomplete'.
        $repo = New-RcTestDir
        $bigDir = Join-Path $repo 'big'
        New-Item -ItemType Directory -Path $bigDir -Force | Out-Null

        $entryCount = 22000
        $sb = New-Object System.Text.StringBuilder
        for ($i = 0; $i -lt $entryCount; $i++) {
            if ($i -gt 0) { [void]$sb.Append(',') }
            [void]$sb.Append(('"f{0:D5}.dat":{{"sha256":"{1}","bytes":0}}' -f $i, ('a' * 64)))
        }
        $manifestText = '{' + $sb.ToString() + '}'
        $manifestPath = Join-Path $bigDir 'files.json'
        [System.IO.File]::WriteAllText($manifestPath, $manifestText)
        (Get-Item -LiteralPath $manifestPath).Length | Should -BeGreaterThan 2097152

        $idx = @{
            schemaVersion = 1
            tool          = 'ab-one-way-sync'
            exportedAtUtc = '20260903T000000Z'
            categories    = @{
                big = @{
                    files  = 'big/files.json'
                    sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    count  = $entryCount
                }
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $repo 'index.json'), (ConvertTo-Json -InputObject $idx -Depth 10))

        $r = Test-OSyncRepoIntegrity -RepoRoot $repo
        $r.Overall | Should -Be 'Incomplete'
        # 'Incomplete' (not 'Missing') proves the 2 MB+ manifest was parsed.
        $r.Categories.big.Status | Should -Be 'Incomplete'
        $r.Categories.big.MissingFiles.Count | Should -Be $entryCount
        $r.Categories.big.CorruptFiles.Count | Should -Be 0
    }
}
