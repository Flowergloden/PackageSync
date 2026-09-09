#Requires -Version 5.1
<#
  ManifestGenerate.ps1 - A-side interactive manifest generator for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncManifestGenerate -Config <config> [-Category winget,pip,npm,bun]
    is the core of src\Export-Manifests.ps1 (the entry script is a thin
    wrapper that imports the module and maps success to the process exit
    code). It is a STANDALONE manual operator tool: it reads the installed
    package set from the A machine (winget export / pip freeze / npm ls -g
    / bun pm ls -g), lets the operator pick entries at the console
    (numbered multi-select), pins the picked entries to the installed
    versions and writes them back into the manifests (winget-packages.txt
    / requirements.txt / npm-packages.txt / bun-packages.txt). It never
    touches the export/apply pipelines.

    1. Per category: collect the installed packages (Get-OSyncInstalledWinget
       / Get-OSyncInstalledPip / Get-OSyncInstalledNpm /
       Get-OSyncInstalledBun). The bun category is presence-gated: it is
       skipped with an Info log (not an error) when the config has no
       paths.bunList key.
    2. Parse the existing manifest entries (Read-OSyncWingetList /
       Read-OSyncNpmList; pip requirements are classified line-wise with
       PEP 503 name normalization - lowercase, runs of [-_.] folded to a
       single '-').
    3. Merge: installed ∪ existing, matched by Key case-insensitively.
       Existing entries are preselected, installed-only entries are not,
       and existing-only entries display ' (not installed)'.
    4. Show-OSyncEntryPicker: numbered multi-select at the console
       (1,3,5-8 / all / none / Enter keeps the preselection).
    5. Write back: human comment lines ('#' prefix) preserved at the top in
       original order + one blank line + the selected entries (installed
       first in collection order, surviving existing entries after),
       pinned to the installed versions. A missing manifest is treated as
       an empty existing manifest (first-generation scenario).
    6. No-op detection: when the target content is line-for-line identical
       to the original, nothing is written and no backup is made; a real
       change first copies '<manifest>.bak-<yyyyMMddTHHmmssZ>' (UTC) and
       then rewrites the file as UTF-8 WITH BOM with CRLF line endings.
    7. An empty selection for a category leaves its manifest untouched (a
       Warning is logged) - an empty requirements.txt would break the
       existing parsers, so an empty manifest is NEVER written.
    8. One category's failure (e.g. winget unavailable) is logged as Error
       and does not block the other categories.

  Every Write-OSyncLog call is piped to Out-Null - Write-OSyncLog RETURNS
  the JSONL path and a bare call would leak strings into the output stream
  (documented gotcha).

  User decision: console numbered multi-select only (no Out-GridView);
  only winget/pip/npm/bun participate (dotfiles has no per-entry
  interaction; bun is opt-in via -Category, not in the default category
  list);
  the picker hard-fails when the session is not interactive (scheduled
  task / non-interactive session); this is an A-side manual tool - it is
  never registered as a scheduled task.
#>

function ConvertTo-OSyncPep503Name {
    <#
    .SYNOPSIS
        Normalizes a pip package name per PEP 503: lowercase, and runs of
        '-', '_' and '.' are folded into a single '-'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )
    return (($Name.ToLowerInvariant()) -replace '[-_.]+', '-')
}

function Get-OSyncInstalledWinget {
    <#
    .SYNOPSIS
        Collects the installed winget packages via `winget export`.

    .DESCRIPTION
        Resolves winget.exe via Resolve-OSyncWingetExePath (override with
        -WingetExePath for tests), runs
          winget export -o <temp.json> --include-versions --accept-source-agreements
        and parses Sources[].Packages[] into @{ Id; Version } objects
        (PackageIdentifier / Version). Throws with a clear message when
        winget.exe is unavailable, the export exits non-zero, or the JSON
        cannot be parsed. The temporary export file is removed in finally.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$WingetExePath
    )

    if ([string]::IsNullOrWhiteSpace($WingetExePath)) {
        $WingetExePath = Resolve-OSyncWingetExePath
        if ([string]::IsNullOrWhiteSpace($WingetExePath)) {
            throw 'Get-OSyncInstalledWinget: winget.exe not found (App Installer not installed?).'
        }
    }

    $tmpJson = Join-Path $env:TEMP ('osync-winget-export-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        & $WingetExePath export -o $tmpJson --include-versions --accept-source-agreements 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Get-OSyncInstalledWinget: winget export failed with exit code $LASTEXITCODE."
        }

        $obj = $null
        try {
            $obj = Get-Content -LiteralPath $tmpJson -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            throw "Get-OSyncInstalledWinget: failed to parse winget export JSON '$tmpJson': $($_.Exception.Message)"
        }

        $packages = @()
        if ($null -ne $obj.Sources) {
            foreach ($source in @($obj.Sources)) {
                if ($null -eq $source -or $null -eq $source.Packages) { continue }
                foreach ($pkg in @($source.Packages)) {
                    if ($null -eq $pkg) { continue }
                    $id = [string]$pkg.PackageIdentifier
                    if ([string]::IsNullOrWhiteSpace($id)) { continue }
                    $version = $null
                    if ($null -ne $pkg.Version) { $version = [string]$pkg.Version }
                    $packages += [pscustomobject]@{ Id = $id; Version = $version }
                }
            }
        }
        return $packages
    }
    finally {
        Remove-Item -LiteralPath $tmpJson -Force -ErrorAction SilentlyContinue
    }
}

function Get-OSyncInstalledPip {
    <#
    .SYNOPSIS
        Collects the installed pip packages via `python -m pip freeze`.

    .DESCRIPTION
        Resolves the python interpreter via Resolve-OSyncPython (override
        with -PythonPath for tests) and parses the `name==version` lines
        into @{ Name; Version } objects. Lines that do not match the
        pinned form (e.g. '-e ...', 'pkg @ file://...', bare names) are
        skipped with a Write-Warning - never a throw. A non-zero pip exit
        code throws with a clear message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$PythonPath
    )

    if ([string]::IsNullOrWhiteSpace($PythonPath)) {
        $PythonPath = Resolve-OSyncPython
    }

    $output = @(& $PythonPath -m pip freeze)
    if ($LASTEXITCODE -ne 0) {
        throw "Get-OSyncInstalledPip: 'pip freeze' failed with exit code $LASTEXITCODE."
    }

    $result = @()
    foreach ($line in $output) {
        $text = [string]$line
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '^([A-Za-z0-9][A-Za-z0-9._-]*)==(.+)$') {
            $result += [pscustomobject]@{ Name = $Matches[1]; Version = $Matches[2] }
        }
        else {
            Write-Warning "Get-OSyncInstalledPip: skipping non-pinned pip freeze line: '$text'"
        }
    }
    return $result
}

function Get-OSyncInstalledNpm {
    <#
    .SYNOPSIS
        Collects the installed global npm packages via `npm ls -g --depth=0 --json`.

    .DESCRIPTION
        Resolves npm from PATH (override with -NpmExe for tests) and parses
        the stdout JSON's dependencies object into @{ Name; Version }
        objects. npm ls may exit non-zero while still printing valid JSON -
        the stdout being parseable as JSON is the criterion; only a parse
        failure throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$NpmExe
    )

    if ([string]::IsNullOrWhiteSpace($NpmExe)) {
        $cmd = Get-Command npm -ErrorAction SilentlyContinue
        if ($null -eq $cmd) {
            throw "Get-OSyncInstalledNpm: 'npm' was not found on PATH."
        }
        $NpmExe = $cmd.Source
    }

    $output = @(& $NpmExe ls -g --depth=0 --json)
    $text = $output -join "`n"

    $obj = $null
    try {
        $obj = $text | ConvertFrom-Json
    }
    catch {
        throw "Get-OSyncInstalledNpm: 'npm ls -g --depth=0 --json' output is not valid JSON (exit $LASTEXITCODE): $($_.Exception.Message)"
    }

    $result = @()
    if ($null -ne $obj.dependencies) {
        foreach ($prop in $obj.dependencies.PSObject.Properties) {
            $name = [string]$prop.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $version = $null
            if ($null -ne $prop.Value -and $null -ne $prop.Value.version) { $version = [string]$prop.Value.version }
            $result += [pscustomobject]@{ Name = $name; Version = $version }
        }
    }
    return $result
}

function Get-OSyncInstalledBun {
    <#
    .SYNOPSIS
        Collects the installed global bun packages via `bun pm ls -g`.

    .DESCRIPTION
        Resolves bun from PATH (override with -BunExe for tests), runs
        `bun pm ls -g` and parses the tree output into @{ Name; Version }
        objects. The default (no --all) output lists TOP-LEVEL packages
        only - the same semantics as `npm ls -g --depth=0` (verified on
        bun 1.4.0: a global node_modules with 250 packages prints only its
        1 top-level entry).

        Output shape (bun 1.4.0):
          <global-dir> node_modules (<count>)     <- header line, skipped
          ├── name@version                        <- entry lines
          └── @scope/name@version

        Encoding gotcha: bun always writes the box-drawing prefix as UTF-8;
        under Windows PowerShell 5.1 the console OEM codepage (e.g. cp936
        on zh-CN) misdecodes it into CJK garbage. The parser therefore does
        NOT match the literal tree characters - an entry line is defined
        structurally as "any run of non-name decoration characters,
        followed by one npm-shaped spec" (anchored to the whole line, so
        the header path line with its ':' / '\' / '()' never matches).
        Name/version are split at the LAST '@' (scoped names start with
        '@' at index 0 and are handled); an entry without '@version'
        yields Version = $null. A non-zero exit code throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [string]$BunExe
    )

    if ([string]::IsNullOrWhiteSpace($BunExe)) {
        # -CommandType Application: an interactive session may define a
        # 'bun' alias/function (shell integrations do this) which shadows
        # the exe in a plain Get-Command; its .Source is EMPTY, and the
        # subsequent `& '' pm ls -g` then fails SILENTLY - module-scope
        # $ErrorActionPreference is Continue, a CommandNotFound error is
        # non-terminating, $LASTEXITCODE keeps its stale (passing) value,
        # and the run ends with an empty picker instead of an error.
        # (Observed 2026-09-09: a long-lived interactive session collected
        # 0 installed while a fresh session collected correctly.)
        $cmd = Get-Command bun -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $cmd -or [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
            throw "Get-OSyncInstalledBun: 'bun' was not found on PATH."
        }
        $BunExe = [string]$cmd.Source
    }

    # 2>&1: merge stderr as well - depending on the host's stream setup a
    # tool may emit its listing on stderr; non-entry lines are skipped by
    # the entry regex below, so the merge is harmless when stderr is empty.
    $output = @(& $BunExe pm ls -g 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Get-OSyncInstalledBun: 'bun pm ls -g' failed with exit code $LASTEXITCODE."
    }
    if ($output.Count -eq 0) {
        # Never fail silently: zero output means the invocation itself
        # broke (shadowed exe / host capture issue) - an empty GLOBAL
        # still prints its header line.
        throw "Get-OSyncInstalledBun: 'bun pm ls -g' produced no output (exit $LASTEXITCODE) - cannot collect the global package set."
    }

    # Normalize to clean single lines: native stderr items arrive as
    # ErrorRecord ([string] yields their message text), and an explicit
    # split survives any host that hands the output over unsplit.
    $lines = @()
    foreach ($item in $output) {
        foreach ($l in (([string]$item) -split "\r?\n")) {
            if (-not [string]::IsNullOrWhiteSpace($l)) { $lines += $l }
        }
    }

    $result = @()
    foreach ($text in $lines) {
        # Decoration = any leading run that is not an ASCII name char or
        # '@' (covers the UTF-8 tree prefix AND its OEM-misdecoded CJK
        # form). The spec itself is npm-shaped; the whole-line anchor
        # rejects the header path line and any warning text.
        if ($text -notmatch '^[^A-Za-z0-9@]*(@?[A-Za-z0-9._~-][A-Za-z0-9._~/-]*(?:@[A-Za-z0-9._~-][^\s@]*)?)\s*$') { continue }
        $spec = $Matches[1]
        $at = $spec.LastIndexOf('@')
        if ($at -gt 0) {
            $result += [pscustomobject]@{ Name = $spec.Substring(0, $at); Version = $spec.Substring($at + 1) }
        }
        else {
            # No '@version' (or a bare scoped name '@scope/name'): unpinned.
            $result += [pscustomobject]@{ Name = $spec; Version = $null }
        }
    }
    if ($result.Count -eq 0 -and $lines.Count -gt 1) {
        # More than just the header line, yet nothing parsed - suspicious;
        # surface the raw evidence instead of silently showing an empty
        # picker. (A truly empty global prints ONLY its header line.)
        Write-Warning "Get-OSyncInstalledBun: 'bun pm ls -g' printed $($lines.Count) line(s) but none parsed as a package entry; first line: '$($lines[0])'"
    }
    return $result
}

function ConvertFrom-OSyncSelectionText {
    <#
    .SYNOPSIS
        Pure function: parses the operator's selection input into a sorted,
        de-duplicated 1-based int[] of selected entry indexes.

    .DESCRIPTION
        Accepts 'all' / 'none' (case-insensitive), single numbers, comma
        separated lists and 'a-b' ranges (e.g. '1,3,5-8'). An empty or
        whitespace-only input returns $null (meaning "keep the current
        selection"). Invalid tokens, out-of-range indexes and inverted
        ranges (e.g. '7-3') throw with a clear message.

        PS 5.1 traps handled: 'none' returns a REAL empty array (return ,@()
        - a plain return @() would be unwrapped into $null), and 'all' with
        Count = 0 also returns an empty array (1..0 wrongly yields 1,0).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    if ($Count -lt 0) {
        throw "ConvertFrom-OSyncSelectionText: Count must be >= 0; got $Count."
    }

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }      # keep current selection

    $raw = $Text.Trim()

    # Case-insensitive keywords (PowerShell -eq is case-insensitive by default).
    if ($raw -eq 'all') {
        if ($Count -eq 0) { return ,@() }
        return @(1..$Count)
    }
    if ($raw -eq 'none') {
        return ,@()                                                # empty array, NOT $null
    }

    $result = @()
    foreach ($token in ($raw -split ',')) {
        $tok = $token.Trim()
        if ([string]::IsNullOrEmpty($tok)) {
            throw "ConvertFrom-OSyncSelectionText: empty selection token in '$Text' (check for stray commas)."
        }

        if ($tok -match '^(\d+)-(\d+)$') {
            $lo = [int]$Matches[1]
            $hi = [int]$Matches[2]
            if ($lo -gt $hi) {
                throw "ConvertFrom-OSyncSelectionText: inverted range '$tok' - start ($lo) is greater than end ($hi)."
            }
            if ($lo -lt 1 -or $hi -gt $Count) {
                throw "ConvertFrom-OSyncSelectionText: range '$tok' is out of range (valid: 1..$Count)."
            }
            $result += @($lo..$hi)
        }
        elseif ($tok -match '^\d+$') {
            $n = [int]$tok
            if ($n -lt 1 -or $n -gt $Count) {
                throw "ConvertFrom-OSyncSelectionText: index '$tok' is out of range (valid: 1..$Count)."
            }
            $result += $n
        }
        else {
            throw "ConvertFrom-OSyncSelectionText: invalid selection token '$tok' (expected numbers, 'a-b' ranges, 'all' or 'none')."
        }
    }

    return @($result | Sort-Object -Unique)
}

function Show-OSyncEntryPicker {
    <#
    .SYNOPSIS
        Interactively lets the operator pick which entries to write into
        the manifest.

    .DESCRIPTION
        Prints a numbered list (current state [x]/[ ] + index + display
        text) and asks for input. The input grammar is
        ConvertFrom-OSyncSelectionText: numbers / 'a-b' ranges / commas /
        'all' / 'none', or Enter to keep the current selection. Invalid
        input is warned about and re-asked until it parses. Returns a NEW
        array of entries, each carrying the extra boolean Selected property
        (Key / Display / Preselected / PinnedText are passed through).

        Hard-fails when the session is not interactive (e.g. a scheduled
        task): interactive selection is a console-only operation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        # AllowEmptyCollection: an empty candidate list (no installed
        # packages and no existing entries) must still reach the picker so
        # the operator can answer 'none' and leave the manifest untouched.
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Entries
    )

    if (-not [Environment]::UserInteractive) {
        throw "Show-OSyncEntryPicker: interactive selection requires an interactive console session (not available under a scheduled task or non-interactive session)."
    }

    Write-Host ''
    Write-Host "=== $Category - select entries to write into the manifest ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $state = if ($Entries[$i].Preselected) { '[x]' } else { '[ ]' }
        Write-Host ('{0} {1,3}  {2}' -f $state, ($i + 1), $Entries[$i].Display)
    }
    Write-Host "Enter numbers / ranges / comma lists (e.g. 1,3,5-8), 'all', 'none', or just Enter to keep the current selection:" -ForegroundColor Cyan

    $selected = $null
    while ($true) {
        $input = Read-Host "Selection [$Category]"
        try {
            $selected = ConvertFrom-OSyncSelectionText -Text $input -Count $Entries.Count
            break
        }
        catch {
            Write-Host "WARNING: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $result = @()
    for ($i = 0; $i -lt $Entries.Count; $i++) {
        $index = $i + 1
        $isSelected = $false
        if ($null -ne $selected) {
            $isSelected = ($index -in $selected)
        }
        else {
            # Enter pressed - keep the current selection.
            $isSelected = [bool]$Entries[$i].Preselected
        }
        $result += [pscustomobject]@{
            Key         = $Entries[$i].Key
            Display     = $Entries[$i].Display
            Preselected = [bool]$Entries[$i].Preselected
            PinnedText  = $Entries[$i].PinnedText
            Selected    = $isSelected
        }
    }

    return $result
}

function New-OSyncManifestCandidates {
    <#
    .SYNOPSIS
        Merges the installed packages with the existing manifest entries
        into the picker candidate list.

    .DESCRIPTION
        Candidates are ordered installed-first (collection order), then
        existing-only entries (file order). Matching is by Key,
        case-insensitive (winget/npm keys are lowercased Id/Name; pip keys
        are PEP 503 normalized names). Preselected = the Key exists in the
        existing manifest. Installed candidates are pinned to the installed
        version (winget 'Id@Version', pip 'name==version', npm
        'name@Version'); existing-only candidates keep their original line
        text verbatim as PinnedText and display ' (not installed)'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,

        # AllowEmptyCollection: an empty installed set / empty existing
        # manifest must bind (PS 5.1 rejects empty arrays on Mandatory
        # array parameters without this attribute).
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Installed,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Existing
    )

    $existingKeys = @{}
    foreach ($e in $Existing) { $existingKeys[$e.Key] = $true }

    $candidates = @()
    $seen = @{}
    foreach ($inst in $Installed) {
        $key = $null
        $pinned = $null
        if ($Category -eq 'winget') {
            $key = ([string]$inst.Id).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace([string]$inst.Version)) {
                $pinned = [string]$inst.Id
            }
            else {
                $pinned = "$($inst.Id)@$($inst.Version)"
            }
        }
        elseif ($Category -eq 'pip') {
            if ([string]::IsNullOrWhiteSpace([string]$inst.Version)) { continue }
            $key = ConvertTo-OSyncPep503Name -Name ([string]$inst.Name)
            $pinned = "$($inst.Name)==$($inst.Version)"
        }
        elseif ($Category -in @('npm', 'bun')) {
            # bun list format is identical to the npm list (README 4.5).
            $key = ([string]$inst.Name).ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace([string]$inst.Version)) {
                $pinned = [string]$inst.Name
            }
            else {
                $pinned = "$($inst.Name)@$($inst.Version)"
            }
        }
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $candidates += [pscustomobject]@{
            Key         = $key
            Display     = $pinned
            Preselected = $existingKeys.ContainsKey($key)
            PinnedText  = $pinned
        }
    }

    foreach ($e in $Existing) {
        if ($seen.ContainsKey($e.Key)) { continue }
        $seen[$e.Key] = $true
        $candidates += [pscustomobject]@{
            Key         = $e.Key
            Display     = "$($e.Text) (not installed)"
            Preselected = $true
            PinnedText  = $e.Text
        }
    }

    return $candidates
}

function Write-OSyncManifestGenerate {
    <#
    .SYNOPSIS
        Writes the selected entries back into the manifest file.

    .DESCRIPTION
        Target content: human comment lines ('#' prefix) in original order
        at the top + one blank line + the selected entries' PinnedText in
        order. When the target is line-for-line identical to the original,
        nothing is written and no backup is made - returns
        @{ Changed = $false; BackupPath = $null }. Otherwise the original
        file is first copied to '<Path>.bak-<yyyyMMddTHHmmssZ>' (UTC) and
        then rewritten as UTF-8 WITH BOM with CRLF line endings - returns
        @{ Changed = $true; BackupPath = <path> }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        # AllowEmptyCollection: a manifest with no comments / an empty
        # selection must bind (PS 5.1 rejects empty arrays on Mandatory
        # array parameters without this attribute).
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$SelectedEntries,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$CommentLines
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Write-OSyncManifestGenerate: manifest file not found: $Path"
    }

    $originalLines = @(Get-Content -LiteralPath $Path -Encoding UTF8)

    $targetLines = @()
    foreach ($c in $CommentLines) { $targetLines += [string]$c }
    if ($CommentLines.Count -gt 0) { $targetLines += '' }
    foreach ($e in $SelectedEntries) { $targetLines += [string]$e.PinnedText }

    $changed = ($targetLines.Count -ne $originalLines.Count)
    if (-not $changed) {
        for ($i = 0; $i -lt $originalLines.Count; $i++) {
            if ([string]$originalLines[$i] -ne [string]$targetLines[$i]) {
                $changed = $true
                break
            }
        }
    }

    if (-not $changed) {
        return [pscustomobject]@{ Changed = $false; BackupPath = $null }
    }

    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $backupPath = "$Path.bak-$stamp"
    Copy-Item -LiteralPath $Path -Destination $backupPath -Force

    $content = ($targetLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($true)))

    return [pscustomobject]@{ Changed = $true; BackupPath = $backupPath }
}

function Invoke-OSyncManifestGenerateCategory {
    <#
    .SYNOPSIS
        Runs the collect -> merge -> pick -> write-back flow for ONE
        category (winget / pip / npm / bun).

    .DESCRIPTION
        Returns @{ Selected = <int>; Changed = <bool>; BackupPath = <path
        or $null> }. A missing manifest file is treated as an empty
        existing manifest (first-generation scenario: every installed
        package starts unselected). An empty selection leaves the manifest
        untouched (Warning logged) - an empty requirements.txt would break
        the existing parsers, so an empty manifest is NEVER written.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$PathKey
    )

    $listPath = Resolve-OSyncConfigPath -Config $Config -Path $Config.paths.$PathKey
    if ([string]::IsNullOrWhiteSpace($listPath)) {
        throw "Invoke-OSyncManifestGenerate: config key 'paths.$PathKey' is empty."
    }

    # --- 1. collect the installed packages ---
    $installed = @()
    switch ($Category) {
        'winget' { $installed = @(Get-OSyncInstalledWinget) }
        'pip'    { $installed = @(Get-OSyncInstalledPip) }
        'npm'    { $installed = @(Get-OSyncInstalledNpm) }
        'bun'    { $installed = @(Get-OSyncInstalledBun) }
    }

    # --- 2. parse the existing manifest entries (missing file = empty existing manifest) ---
    $existing = @()
    $commentLines = @()
    $fileExists = Test-Path -LiteralPath $listPath -PathType Leaf
    if ($fileExists) {
        $originalLines = @(Get-Content -LiteralPath $listPath -Encoding UTF8)
        foreach ($line in $originalLines) {
            if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
            if (([string]$line).TrimStart().StartsWith('#')) { $commentLines += [string]$line }
        }
        switch ($Category) {
            'winget' {
                $parsed = @(Read-OSyncWingetList -Path $listPath)
                foreach ($p in $parsed) {
                    $raw = [string]$originalLines[$p.Line - 1]
                    $existing += [pscustomobject]@{ Key = $p.Id.ToLowerInvariant(); Text = $raw }
                }
            }
            'pip' {
                # No entry-level parser for requirements: classify line-wise.
                # Non-comment non-blank lines are entries; the match key is
                # the name before '==' (PEP 503 normalized); lines without
                # '==' use the whole trimmed line as the key.
                foreach ($line in $originalLines) {
                    $check = ([string]$line -split '#', 2)[0].Trim()
                    if ([string]::IsNullOrEmpty($check)) { continue }
                    $key = $null
                    if ($check -match '^([^=]+)==') {
                        $key = ConvertTo-OSyncPep503Name -Name $Matches[1].Trim()
                    }
                    else {
                        $key = ConvertTo-OSyncPep503Name -Name $check
                    }
                    $existing += [pscustomobject]@{ Key = $key; Text = [string]$line }
                }
            }
            'npm' {
                $parsed = @(Read-OSyncNpmList -Path $listPath)
                foreach ($p in $parsed) {
                    $raw = [string]$originalLines[$p.Line - 1]
                    $existing += [pscustomobject]@{ Key = $p.Name.ToLowerInvariant(); Text = $raw }
                }
            }
            'bun' {
                # bun list format is identical to the npm list (README 4.5).
                $parsed = @(Read-OSyncNpmList -Path $listPath)
                foreach ($p in $parsed) {
                    $raw = [string]$originalLines[$p.Line - 1]
                    $existing += [pscustomobject]@{ Key = $p.Name.ToLowerInvariant(); Text = $raw }
                }
            }
        }
    }

    # --- 3. merge into candidates (installed first, existing-only after) ---
    $candidates = @(New-OSyncManifestCandidates -Category $Category -Installed $installed -Existing $existing)
    Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: '$Category' collected $($installed.Count) installed, $($existing.Count) existing, $($candidates.Count) candidates." -Config $Config | Out-Null

    # --- 4. interactive picker ---
    $picked = @(Show-OSyncEntryPicker -Category $Category -Entries $candidates)
    $selected = @($picked | Where-Object { $_.Selected })
    Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: '$Category' operator selected $($selected.Count) of $($candidates.Count) entries." -Config $Config | Out-Null

    # --- 5. empty selection: leave the manifest untouched (never write an empty manifest) ---
    if ($selected.Count -eq 0) {
        Write-OSyncLog -Category 'export' -Level Warning -Message "manifest generate: '$Category' 该类别未选中任何条目，清单保持原样不动" -Config $Config | Out-Null
        return @{ Selected = 0; Changed = $false; BackupPath = $null }
    }

    # --- 6. write back (first generation: nothing to compare or back up) ---
    if (-not $fileExists) {
        $targetLines = @()
        foreach ($c in $commentLines) { $targetLines += [string]$c }
        if ($commentLines.Count -gt 0) { $targetLines += '' }
        foreach ($e in $selected) { $targetLines += [string]$e.PinnedText }
        $content = ($targetLines -join "`r`n") + "`r`n"
        [System.IO.File]::WriteAllText($listPath, $content, (New-Object System.Text.UTF8Encoding($true)))
        Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: '$Category' created '$listPath' with $($selected.Count) entries." -Config $Config | Out-Null
        return @{ Selected = $selected.Count; Changed = $true; BackupPath = $null }
    }

    $writeResult = Write-OSyncManifestGenerate -Path $listPath -SelectedEntries $selected -CommentLines $commentLines
    if ($writeResult.Changed) {
        Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: '$Category' wrote $($selected.Count) entries to '$listPath' (backup '$($writeResult.BackupPath)')." -Config $Config | Out-Null
    }
    else {
        Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: '$Category' unchanged - no rewrite of '$listPath'." -Config $Config | Out-Null
    }
    return @{ Selected = $selected.Count; Changed = $writeResult.Changed; BackupPath = $writeResult.BackupPath }
}

function Invoke-OSyncManifestGenerate {
    <#
    .SYNOPSIS
        Runs the interactive manifest generator for every requested category.

    .DESCRIPTION
        For each of winget/pip/npm/bun in $Category (other categories are
        ignored - dotfiles has no per-entry interaction) it resolves the
        manifest path via Resolve-OSyncConfigPath (paths.wingetWhitelist /
        paths.requirements / paths.npmList / paths.bunList), collects the
        installed packages, merges them with the existing manifest entries,
        shows the picker and writes the selection back. The bun category is
        presence-gated: it is skipped (Info log, not an error) when the
        config has no paths.bunList key. One category's failure (e.g.
        winget unavailable) is logged as Error and does not block the
        others.

        Returns a hashtable of category -> @{ Selected = <int>; Changed =
        <bool>; BackupPath = <path or $null> }. All Write-OSyncLog calls
        are piped to Out-Null (documented gotcha).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $false)]
        [string[]]$Category = @('winget', 'pip', 'npm')
    )

    $pathKeys = @{
        winget = 'wingetWhitelist'
        pip    = 'requirements'
        npm    = 'npmList'
        bun    = 'bunList'
    }

    Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: run starting (categories '$($Category -join ',')')." -Config $Config | Out-Null

    $result = @{}
    foreach ($cat in $Category) {
        if ($cat -notin @('winget', 'pip', 'npm', 'bun')) { continue }
        # bun is presence-gated: no paths.bunList = bun not enabled - skip
        # with an Info log instead of letting Resolve-OSyncConfigPath throw
        # on the $null path (an old config without the bun keys must not
        # turn an explicit -Category bun into an error).
        if ($cat -eq 'bun' -and [string]::IsNullOrWhiteSpace([string](Get-ONestedValue -Object $Config -Path 'paths.bunList'))) {
            Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: 'bun' skipped - config has no 'paths.bunList' (bun not enabled)." -Config $Config | Out-Null
            $result[$cat] = @{ Selected = 0; Changed = $false; BackupPath = $null }
            continue
        }
        try {
            $result[$cat] = Invoke-OSyncManifestGenerateCategory -Config $Config -Category $cat -PathKey $pathKeys[$cat]
        }
        catch {
            Write-OSyncLog -Category 'export' -Level Error -Message "manifest generate: category '$cat' FAILED: $($_.Exception.Message)" -Config $Config | Out-Null
            $result[$cat] = @{ Selected = 0; Changed = $false; BackupPath = $null }
        }
    }

    Write-OSyncLog -Category 'export' -Level Info -Message "manifest generate: run finished (categories '$($Category -join ',')')." -Config $Config | Out-Null
    return $result
}