#Requires -Version 5.1
<#
  State.ps1 - B-side idempotency state storage (dual stores).
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  WHY TWO STORES (Oracle r3-B1, elevation surface reduction):
    - SYSTEM store  <stateDir>\state\system-state.json  -> categories winget / pip / npm.
      Written only by SYSTEM/admin-privileged flows (machine-scope installs).
    - USER store    <stateDir>\run\user-state.json      -> category dotfiles.
      Writable by both principals (dotfiles apply may run as the logged-in user).

  Schemas (schemaVersion = 1):
    system: {"schemaVersion":1,"bootstrapped":false,"wingetExePath":null,
             "pythonExePath":null,"nodeExePath":null,"runtimeWingetHash":null,
             "runtimeFilesHash":null,
             "lastApplied":{"winget":null,"pip":null,"npm":null},
             "winget":{},"pip":{},"npm":{}}
    user:   {"schemaVersion":1,"lastApplied":{"dotfiles":null},"dotfiles":{}}

  IMPORTANT - exe-path fields (wingetExePath / pythonExePath / nodeExePath) are
  RECORD / DIAGNOSTIC ONLY. Consumers (todos 12-17) must re-derive executable
  paths on every run (e.g. Resolve-OSyncWingetExePath) and must NEVER execute a
  path read back from this state - anything that can live in a
  user-influenceable store is untrusted input.

  API (every function accepts -StateDir, or a -Config whose stateDir is used;
  nothing here ever touches the real C:\ProgramData\PakageSync unless told to):
    Get-OSyncState -Category <winget|pip|npm|dotfiles>
        Reads the category's store. Missing file -> fresh empty state (no
        warning). Unreadable/invalid -> rename to .bak, rebuild empty state,
        Write-Warning.
    Save-OSyncState -Category -State
        Atomic write: JSON to a temp file IN THE SAME DIRECTORY as the target,
        then Move-Item -Force. Within one volume Move-Item is a rename and is
        atomic; across volumes it degrades to copy+delete and loses atomicity,
        which is why the temp file is never created on another drive (Oracle m5).
    Test-OSyncCategoryNewer -Category -ExportedAtUtc
        $true when lastApplied.<cat> is null or earlier than -ExportedAtUtc.
        The fixed-width zero-padded 'yyyyMMddTHHmmssZ' format is validated and
        compared as an ordinal string, which IS chronological for this format
        (same rationale as the index.json exportedAtUtc, Oracle r7-2).
    Add-OSyncStateRecord -Category -Name -Version -Sha256
        Records {version, sha256} under <store>.<category>[<name>]. Does NOT
        touch lastApplied - only Set-OSyncLastApplied stamps a generation.
    Set-OSyncLastApplied -Category -ExportedAtUtc
        Stamps lastApplied.<category> after a successful apply run
        (todos 12-17 call it with the repository index.json exportedAtUtc).

  JSON contract: WRITE always via ConvertTo-OSyncJson (Util.ps1, todo 1).
  READ uses the JavaScriptSerializer pattern from the todo-3 repository
  contract (Add-Type -AssemblyName System.Web.Extensions, MaxJsonLength =
  int max - dodges the ~2MB ConvertFrom-Json cap of PS 5.1). Under pwsh 7 the
  assembly may load but fail at use time, so availability is proven with a
  trivial DeserializeObject('{}') probe and ConvertFrom-Json is the fallback.
  This choice is recorded in .omo\notepads\ab-one-way-sync\learnings.md.

  State updates are read-modify-write, NOT locked across processes. The
  apply pipeline is single-instance per machine by design; if that ever
  changes, a per-store lock file is the place to add serialisation.
#>

# ---- internal constants -----------------------------------------------------

# Category -> store name. winget/pip/npm live in the SYSTEM store, dotfiles in
# the USER store (dual-store design, Oracle r3-B1).
$script:OSyncCategoryStoreMap = @{
    'winget'   = 'System'
    'pip'      = 'System'
    'npm'      = 'System'
    'dotfiles' = 'User'
}

# JSON parser selection (see header). The JavaScriptSerializer path is only
# taken when it is PROVEN usable: pwsh 7 on Windows can GAC-load
# System.Web.Extensions but its types then fail at use time with
# "Could not load type 'System.Web.UI.WebResourceAttribute'" - a trivial
# DeserializeObject('{}') probe catches exactly that and falls back to
# ConvertFrom-Json (which has no 2MB cap on .NET Core). State files are tiny,
# so the PS 5.1 ConvertFrom-Json cap would not matter here anyway.
$script:OJsonParser = 'ConvertFromJson'
$script:OJsonSerializer = $null
try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $script:OJsonSerializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $script:OJsonSerializer.MaxJsonLength = [int]::MaxValue
    $null = $script:OJsonSerializer.DeserializeObject('{}')
    $script:OJsonParser = 'JavaScriptSerializer'
}
catch {
    $script:OJsonParser = 'ConvertFromJson'
}

# ---- private helpers --------------------------------------------------------

function New-OEmptyState {
    # Fresh, fully-populated empty schema. A factory (not a stored template)
    # so every caller gets an independent tree - no shared reference surprises.
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('System', 'User')]
        [string]$StoreName
    )

    if ($StoreName -eq 'System') {
        return [ordered]@{
            schemaVersion     = 1
            bootstrapped      = $false
            wingetExePath     = $null
            pythonExePath     = $null
            nodeExePath       = $null
            runtimeWingetHash = $null
            runtimeFilesHash  = $null
            lastApplied       = [ordered]@{ winget = $null; pip = $null; npm = $null }
            winget            = [ordered]@{}
            pip               = [ordered]@{}
            npm               = [ordered]@{}
        }
    }
    return [ordered]@{
        schemaVersion = 1
        lastApplied   = [ordered]@{ dotfiles = $null }
        dotfiles      = [ordered]@{}
    }
}

function Resolve-OStateDir {
    # Resolve the state root from whatever the caller supplied.
    param(
        [Parameter(Mandatory = $false)]
        [string]$StateDir,

        [Parameter(Mandatory = $false)]
        $Config
    )

    if (-not [string]::IsNullOrWhiteSpace($StateDir)) {
        return $StateDir
    }
    if ($null -ne $Config -and $null -ne $Config.stateDir -and -not [string]::IsNullOrWhiteSpace([string]$Config.stateDir)) {
        return ([string]$Config.stateDir)
    }
    throw "State.ps1: no state directory available - pass -StateDir or a -Config object with a stateDir property."
}

function Get-OStateStoreInfo {
    # Maps a category to its store name and on-disk path.
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('winget', 'pip', 'npm', 'dotfiles')]
        [string]$Category,

        [Parameter(Mandatory = $true)]
        [string]$StateDir
    )

    $storeName = $script:OSyncCategoryStoreMap[$Category]
    if ($storeName -eq 'System') {
        $path = Join-Path (Join-Path $StateDir 'state') 'system-state.json'
    }
    else {
        $path = Join-Path (Join-Path $StateDir 'run') 'user-state.json'
    }
    return [pscustomobject]@{ Name = $storeName; Path = $path }
}

function ConvertFrom-OJsonValue {
    # Normalises whatever the JSON parser produced into the SAME tree shape
    # New-OEmptyState builds: [ordered] dictionaries at every object level.
    # Both empty and loaded states then support the same dot/index access,
    # and the state schema contains no arrays, so array handling is
    # best-effort only.
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $dict = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $dict[[string]$key] = ConvertFrom-OJsonValue -Value $Value[$key]
        }
        return $dict
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $dict = [ordered]@{}
        foreach ($prop in $Value.PSObject.Properties) {
            $dict[$prop.Name] = ConvertFrom-OJsonValue -Value $prop.Value
        }
        return $dict
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $list = @()
        foreach ($item in $Value) {
            $list += (ConvertFrom-OJsonValue -Value $item)
        }
        return , $list
    }
    return $Value
}

function ConvertFrom-OJson {
    # Parse a JSON string into a normalised [ordered]-dictionary tree.
    # Throws on invalid JSON - callers translate that into corruption handling.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Raw
    )

    if ($script:OJsonParser -eq 'JavaScriptSerializer') {
        # MaxJsonLength = int max per the todo-3 repository contract; the
        # serializer only CAPS the allowed input length, it does not
        # pre-allocate it. The instance is reused from script scope.
        $parsed = $script:OJsonSerializer.DeserializeObject($Raw)
        return (ConvertFrom-OJsonValue -Value $parsed)
    }

    # pwsh 7 / .NET Core fallback: ConvertFrom-Json has no 2MB cap here.
    $parsed = $Raw | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    return (ConvertFrom-OJsonValue -Value $parsed)
}

function Read-OStateFile {
    # Read + validate a store file. Missing -> empty state (bootstrap).
    # Unreadable / invalid -> quarantine to .bak, rebuild empty, Write-Warning.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidateSet('System', 'User')]
        [string]$StoreName
    )

    # Bootstrap: a store that has never been written is simply an empty state;
    # the first apply run will populate and save it.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return (New-OEmptyState -StoreName $StoreName)
    }

    try {
        $parsed = ConvertFrom-OJson -Raw ([System.IO.File]::ReadAllText($Path))
        $valid = ($null -ne $parsed) -and
                 ($parsed -is [System.Collections.IDictionary]) -and
                 ($parsed['schemaVersion'] -eq 1) -and
                 ($parsed['lastApplied'] -is [System.Collections.IDictionary])
        if (-not $valid) {
            throw "schema validation failed (schemaVersion must be 1 and lastApplied must be an object)."
        }
        return $parsed
    }
    catch {
        # Corruption handling (plan todo 4): quarantine the bad file, rebuild
        # an empty state, and surface a warning so the operator sees it.
        $bak = "$Path.bak"
        Move-Item -LiteralPath $Path -Destination $bak -Force -ErrorAction SilentlyContinue
        Write-Warning ("State.ps1: store '{0}' is unreadable or invalid ({1}); it was renamed to '{2}' and an empty state was rebuilt." -f $Path, $_.Exception.Message, $bak)
        return (New-OEmptyState -StoreName $StoreName)
    }
}

function Write-OStateFileAtomic {
    # Serialize and atomically replace the store file.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        $State
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = ConvertTo-OSyncJson -InputObject $State

    # The temp file MUST live in the same directory as the target: Move-Item
    # within one volume is a rename and is atomic; across volumes it degrades
    # to copy + delete and the atomicity guarantee is lost (Oracle m5).
    $tmp = Join-Path $dir ('{0}.{1}.tmp' -f (Split-Path -Leaf $Path), [guid]::NewGuid().ToString('N'))
    try {
        # UTF-8 WITH BOM (house style, see learnings.md) - System.IO.File
        # writes it byte-exact, and the JavaScriptSerializer reader accepts it.
        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($tmp, $json, $utf8Bom)
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
    finally {
        # Never leave a stale temp file behind, even on failure.
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Assert-OExportedAtUtc {
    # Validate the 'yyyyMMddTHHmmssZ' basic-format UTC stamp BEFORE any
    # comparison; a strict format is what makes ordinal string comparison
    # chronological (Oracle r7-2).
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ExportedAtUtc
    )

    $styles = ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParseExact(
        $ExportedAtUtc,
        'yyyyMMddTHHmmssZ',
        [System.Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref]$parsed)
    if (-not $ok) {
        throw "State.ps1: exportedAtUtc '$ExportedAtUtc' is not in the expected 'yyyyMMddTHHmmssZ' (UTC) format."
    }
}

# ---- public API -------------------------------------------------------------

function Get-OSyncState {
    [CmdletBinding(DefaultParameterSetName = 'StateDir')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('winget', 'pip', 'npm', 'dotfiles')]
        [string]$Category,

        [Parameter(Mandatory = $true, ParameterSetName = 'StateDir')]
        [string]$StateDir,

        [Parameter(Mandatory = $true, ParameterSetName = 'Config')]
        $Config
    )

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        $resolved = Resolve-OStateDir -Config $Config
    }
    else {
        $resolved = Resolve-OStateDir -StateDir $StateDir
    }
    $store = Get-OStateStoreInfo -Category $Category -StateDir $resolved
    return (Read-OStateFile -Path $store.Path -StoreName $store.Name)
}

function Save-OSyncState {
    [CmdletBinding(DefaultParameterSetName = 'StateDir')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('winget', 'pip', 'npm', 'dotfiles')]
        [string]$Category,

        [Parameter(Mandatory = $true, Position = 1)]
        $State,

        [Parameter(Mandatory = $true, ParameterSetName = 'StateDir')]
        [string]$StateDir,

        [Parameter(Mandatory = $true, ParameterSetName = 'Config')]
        $Config
    )

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        $resolved = Resolve-OStateDir -Config $Config
    }
    else {
        $resolved = Resolve-OStateDir -StateDir $StateDir
    }
    $store = Get-OStateStoreInfo -Category $Category -StateDir $resolved
    Write-OStateFileAtomic -Path $store.Path -State $State
    return $store.Path
}

function Test-OSyncCategoryNewer {
    [CmdletBinding(DefaultParameterSetName = 'StateDir')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('winget', 'pip', 'npm', 'dotfiles')]
        [string]$Category,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ExportedAtUtc,

        [Parameter(Mandatory = $true, ParameterSetName = 'StateDir')]
        [string]$StateDir,

        [Parameter(Mandatory = $true, ParameterSetName = 'Config')]
        $Config
    )

    # Callers pass the exportedAtUtc straight from the repository index.json;
    # the strict format is asserted before it is trusted in a comparison.
    Assert-OExportedAtUtc -ExportedAtUtc $ExportedAtUtc

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        $state = Get-OSyncState -Category $Category -Config $Config
    }
    else {
        $state = Get-OSyncState -Category $Category -StateDir $StateDir
    }

    $last = $state.lastApplied[$Category]
    if ($null -eq $last) {
        # Never applied -> anything is newer.
        return $true
    }

    $styles = ([System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $lastParsed = [DateTime]::MinValue
    $lastOk = ($last -is [string]) -and [DateTime]::TryParseExact(
        [string]$last,
        'yyyyMMddTHHmmssZ',
        [System.Globalization.CultureInfo]::InvariantCulture,
        $styles,
        [ref]$lastParsed)
    if (-not $lastOk) {
        # A malformed marker cannot prove the category was applied; re-applying
        # is the safe direction for an idempotent one-way sync, so report
        # "newer" rather than skipping.
        Write-Warning ("State.ps1: lastApplied.{0} = '{1}' is malformed; treating the category as never applied." -f $Category, $last)
        return $true
    }

    # Both stamps are fixed-width zero-padded 'yyyyMMddTHHmmssZ' strings, so
    # an ordinal string comparison IS a chronological comparison.
    return ([string]::CompareOrdinal($ExportedAtUtc, [string]$last) -gt 0)
}

function Add-OSyncStateRecord {
    [CmdletBinding(DefaultParameterSetName = 'StateDir')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('winget', 'pip', 'npm', 'dotfiles')]
        [string]$Category,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Name,

        [Parameter(Mandatory = $true, Position = 2)]
        [AllowEmptyString()]
        [string]$Version,

        [Parameter(Mandatory = $true, Position = 3)]
        [AllowEmptyString()]
        [string]$Sha256,

        [Parameter(Mandatory = $true, ParameterSetName = 'StateDir')]
        [string]$StateDir,

        [Parameter(Mandatory = $true, ParameterSetName = 'Config')]
        $Config
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "State.ps1: Add-OSyncStateRecord requires a non-empty -Name."
    }

    # Read-modify-write of the category's store:
    #   <store>.<category>[<name>] = { version, sha256 }
    # lastApplied.<category> is deliberately NOT touched here - only
    # Set-OSyncLastApplied stamps a generation as applied (todos 12-17 call it
    # with the repo index exportedAtUtc once the whole category succeeded).
    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        $state = Get-OSyncState -Category $Category -Config $Config
    }
    else {
        $state = Get-OSyncState -Category $Category -StateDir $StateDir
    }

    # Defensive: a hand-edited store could hold a non-object table; replace it.
    if ($null -eq $state[$Category] -or $state[$Category] -isnot [System.Collections.IDictionary]) {
        $state[$Category] = [ordered]@{}
    }
    $state[$Category][$Name] = [ordered]@{
        version = $Version
        sha256  = $Sha256
    }

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        Save-OSyncState -Category $Category -State $state -Config $Config | Out-Null
    }
    else {
        Save-OSyncState -Category $Category -State $state -StateDir $StateDir | Out-Null
    }
    return $state[$Category][$Name]
}

function Set-OSyncLastApplied {
    [CmdletBinding(DefaultParameterSetName = 'StateDir')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateSet('winget', 'pip', 'npm', 'dotfiles')]
        [string]$Category,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ExportedAtUtc,

        [Parameter(Mandatory = $true, ParameterSetName = 'StateDir')]
        [string]$StateDir,

        [Parameter(Mandatory = $true, ParameterSetName = 'Config')]
        $Config
    )

    Assert-OExportedAtUtc -ExportedAtUtc $ExportedAtUtc

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        $state = Get-OSyncState -Category $Category -Config $Config
    }
    else {
        $state = Get-OSyncState -Category $Category -StateDir $StateDir
    }
    $state.lastApplied[$Category] = $ExportedAtUtc

    if ($PSCmdlet.ParameterSetName -eq 'Config') {
        return (Save-OSyncState -Category $Category -State $state -Config $Config)
    }
    return (Save-OSyncState -Category $Category -State $state -StateDir $StateDir)
}
