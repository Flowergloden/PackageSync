# ManifestParse.ps1
#
# Offline manifest parsers for the A -> B one-way package sync pipeline.
#
# This file is intentionally STANDALONE: it must not depend on other lib
# files (Config.ps1 / Logging.ps1 / Util.ps1), because the parallel task
# that owns them may not have created them yet while this one runs.
# Plain Write-Warning / throw only - no Write-OSyncLog usage.
#
# Every parsed entry object carries a Line property holding the 1-based
# source line number for diagnostics, and every error raised for a
# malformed line includes that line number in its message.

# A winget package Id consists of at least two dot-separated segments,
# e.g. '7zip.7zip', 'Python.Python.3.12', 'OpenJS.NodeJS.LTS'.
$script:WingetIdPattern = '^([^.\s]+)(\.[^.\s]+)+$'

# A valid npm package name segment (lowercase, url-safe characters).
$script:NpmNameSegmentPattern = '^[a-z0-9][a-z0-9._~-]*$'

function Read-OSyncWingetList {
    <#
    .SYNOPSIS
    Parses a winget package list (one 'Id' or 'Id@version' entry per line).

    .DESCRIPTION
    Skips blank lines and '#' comments (full-line or inline), de-duplicates
    entries by Id (case-insensitive, first occurrence wins) and returns an
    array of objects with Id / Version / Line properties. Version is $null
    when the entry is not pinned. A malformed line raises an error whose
    message contains the line number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Winget list file not found: $Path"
    }

    $results = @()
    $seen = @{}

    # Force an array: a single-line file would otherwise yield a scalar
    # string and $lines[$i] would index individual characters.
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $lineNo = $i + 1
        $line = [string]$lines[$i]

        # Strip inline comments and surrounding whitespace.
        $trimmed = ($line -split '#', 2)[0].Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }

        # Optional '@version' - split at the first '@'.
        if ($trimmed.Contains('@')) {
            $at = $trimmed.IndexOf('@')
            $id = $trimmed.Substring(0, $at)
            $version = $trimmed.Substring($at + 1)
            if ($version -notmatch '^[^\s@]+$') {
                throw "Invalid winget list entry at line ${lineNo}: '$line' (version after '@' must be non-empty and free of whitespace or '@')."
            }
        }
        else {
            $id = $trimmed
            $version = $null
        }

        if ($id -notmatch $script:WingetIdPattern) {
            throw "Invalid winget list entry at line ${lineNo}: '$line' (expected 'Id' or 'Id@version' where Id has at least 2 dot-separated segments)."
        }

        # De-duplicate by Id, case-insensitive; first occurrence wins.
        $key = $id.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $results += [pscustomobject]@{
                Id      = $id
                Version = $version
                Line    = $lineNo
            }
        }
    }

    $results
}

function Read-OSyncNpmList {
    <#
    .SYNOPSIS
    Parses an npm package list (one entry per line).

    .DESCRIPTION
    Supports 'name', 'name@version' and '@scope/name[@version]'. Skips
    blank lines and '#' comments (full-line or inline), de-duplicates by
    package name (first occurrence wins) and returns an array of objects
    with Name / Version / Line properties. Version is $null when the entry
    is not pinned. A malformed line raises an error whose message contains
    the line number.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "npm list file not found: $Path"
    }

    $results = @()
    $seen = @{}

    # Force an array: a single-line file would otherwise yield a scalar
    # string and $lines[$i] would index individual characters.
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $lineNo = $i + 1
        $line = [string]$lines[$i]

        $trimmed = ($line -split '#', 2)[0].Trim()
        if ([string]::IsNullOrEmpty($trimmed)) { continue }

        # Scoped packages start with '@scope/name'.
        if ($trimmed.StartsWith('@')) {
            $slash = $trimmed.IndexOf('/')
            if ($slash -lt 2) {
                throw "Invalid npm list entry at line ${lineNo}: '$line' (scoped names must look like '@scope/name')."
            }
            $scopePart = $trimmed.Substring(1, $slash - 1)
            $rest = $trimmed.Substring($slash + 1)
        }
        else {
            $scopePart = $null
            $rest = $trimmed
        }

        # Optional '@version' - split at the first '@' inside the name part.
        if ($rest.Contains('@')) {
            $at = $rest.IndexOf('@')
            $namePart = $rest.Substring(0, $at)
            $version = $rest.Substring($at + 1)
        }
        else {
            $namePart = $rest
            $version = $null
        }

        if ($null -ne $scopePart) {
            # -cnotmatch: npm names are strictly lowercase.
            if ($scopePart -cnotmatch $script:NpmNameSegmentPattern -or $namePart -cnotmatch $script:NpmNameSegmentPattern) {
                throw "Invalid npm list entry at line ${lineNo}: '$line' (expected 'name', 'name@version' or '@scope/name[@version]')."
            }
            $name = '@' + $scopePart + '/' + $namePart
        }
        else {
            # -cnotmatch: npm names are strictly lowercase.
            if ($namePart -cnotmatch $script:NpmNameSegmentPattern) {
                throw "Invalid npm list entry at line ${lineNo}: '$line' (expected 'name', 'name@version' or '@scope/name[@version]')."
            }
            $name = $namePart
        }

        if ($null -ne $version -and $version -notmatch '^[^\s@]+$') {
            throw "Invalid npm list entry at line ${lineNo}: '$line' (version after '@' must be non-empty and free of whitespace or '@')."
        }

        $key = $name.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $results += [pscustomobject]@{
                Name    = $name
                Version = $version
                Line    = $lineNo
            }
        }
    }

    $results
}

function Read-OSyncRequirements {
    <#
    .SYNOPSIS
    Validates a pip requirements file and passes its text through unchanged.

    .DESCRIPTION
    Returns the original file content verbatim so the caller can copy it
    into the offline export without transformation. Enforced rules:

      - An empty file (no non-comment, non-blank entries) raises an error.
      - Lines using -e/--editable, -r/--requirement or -c/--constraint
        raise an error naming the line number: editable installs and
        referenced requirement/constraint files are not reproducible
        offline and the referenced files are not part of the export.
      - Lines without an exact '==' pin produce a Write-Warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Requirements file not found: $Path"
    }

    # Read the raw bytes as UTF-8 (BOM-aware) and pass the text through.
    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $content = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)

    $lines = $content -split "`r?`n"
    $hasEntry = $false

    for ($i = 0; $i -lt @($lines).Count; $i++) {
        $lineNo = $i + 1
        $line = [string]$lines[$i]

        # Validate on the comment-stripped form, but never alter the output text.
        $check = ($line -split '#', 2)[0].Trim()
        if ([string]::IsNullOrEmpty($check)) { continue }

        $hasEntry = $true

        # Offline-unfriendly option lines.
        if ($check -match '^--(editable|requirement|constraint)(?:\s|=|$)') {
            throw "Requirements file '$Path' line $lineNo uses '--$($Matches[1])', which is not supported for offline export (editable installs / referenced files are not shipped): '$line'."
        }
        if ($check -match '^-[erc](?:\s|=|$)') {
            throw "Requirements file '$Path' line $lineNo uses option '$($Matches[0].TrimEnd())', which is not supported for offline export (referenced files are not shipped): '$line'."
        }

        # Pinning check: an exact pin must contain '=='.
        if ($check -notmatch '==') {
            Write-Warning "Requirements file '$Path' line $lineNo is not pinned with '==': '$line'"
        }
    }

    if (-not $hasEntry) {
        throw "Requirements file '$Path' is empty (no non-comment requirement entries found)."
    }

    $content
}
