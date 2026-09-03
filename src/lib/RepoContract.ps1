#Requires -Version 5.1
<#
  RepoContract.ps1 - the repository trust root (files.json / index.json).

  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  New-OSyncFilesManifest  : streams SHA256 over every file under <dir> (recursive)
                            and writes <dir>\files.json as
                              { "<relative path with / slashes>": {"sha256": "...", "bytes": N} }
                            The manifest itself (files.json) is always excluded.
                            Hashing uses a FileStream + a 1 MB buffer - files are
                            never loaded into memory whole.

  Publish-OSyncIndex      : writes <staging>\index.json describing every category
                            directory that exists in the staging dir:
                              {
                                "schemaVersion": 1,
                                "tool": "ab-one-way-sync",
                                "exportedAtUtc": "<yyyyMMddTHHmmssZ>",
                                "categories": {
                                  "<cat>": {"files": "<cat>/files.json",
                                            "sha256": "<sha256 of files.json>",
                                            "count": N}
                                }
                              }
                            exportedAtUtc uses the ISO8601 BASIC format (no ':')
                            because NTFS forbids ':' in directory names and the
                            timestamp feeds generation directory names - index
                            values and generation directory names share one
                            source and one format (Oracle r7-2).

  Test-OSyncRepoIntegrity : strict trust-root validation, in this exact order:
                            1. index.json exists and parses as JSON
                               (failure => overall status 'Invalid', trust nothing,
                                no category is examined at all)
                            2. per category: files.json exists AND its sha256
                               matches the index record
                            3. files.json parses as JSON
                            4. per file listed in files.json: sha256 recheck
                            Returns a result object with per-category status
                            'OK' | 'Incomplete' | 'Missing' plus the lists of
                            missing / corrupt files.

  JSON READING is done through a small private reader (ConvertFrom-RcJson):
    - Windows PowerShell 5.1: System.Web.Extensions' JavaScriptSerializer with
      MaxJsonLength = [int]::MaxValue. PS 5.1's ConvertFrom-Json uses the same
      serializer with the DEFAULT ~2 MB cap and dies on big manifests (Oracle m1)
      - an npm storage category can easily exceed 2 MB of manifest text.
    - pwsh 7 (System.Web.Extensions does not exist there): ConvertFrom-Json
      -AsHashtable, which has no 2 MB limit on PowerShell 7.
    Both branches yield nested IDictionary-compatible objects, so all downstream
    code treats JSON objects uniformly.

  JSON WRITING goes exclusively through ConvertTo-OSyncJson (Util.ps1), which
  always uses -Depth 10. All files are written UTF-8 WITH BOM.

  NOTE: files present on disk but absent from files.json are NOT reported -
  the manifest is the contract; extra un-manifested files are out of scope of
  the trust check and are left to the B-side cleanup logic (todo 12+).
#>

# ---------------------------------------------------------------- private
# One-time probe: System.Web.Extensions (JavaScriptSerializer) exists on
# Windows PowerShell 5.1 but NOT on pwsh 7 (.NET Framework only). Probe once
# at import time so every read does not pay for a failing Add-Type.
# GOTCHA: on pwsh 7 Add-Type can SUCCEED against the reference assemblies,
# and even New-Object succeeds - the TypeLoadException only surfaces when
# DeserializeObject actually loads the System.Web pipeline. The probe must
# therefore do a FULL round trip.
$script:RcJsSerializerAvailable = $false
try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $probe = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $null = $probe.DeserializeObject('{}')
    $script:RcJsSerializerAvailable = $true
} catch {
    # pwsh 7: fall back to ConvertFrom-Json -AsHashtable (see header).
    $script:RcJsSerializerAvailable = $false
}

# Reads JSON text into a nested IDictionary-compatible object graph.
# Throws (propagates the underlying exception) when the text is not valid JSON.
function ConvertFrom-RcJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    if ($script:RcJsSerializerAvailable) {
        try {
            $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            # Lift the ~2 MB default cap - repository manifests can be huge
            # (Oracle m1). PS 5.1's own ConvertFrom-Json does NOT lift it.
            $serializer.MaxJsonLength = [int]::MaxValue
            return $serializer.DeserializeObject($Text)
        } catch [System.TypeLoadException] {
            # Runtime type-load failure (pwsh 7 partial type load). Permanently
            # switch to the fallback for the rest of this session. Real JSON
            # parse errors (ArgumentException) still propagate to the caller.
            $script:RcJsSerializerAvailable = $false
        }
    }
    return (ConvertFrom-Json -InputObject $Text -AsHashtable)
}

# Streams SHA256 over a file without loading it into memory (1 MB buffer).
function Get-RcSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $buffer = New-Object byte[] 1048576
        while ($true) {
            $read = $stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }
            [void]$sha.TransformBlock($buffer, 0, $read, $null, 0)
        }
        [void]$sha.TransformFinalBlock($buffer, 0, 0)
        return ([System.BitConverter]::ToString($sha.Hash).Replace('-', '').ToLowerInvariant())
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $sha.Dispose()
    }
}

# Writes UTF-8 text WITH BOM (consistent with the rest of the project).
function Write-RcTextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text
    )
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------------------------------------------------------------- public

function New-OSyncFilesManifest {
    <#
    .SYNOPSIS
        Streams SHA256 over every file under <dir> and writes <dir>\files.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Dir
    )

    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) {
        throw "New-OSyncFilesManifest: directory not found: '$Dir'."
    }

    $dirFull = [System.IO.Path]::GetFullPath($Dir)
    $prefix = $dirFull.TrimEnd('\', '/') + '\'
    $manifestFull = [System.IO.Path]::GetFullPath((Join-Path $dirFull 'files.json'))

    $map = @{}
    Get-ChildItem -LiteralPath $dirFull -Recurse -File -Force |
        Where-Object { -not ($_.FullName -eq $manifestFull) } |
        ForEach-Object {
            # Relative path with FORWARD slashes (stable across OS and readable
            # by any JSON consumer). -eq on FullName is case-insensitive on
            # Windows, so files.json is excluded regardless of case.
            $rel = $_.FullName.Substring($prefix.Length).Replace('\', '/')
            $map[$rel] = @{
                sha256 = (Get-RcSha256 -Path $_.FullName)
                bytes  = $_.Length
            }
        }

    $json = ConvertTo-OSyncJson -InputObject $map
    Write-RcTextFile -Path $manifestFull -Text $json
    return (Get-Item -LiteralPath $manifestFull)
}

function Publish-OSyncIndex {
    <#
    .SYNOPSIS
        Writes <staging>\index.json describing every category dir that exists.
        Requires each existing category to already carry its files.json
        (call New-OSyncFilesManifest first) - a category without a manifest
        is a publish error, never a silent skip.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StagingDir
    )

    if (-not (Test-Path -LiteralPath $StagingDir -PathType Container)) {
        throw "Publish-OSyncIndex: staging directory not found: '$StagingDir'."
    }

    # Fixed category order; only dirs that EXIST are indexed.
    $categories = @{}
    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles', 'runtime')) {
        $catDir = Join-Path $StagingDir $cat
        if (-not (Test-Path -LiteralPath $catDir -PathType Container)) { continue }

        $filesJson = Join-Path $catDir 'files.json'
        if (-not (Test-Path -LiteralPath $filesJson -PathType Leaf)) {
            throw "Publish-OSyncIndex: category '$cat' exists but has no files.json. Run New-OSyncFilesManifest on it first."
        }

        # Re-read the manifest so 'count' is the count of the manifest that is
        # actually on disk (source of truth), not a stale in-memory number.
        $manifest = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText($filesJson))
        if ($null -eq $manifest -or -not ($manifest -is [System.Collections.IDictionary])) {
            throw "Publish-OSyncIndex: '$filesJson' is not a valid JSON object."
        }

        $categories[$cat] = @{
            files  = ($cat + '/files.json')
            sha256 = (Get-RcSha256 -Path $filesJson)
            count  = $manifest.Count
        }
    }

    $index = @{
        schemaVersion = 1
        tool          = 'ab-one-way-sync'
        # ISO8601 BASIC format: directory-name safe (NTFS forbids ':').
        exportedAtUtc = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        categories    = $categories
    }

    $indexPath = Join-Path $StagingDir 'index.json'
    Write-RcTextFile -Path $indexPath -Text (ConvertTo-OSyncJson -InputObject $index)
    return (Get-Item -LiteralPath $indexPath)
}

function Test-OSyncRepoIntegrity {
    <#
    .SYNOPSIS
        Validates a repository against its index.json trust root.
        Returns a result object (not a bool): Overall + per-category status
        'OK' | 'Incomplete' | 'Missing' with missing/corrupt file lists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $repoFull = [System.IO.Path]::GetFullPath($RepoRoot)
    $indexPath = Join-Path $repoFull 'index.json'

    $result = [pscustomobject]@{
        RepoRoot      = $repoFull
        Overall       = 'OK'          # 'OK' | 'Incomplete' | 'Invalid'
        IndexPath     = $indexPath
        IndexSha256   = $null
        IndexError    = $null
        ExportedAtUtc = $null
        Categories    = @{}           # category name -> category status object
    }

    # 1) index.json must exist AND parse as JSON. On any failure here the
    #    whole repository is 'Invalid' and NOTHING is trusted - no category,
    #    no files.json, no file hash is examined (a broken trust root makes
    #    every downstream hash chain meaningless).
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        $result.Overall = 'Invalid'
        $result.IndexError = "index.json not found at '$indexPath'."
        return $result
    }
    $result.IndexSha256 = Get-RcSha256 -Path $indexPath
    try {
        $index = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText($indexPath))
    } catch {
        $result.Overall = 'Invalid'
        $result.IndexError = "index.json is not valid JSON: $($_.Exception.Message)"
        return $result
    }
    if ($null -eq $index -or -not ($index -is [System.Collections.IDictionary])) {
        $result.Overall = 'Invalid'
        $result.IndexError = 'index.json is not a JSON object.'
        return $result
    }
    if (-not $index.ContainsKey('categories') -or -not ($index['categories'] -is [System.Collections.IDictionary])) {
        $result.Overall = 'Invalid'
        $result.IndexError = "index.json is missing the required 'categories' object."
        return $result
    }
    $result.ExportedAtUtc = $index['exportedAtUtc']

    # 2)-4) per category: files.json exists + sha256 matches the index record,
    #      files.json parses, then per-file sha256 recheck.
    $categories = $index['categories']
    $anyNotOk = $false
    foreach ($entry in $categories.GetEnumerator()) {
        $catName = [string]$entry.Key
        $catResult = [pscustomobject]@{
            Category       = $catName
            Status         = 'OK'
            Reason         = $null
            FilesJsonPath  = $null
            ExpectedSha256 = $null
            ActualSha256   = $null
            Count          = $null
            MissingFiles   = @()
            CorruptFiles   = @()
        }

        $rec = $entry.Value
        if ($null -eq $rec -or -not ($rec -is [System.Collections.IDictionary]) -or
            -not $rec.ContainsKey('files') -or -not $rec.ContainsKey('sha256')) {
            $catResult.Status = 'Missing'
            $catResult.Reason = "malformed index record for category '$catName'."
            $result.Categories[$catName] = $catResult
            $anyNotOk = $true
            continue
        }

        $filesJsonPath = Join-Path $repoFull ([string]$rec['files'])
        $catResult.FilesJsonPath = $filesJsonPath
        $catResult.ExpectedSha256 = [string]$rec['sha256']
        if ($rec.ContainsKey('count')) { $catResult.Count = [int64]$rec['count'] }

        # 2) files.json exists and its sha256 matches the index record.
        #    A missing OR mismatching manifest makes the whole category
        #    'Missing': its file list cannot be trusted either way.
        if (-not (Test-Path -LiteralPath $filesJsonPath -PathType Leaf)) {
            $catResult.Status = 'Missing'
            $catResult.Reason = "files.json not found at '$filesJsonPath'."
            $result.Categories[$catName] = $catResult
            $anyNotOk = $true
            continue
        }
        $catResult.ActualSha256 = Get-RcSha256 -Path $filesJsonPath
        if ($catResult.ActualSha256 -ne $catResult.ExpectedSha256) {
            $catResult.Status = 'Missing'
            $catResult.Reason = ("files.json sha256 mismatch for category '{0}' (index recorded '{1}', actual '{2}')." -f
                $catName, $catResult.ExpectedSha256, $catResult.ActualSha256)
            $result.Categories[$catName] = $catResult
            $anyNotOk = $true
            continue
        }

        # 3) files.json parses (should be guaranteed by the hash match, but the
        #    hash is only a byte-level check - keep the structural check anyway).
        try {
            $manifest = ConvertFrom-RcJson -Text ([System.IO.File]::ReadAllText($filesJsonPath))
        } catch {
            $catResult.Status = 'Missing'
            $catResult.Reason = "files.json of category '$catName' is not valid JSON: $($_.Exception.Message)"
            $result.Categories[$catName] = $catResult
            $anyNotOk = $true
            continue
        }
        if ($null -eq $manifest -or -not ($manifest -is [System.Collections.IDictionary])) {
            $catResult.Status = 'Missing'
            $catResult.Reason = "files.json of category '$catName' is not a JSON object."
            $result.Categories[$catName] = $catResult
            $anyNotOk = $true
            continue
        }

        # 4) per-file recheck. Paths in files.json are relative to the
        #    directory CONTAINING files.json (i.e. the category dir).
        $catDir = Split-Path -Parent $filesJsonPath
        $missing = New-Object System.Collections.Generic.List[string]
        $corrupt = New-Object System.Collections.Generic.List[string]
        foreach ($fileEntry in $manifest.GetEnumerator()) {
            $relPath = [string]$fileEntry.Key
            $meta = $fileEntry.Value
            $filePath = Join-Path $catDir $relPath

            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                $missing.Add($relPath)
                continue
            }

            # Byte-count check first: cheap, catches truncation/growth without
            # hashing the file at all.
            if ($meta -is [System.Collections.IDictionary] -and $meta.ContainsKey('bytes')) {
                $expectedBytes = [int64]$meta['bytes']
                if ((Get-Item -LiteralPath $filePath -Force).Length -ne $expectedBytes) {
                    $corrupt.Add($relPath)
                    continue
                }
            }

            if ($meta -is [System.Collections.IDictionary] -and $meta.ContainsKey('sha256')) {
                $expectedSha = [string]$meta['sha256']
                if ((Get-RcSha256 -Path $filePath) -ne $expectedSha) {
                    $corrupt.Add($relPath)
                }
            }
        }
        $catResult.MissingFiles = $missing.ToArray()
        $catResult.CorruptFiles = $corrupt.ToArray()

        if ($catResult.MissingFiles.Count -gt 0 -or $catResult.CorruptFiles.Count -gt 0) {
            $catResult.Status = 'Incomplete'
            $anyNotOk = $true
        }

        $result.Categories[$catName] = $catResult
    }

    if ($anyNotOk) { $result.Overall = 'Incomplete' }
    return $result
}
