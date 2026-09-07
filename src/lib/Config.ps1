#Requires -Version 5.1
<#
  Config.ps1 - configuration loading and validation for PakageSync.
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Get-OSyncConfig -Path <file> reads a packagesync JSON config and validates:
    - every required key is present and non-empty (the error names the key),
    - schemaVersion == 1, role is "A" or "B",
    - httpPort / verdaccioPort / npm.aVerdaccioPort are integers 1..65535,
    - categories.{winget,pip,npm,dotfiles} are booleans,
    - winget.scope in {machine,user}, winget.architecture in {x64,x86,arm64},
    - pip.downloadArgs is a non-empty array,
  and enforces the cross-field rule:
    categories.pip OR categories.npm enabled => categories.winget MUST be
    enabled (the runtime bootstrap payload - the Python/Node winget entries -
    lives under the winget category directory; Oracle m7 / Momus m6).
  Returns the parsed PSCustomObject with a DERIVED toolRoot NoteProperty
  (the parent of the config file's parent - the repo owning the operator
  manifests) stamped on it; Resolve-OSyncConfigPath resolves config.paths.*
  against that tool root (never config.repoRoot, the output landing dir).
#>

function Get-ONestedValue {
    # Walks a dotted path ("npm.aVerdaccioPort") on a PSCustomObject.
    # Returns $null when any segment is missing or the value is JSON null.
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $current = $Object
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $null }
        if ($current.PSObject.Properties.Name -notcontains $part) { return $null }
        $current = $current.$part
    }
    return $current
}

function Assert-OPort {
    param($Value, [string]$Key)
    $number = 0
    $ok = $false
    try {
        $number = [int]$Value
        $ok = $true
    }
    catch {
        $ok = $false
    }
    if (-not $ok -or $number -lt 1 -or $number -gt 65535) {
        throw "Get-OSyncConfig: config key '$Key' must be an integer port number in 1-65535; got '$Value'."
    }
}

function Get-OSyncConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Get-OSyncConfig: config file not found: '$Path'."
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $config = $null
    try {
        $config = $raw | ConvertFrom-Json
    }
    catch {
        throw "Get-OSyncConfig: config file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    # --- required keys (presence + non-empty strings) ---
    $requiredKeys = @(
        'schemaVersion', 'role', 'repoRoot', 'stagingRoot', 'httpBind',
        'httpPort', 'verdaccioPort', 'npm.aVerdaccioPort', 'stateDir',
        'winget.scope', 'winget.architecture',
        'pip.downloadArgs', 'pip.upgradeOnApply', 'pip.allowSdist',
        'paths.wingetWhitelist', 'paths.runtimeWhitelist', 'paths.requirements',
        'paths.npmList', 'paths.dotfilesSource',
        'pins.chezmoi.version', 'pins.chezmoi.url', 'pins.chezmoi.sha256',
        'pins.appInstaller.msixbundleUrl', 'pins.appInstaller.msixbundleSha256',
        'pins.appInstaller.vcLibsUrl', 'pins.appInstaller.vcLibsSha256',
        'pins.appInstaller.uiXamlUrl', 'pins.appInstaller.uiXamlSha256',
        'pins.appInstaller.vcRedistUrl', 'pins.appInstaller.vcRedistSha256',
        'pins.npm.verdaccioVersion'
    )
    foreach ($key in $requiredKeys) {
        $value = Get-ONestedValue -Object $config -Path $key
        if ($null -eq $value) {
            throw "Get-OSyncConfig: config '$Path' is missing required key '$key'."
        }
        if ($value -is [string] -and $value.Trim().Length -eq 0) {
            throw "Get-OSyncConfig: config key '$key' is empty."
        }
    }

    # --- categories: each must be a boolean ---
    foreach ($cat in @('winget', 'pip', 'npm', 'dotfiles')) {
        $value = Get-ONestedValue -Object $config -Path "categories.$cat"
        if ($null -eq $value -or $value -isnot [bool]) {
            throw "Get-OSyncConfig: config key 'categories.$cat' must be true or false; got '$value'."
        }
    }

    # --- schemaVersion / role ---
    if ($config.schemaVersion -ne 1) {
        throw "Get-OSyncConfig: config key 'schemaVersion' must be 1; got '$($config.schemaVersion)'."
    }
    if ($config.role -notin @('A', 'B')) {
        throw "Get-OSyncConfig: config key 'role' must be 'A' or 'B'; got '$($config.role)'."
    }

    # --- ports ---
    Assert-OPort -Value $config.httpPort -Key 'httpPort'
    Assert-OPort -Value $config.verdaccioPort -Key 'verdaccioPort'
    Assert-OPort -Value $config.npm.aVerdaccioPort -Key 'npm.aVerdaccioPort'

    # --- winget settings ---
    if ($config.winget.scope -notin @('machine', 'user')) {
        throw "Get-OSyncConfig: config key 'winget.scope' must be 'machine' or 'user'; got '$($config.winget.scope)'."
    }
    if ($config.winget.architecture -notin @('x64', 'x86', 'arm64')) {
        throw "Get-OSyncConfig: config key 'winget.architecture' must be one of x64/x86/arm64; got '$($config.winget.architecture)'."
    }

    # --- pip settings ---
    if ($config.pip.downloadArgs -isnot [System.Array] -or $config.pip.downloadArgs.Count -eq 0) {
        throw "Get-OSyncConfig: config key 'pip.downloadArgs' must be a non-empty array of strings."
    }
    if ($config.pip.upgradeOnApply -isnot [bool]) {
        throw "Get-OSyncConfig: config key 'pip.upgradeOnApply' must be true or false; got '$($config.pip.upgradeOnApply)'."
    }
    if ($config.pip.allowSdist -isnot [bool]) {
        throw "Get-OSyncConfig: config key 'pip.allowSdist' must be true or false; got '$($config.pip.allowSdist)'."
    }

    # --- cross-field rule: pip or npm => winget ---
    if (($config.categories.pip -or $config.categories.npm) -and -not $config.categories.winget) {
        throw "Get-OSyncConfig: config key 'categories.winget' must be enabled when 'categories.pip' or 'categories.npm' is enabled (the runtime bootstrap payload lives in the winget category directory)."
    }

    # --- stamp the derived tool root (path-resolution fix) ---
    # config.paths.* are operator-edited INPUT files living in the TOOL repo
    # (manifests\...), NOT in the output landing dir config.repoRoot. The tool
    # root is the parent of the config file's parent ('<toolRoot>\config\
    # packagesync.json'). It is DERIVED - never a JSON key - and added as a
    # NoteProperty so the export libs can resolve paths.* via
    # Resolve-OSyncConfigPath. No code path serializes the whole config
    # object, so the extra property cannot leak into any JSON artifact.
    $fullConfigPath = (Resolve-Path -LiteralPath $Path).Path
    $configDir = Split-Path -Parent $fullConfigPath
    $toolRoot = Split-Path -Parent $configDir
    if ([string]::IsNullOrWhiteSpace($toolRoot)) { $toolRoot = $configDir }
    $config | Add-Member -NotePropertyName toolRoot -NotePropertyValue $toolRoot -Force

    return $config
}

function Resolve-OSyncConfigPath {
    <#
      Resolves a config.paths.* value against the TOOL root - the repo that
      owns the operator-edited manifests (the parent of the config file's
      parent), NOT config.repoRoot (the output landing dir):
        - an absolute/rooted path is used verbatim,
        - a relative path is joined to $Config.toolRoot.
      $Config.toolRoot is stamped by Get-OSyncConfig (derived, never a JSON
      key); when absent (hand-rolled configs in tests) it falls back to this
      module's repo root (src\lib -> two levels up).
      Returns the resolved path string; existence is NOT required - callers
      decide what a missing file means.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Config,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }

    $toolRoot = $null
    if ($null -ne $Config) {
        $prop = $Config.PSObject.Properties['toolRoot']
        if ($null -ne $prop) { $toolRoot = [string]$prop.Value }
    }
    if ([string]::IsNullOrWhiteSpace($toolRoot)) {
        $toolRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
    }
    return (Join-Path $toolRoot $Path)
}
