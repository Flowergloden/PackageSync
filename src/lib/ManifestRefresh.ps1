#Requires -Version 5.1
# Non-interactive refresh: the manifest remains the allowlist, never an inventory.
function Update-OSyncManifestVersions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('winget', 'pip', 'npm', 'bun')][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][array]$Installed
    )

    # Validate before writing; do not silently repair malformed input.
    switch ($Category) {
        'winget' { $null = Read-OSyncWingetList -Path $Path }
        'pip'    { $null = Read-OSyncRequirements -Path $Path }
        default  { $null = Read-OSyncNpmList -Path $Path }
    }
    $versions = @{}
    foreach ($package in $Installed) {
        $name = if ($Category -eq 'winget') { [string]$package.Id } else { [string]$package.Name }
        $version = [string]$package.Version
        if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version) -or
            $version -match '[\s@#;]' -or $version -eq 'unknown') { continue }
        $key = if ($Category -eq 'pip') { ConvertTo-OSyncPep503Name -Name $name } else { $name.ToLowerInvariant() }
        # Multiple installations with conflicting versions cannot safely be pinned.
        if ($versions.ContainsKey($key) -and $versions[$key] -ne $version) { $versions[$key] = $null }
        else { $versions[$key] = $version }
    }

    $original = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    # Retain each original newline, comments, indentation and final-newline state.
    $parts = [regex]::Split($original, '(\r\n|\n|\r)')
    $updated = 0
    # Hashes are tied to the old payload; leave hash-locked requirements untouched.
    $hashLocked = $Category -eq 'pip' -and $original -match '--hash(?:=|\s)'
    for ($i = 0; $i -lt $parts.Count; $i += 2) {
        $pattern = if ($Category -eq 'pip') {
            '^(?<indent>\s*)(?<name>[A-Za-z0-9][A-Za-z0-9._-]*)(?<extras>\[[^\]]+\])?(?:==[^\s;#*=]+)?(?<suffix>\s*(?:;[^#]*)?(?:#.*)?)$'
        } else {
            '^(?<indent>\s*)(?<name>@[^\s/@]+/[^\s@#]+|[^\s@#]+)(?:@[^\s#]+)?(?<suffix>\s*(?:#.*)?)$'
        }
        if ($hashLocked -or $parts[$i] -notmatch $pattern) { continue }
        $name = $Matches['name']
        $indent = $Matches['indent']
        $suffix = $Matches['suffix']
        $extras = $Matches['extras']
        $key = if ($Category -eq 'pip') { ConvertTo-OSyncPep503Name -Name $name } else { $name.ToLowerInvariant() }
        if (-not $versions.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$versions[$key])) { continue }
        $pin = if ($Category -eq 'pip') { "$name$extras==$($versions[$key])" } else { "$name@$($versions[$key])" }
        $line = "$indent$pin$suffix"
        if ($line -cne $parts[$i]) { $parts[$i] = $line; $updated++ }
    }
    $backupPath = $null
    if ($updated -gt 0) {
        $backupPath = "$Path.bak-$([datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N'))"
        Copy-Item -LiteralPath $Path -Destination $backupPath -ErrorAction Stop
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        [System.IO.File]::WriteAllText($Path, ($parts -join ''), (New-Object System.Text.UTF8Encoding($bom)))
    }
    return [pscustomobject]@{ Changed = ($updated -gt 0); Updated = $updated; BackupPath = $backupPath }
}

function Invoke-OSyncManifestRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][ValidateSet('winget', 'pip', 'npm', 'runtime')][string]$Category
    )

    $targets = switch ($Category) {
        'winget' { @{ Kind = 'winget'; PathKey = 'wingetWhitelist' } }
        'pip' { @{ Kind = 'pip'; PathKey = 'requirements' } }
        'npm' {
            @{ Kind = 'npm'; PathKey = 'npmList' }
            if (Test-OSyncBunEnabled -Config $Config) { @{ Kind = 'bun'; PathKey = 'bunList' } }
        }
        'runtime' { @{ Kind = 'winget'; PathKey = 'runtimeWhitelist' } }
    }
    foreach ($target in $targets) {
        $rawPath = [string](Get-ONestedValue -Object $Config -Path "paths.$($target.PathKey)")
        if ($target.Kind -eq 'bun' -and [string]::IsNullOrWhiteSpace($rawPath)) { continue }
        $path = Resolve-OSyncConfigPath -Config $Config -Path $rawPath
        if ($target.Kind -eq 'bun') {
            # Missing/empty bun lists are legal and do not require a local bun executable.
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if (@(Read-OSyncNpmList -Path $path).Count -eq 0) { continue }
        }
        Write-OSyncLog -Category 'export' -Level Info -Message "manifest refresh: '$Category' collecting installed $($target.Kind) versions for '$path'." -Config $Config | Out-Null
        $installed = switch ($target.Kind) {
            'winget' { Get-OSyncInstalledWinget }
            'pip' { Get-OSyncInstalledPip }
            'npm' { Get-OSyncInstalledNpm }
            'bun' { Get-OSyncInstalledBun }
        }
        $result = Update-OSyncManifestVersions -Path $path -Category $target.Kind -Installed @($installed)
        Write-OSyncLog -Category 'export' -Level Info -Message "manifest refresh: '$path' updated $($result.Updated) entries (backup '$($result.BackupPath)')." -Config $Config | Out-Null
    }
}
