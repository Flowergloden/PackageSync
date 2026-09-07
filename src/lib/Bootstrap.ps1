#Requires -Version 5.1
<#
  Bootstrap.ps1 - B-side runtime bootstrap (Install-OfflineBootstrap).
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncBootstrap -Config [-RepoRoot] [-WhatIf]
      Runs the whole bootstrap orchestration for the B side. The logic for
      every numbered step of plan todo 12 lives here; the entry script
      src\Install-OfflineBootstrap.ps1 only acquires the apply.lock, calls
      this function and maps the result to an exit code (the lock is taken
      ONLY by the entry scripts - todo 12 and todo 17 - never by lib flows,
      Momus r7-m3).

  Precondition:
      <repoRoot> must pass Test-OSyncRepoIntegrity for the runtime category
      AND for every enabled winget/npm category (a disabled category skips
      its requirement - Momus r4-m7). The required categories are then
      robocopied into <stateDir>\work\bootstrap\<exportedAtUtc>\ and EVERY
      file hash is RE-VERIFIED against the copied files.json (same work-copy
      semantics as the apply path, Momus M3 / Oracle M4). All subsequent
      reads use that work copy <bw>; under -WhatIf the repo root is read
      directly and nothing is written.

  Steps (0/1/2/3 only when categories.winget is enabled, 4 only when
  categories.npm is enabled, 5/6/7 always - Momus r4-m7 / m2):
      [0] Machine VC++ runtime: if the HKLM VC\Runtimes\x64 key exists it is
          skipped, otherwise <bw>\runtime\appinstaller\VC_redist.x64.exe
          /install /quiet /norestart runs (acceptable exit codes {0,3010,
          1638}, Oracle m8 - 3010 = reboot required, 1638 = another version
          already installed, both success).
      [1] App Installer: installed Microsoft.DesktopAppInstaller version >=
          payload msixbundle version skips the whole step; otherwise the
          VCLibs -> UI.Xaml -> msixbundle pieces are added IN ORDER, each
          with its own existence + sha256 check (against the verified work
          copy) AND its own version gate: installed identity version >=
          payload identity version skips that piece (Momus m7 / Oracle
          r5-m2 - the VCLibs version mismatch observed in todo-10 QA is
          handled by this gate: the OS-shipped 14.0.33728 >= payload
          14.0.33321 skips the piece). After the pieces, winget.exe is
          resolved (Resolve-OSyncWingetExePath, newest WindowsApps glob) and
          recorded into state.wingetExePath; an empty glob is an explicit
          error (Metis B1).
      [2] LocalManifestFiles, PER-USER semantics in BOTH contexts (Momus
          r3-M4 / Oracle r3-M5): enabled as the admin with
          `winget settings --enable LocalManifestFiles`, AND a ONE-SHOT
          SYSTEM scheduled task runs the same enable then deletes itself.
          QA EXEMPTION: if the admin context is already enabled, log + skip.
          Observed storage (todo-13 QA, winget v1.29.290): the setting lives
          in C:\ProgramData\Microsoft\WinGet\<SID>\settings\pkg\Microsoft
          .DesktopAppInstaller\admin_settings (key localManifestFiles); the
          sanctioned `winget settings --enable` command writes it and is
          verified via `winget settings export`. If enable + verify fails the
          bootstrap aborts with that location pinned in the message.
      [3] Start-OSyncHttpServer -Root <bw> (config.httpPort) then for each
          <bw>\runtime\runtime-winget.txt entry:
              winget install --manifest <staged manifest-only flat dir>
                  --scope <config.winget.scope> --architecture <config.winget.architecture>
                  --accept-package-agreements --accept-source-agreements
                  --disable-interactivity
          CRITICAL (todo-13 QA discovery): winget v1.29.290 `--manifest <dir>`
          REJECTS non-YAML files and subdirectories, so each package is
          staged manifest-only exactly like WingetApply.ps1 (reusing
          New-OSyncWingetManifestStaging). Source auto-update failures are
          logged only. Exit-code policy reuses $script:WingetSatisfiedExitCodes
          (READ-ONLY consumer, Winget.Common.ps1): 0/satisfied = ok, any
          other non-zero = the bootstrap FAILS and step 7 is never reached
          (Momus M3). After the installs the machine PATH is re-read and the
          resolved python.exe / node.exe are recorded into system-state
          (RECORD ONLY - apply re-derives every run, Oracle r3-B1). A
          runtime entry that was expected to install a tool which does not
          resolve afterwards is an explicit error (Oracle m9).
      [4] npm category: the portable Verdaccio payload lands locally
          (Invoke-OSyncRobocopy <bw>\runtime\verdaccio ->
          <stateDir>\verdaccio-bin /MIR and <bw>\npm -> <stateDir>\verdaccio
          /MIR - the config's relative ./storage resolves in place), then the
          resident scheduled task 'PakageSync-Verdaccio' is registered
          (SYSTEM, AtStartup, RestartCount=3 / RestartInterval=1min failure
          restart, Oracle m-4):
              <nodeExe> <stateDir>\verdaccio-bin\node_modules\verdaccio\bin\verdaccio
                  --config <stateDir>\verdaccio\verdaccio-b.yml
          and started; the registry is then waited for on
          127.0.0.1:<config.verdaccioPort> (30 s, Oracle M4 - the service
          only ever reads the LOCAL copy, never the sync dirs). Task name is
          injectable (-VerdaccioTaskName) so QA uses a temp-named task.
      [5] stateDir layout + ACLs (Oracle r3-B1 / M4): bootstrap explicitly
          creates state\ (SYSTEM/admins RW, Users read-only), run\ (both
          principals modify - apply.lock, user-state.json, chezmoistate.boltdb,
          logs\), bin\ (SYSTEM/admins write, Users RX - launch-apply.ps1,
          Momus r6-B1), work\, verdaccio\, verdaccio-bin\ (SYSTEM/admins
          exclusive, Users read-only). Pre-existing dirs are icacls /reset
          first, then the grants are re-applied; an unexpected OWNER aborts
          (CREATOR OWNER pre-create poisoning, Oracle r3-M4). The <repoRoot>
          ACL is checked for Users readability (warning only, never changed).
      [6] Tool landing: Invoke-OSyncRobocopy <bw>\runtime\tool ->
          C:\PakageSync /MIR /XD config (the config dir is EXCLUDED - the B
          side owns its config; packagesync.b.json is copied to
          C:\PakageSync\config\packagesync.json ONLY when that file does not
          exist yet, so a re-bootstrap never resets local config, Momus
          r3-B1). C:\PakageSync + .new/.old are hardened (explicit create +
          icacls /reset + owner check, abort on unexpected owner) and the
          one-shot micro launcher <stateDir>\bin\launch-apply.ps1 is placed
          (never renamed, SYSTEM/admin-writable Users-RX bin\, Momus r6-B1;
          it self-heals the current/.new/.old family, Oracle r7-6).
      [7] state.bootstrapped = $true (system store) - only after every
          enabled step succeeded; diagnostic fields wingetExePath /
          pythonExePath / nodeExePath / runtimeWingetHash / runtimeFilesHash
          are recorded too.

  Every step is detect-then-execute (idempotent). Each step function returns
  a step-result object { Step, Status ('skipped'|'done'|'failed'), Message,
  Data } that the orchestrator logs with Write-OSyncLog (always | Out-Null -
  Write-OSyncLog RETURNS the JSONL path, learnings.md).

  The apply.lock helpers (Test-OSyncAcquireBootstrapLock /
  Remove-OSyncBootstrapLock) implement the shared <stateDir>\run\apply.lock
  contract (File.CreateNew atomic; holder writes PID + timestamp; stale >2 h
  or future timestamp (>now+5 min) is broken + logged; else wait max 60 s
  then skip - Momus m6). The lock is acquired ONLY by the entry scripts.

  Must NOT (todo 12): register PakageSync-Apply-* (todo 17); modify the
  registry / group policy; execute any exe path read back from state (all
  paths are re-derived this run).
#>

# ---- internal constants -----------------------------------------------------

# VC_redist acceptable exit codes (Oracle m8): 0 success, 3010 success +
# reboot required, 1638 another/newer version already installed.
$script:OSyncVcRedistAcceptableExitCodes = @(0, 3010, 1638)

# JSON reader probe: identical strategy to State.ps1 / RepoContract.ps1
# (JavaScriptSerializer on PS 5.1 dodges the ~2 MB ConvertFrom-Json cap;
# pwsh 7 falls back to ConvertFrom-Json).
$script:OBootstrapJsonParser = 'ConvertFromJson'
$script:OBootstrapJsonSerializer = $null
try {
    Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop
    $probe = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $probe.MaxJsonLength = [int]::MaxValue
    $null = $probe.DeserializeObject('{}')
    $script:OBootstrapJsonParser = 'JavaScriptSerializer'
    $script:OBootstrapJsonSerializer = $probe
}
catch {
    $script:OBootstrapJsonParser = 'ConvertFromJson'
}

# ---- private helpers --------------------------------------------------------

function ConvertFrom-OSyncBootstrapJson {
    # Parse JSON text (same availability probe as State.ps1). Throws on
    # invalid JSON. Both branches yield IDictionary-compatible trees so every
    # downstream check (-is [IDictionary], .ContainsKey, .GetEnumerator())
    # works uniformly: JS serializer on PS 5.1, ConvertFrom-Json -AsHashtable
    # on pwsh 7 (same choice as RepoContract.ps1).
    param([Parameter(Mandatory = $true)][string]$Text)
    if ($script:OBootstrapJsonParser -eq 'JavaScriptSerializer') {
        return $script:OBootstrapJsonSerializer.DeserializeObject($Text)
    }
    return ($Text | ConvertFrom-Json -AsHashtable -Depth 100 -ErrorAction Stop)
}

function New-OSyncBootstrapStepResult {
    param(
        [Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][ValidateSet('skipped', 'done', 'failed')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        $Data = $null
    )
    return [pscustomobject]@{ Step = $Step; Status = $Status; Message = $Message; Data = $Data }
}

function Get-OSyncBootstrapManifestEntry {
    # Reads ONE relative-path entry (sha256) out of a files.json. Returns
    # $null when the entry is absent.
    param(
        [Parameter(Mandatory = $true)][string]$FilesJsonPath,
        [Parameter(Mandatory = $true)][string]$RelPath
    )
    $manifest = ConvertFrom-OSyncBootstrapJson -Text ([System.IO.File]::ReadAllText($FilesJsonPath))
    if ($null -eq $manifest) { return $null }
    if ($manifest -is [System.Collections.IDictionary]) {
        $normKey = $RelPath.Replace('\', '/')
        foreach ($key in $manifest.Keys) {
            if ([string]$key -eq $normKey) {
                $entry = $manifest[$key]
                if ($entry -is [System.Collections.IDictionary]) {
                    return [pscustomobject]@{
                        Sha256 = ([string]$entry['sha256'])
                        Bytes  = $entry['bytes']
                    }
                }
                return $null
            }
        }
    }
    return $null
}

function Get-OSyncInstalledAppxVersion {
    # Highest installed version of an Appx package by Identity Name, or $null.
    param([Parameter(Mandatory = $true)][string]$PackageName)
    $pkgs = @(Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue)
    if ($pkgs.Count -eq 0) { return $null }
    $best = $null
    foreach ($p in $pkgs) {
        $v = $null
        try { $v = [version]$p.Version } catch { $v = $null }
        if ($null -ne $v) {
            if ($null -eq $best -or $v -gt $best) { $best = $v }
        }
    }
    if ($null -eq $best) { return $null }
    return $best
}

function Test-OSyncTrustedDirOwner {
    # True when the directory owner is SYSTEM, BUILTIN\Administrators, or a
    # member of the local Administrators group. This is the anti-poisoning
    # gate (Oracle r3-M4): an unprivileged user who pre-creates a directory
    # becomes its owner and must fail the check.
    param([Parameter(Mandatory = $true)][string]$Dir)
    $owner = $null
    try { $owner = (Get-Acl -LiteralPath $Dir -ErrorAction Stop).Owner } catch { return $false }
    try {
        $ownerSid = (New-Object System.Security.Principal.NTAccount($owner)).Translate([System.Security.Principal.SecurityIdentifier])
    }
    catch { return $false }
    $sidValue = $ownerSid.Value
    if ($sidValue -eq 'S-1-5-18' -or $sidValue -eq 'S-1-5-32-544') { return $true }
    $admins = @(Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue)
    foreach ($a in $admins) {
        if ($a.SID -eq $sidValue) { return $true }
    }
    return $false
}

function Invoke-OSyncBootstrapGrantAcl {
    # Applies the fixed per-role grants to a directory using SID-based icacls
    # (localization-proof). 0x1200a9 = (OI)(CI)RX, 0x1200bf = (OI)(CI)M.
    param(
        [Parameter(Mandatory = $true)][string]$Dir,
        [Parameter(Mandatory = $true)][ValidateSet('SystemAdminsRead', 'UsersModify', 'SystemAdminsRWUsersRX')][string]$Policy
    )
    $sids = @('*S-1-5-18', '*S-1-5-32-544')   # SYSTEM, Administrators
    $users = '*S-1-5-32-545'                    # Users
    $inherit = '(OI)(CI)'
    switch ($Policy) {
        'SystemAdminsRead'   { $argsList = @($Dir, '/inheritance:r', "/grant:r", "$($sids[0]):$($inherit)F", "/grant:r", "$($sids[1]):$($inherit)F", "/grant:r", "$($users):$($inherit)RX") }
        'UsersModify'        { $argsList = @($Dir, '/inheritance:r', "/grant:r", "$($sids[0]):$($inherit)M", "/grant:r", "$($sids[1]):$($inherit)M", "/grant:r", "$($users):$($inherit)M") }
        'SystemAdminsRWUsersRX' { $argsList = @($Dir, '/inheritance:r', "/grant:r", "$($sids[0]):$($inherit)M", "/grant:r", "$($sids[1]):$($inherit)M", "/grant:r", "$($users):$($inherit)RX") }
    }
    # icacls on a just-created dir first /reset to strip inherited ACEs, then
    # apply the explicit grants. /grant:r replaces, so re-running is a no-op.
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = @(& icacls.exe $Dir /reset 2>&1)
        $null = @(& icacls.exe @argsList 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldEap }
    if ($code -ne 0) {
        throw "Bootstrap.ps1: icacls failed (exit $code) hardening '$Dir'."
    }
}

# ---- lock helpers (entry-script only consumers) -----------------------------

function Test-OSyncAcquireBootstrapLock {
    <#
      Acquires <stateDir>\run\apply.lock atomically (File.CreateNew). The
      holder writes 'PID=<pid> TIMESTAMP=<ISO8601-UTC>'. Returns $true when
      acquired. Stale lock (>2 h) or a future timestamp (>now+5 min) is
      broken + logged, then retried. Otherwise waits up to -TimeoutSeconds
      and returns $false (the caller skips the run). Callers: ONLY the entry
      scripts (Install-OfflineBootstrap / Invoke-OfflineApply), never lib
      flows (Momus r7-m3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter(Mandatory = $false)][int]$TimeoutSeconds = 60
    )
    $runDir = Join-Path $StateDir 'run'
    if (-not (Test-Path -LiteralPath $runDir -PathType Container)) {
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    }
    $lockPath = Join-Path $runDir 'apply.lock'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try {
                $content = 'PID={0} TIMESTAMP={1}' -f $PID, [DateTime]::UtcNow.ToString('o')
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
            return $true
        }
        catch {
            # Lock exists: decide stale-break or wait.
            $stale = $false
            try {
                $raw = [System.IO.File]::ReadAllText($lockPath)
                $m = [regex]::Match($raw, 'TIMESTAMP=([^\s]+)')
                if ($m.Success) {
                    $ts = [DateTime]::MinValue
                    if ([DateTime]::TryParse([string]$m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ts)) {
                        $age = ([DateTime]::UtcNow - $ts.ToUniversalTime())
                        if ($age.TotalHours -gt 2) { $stale = $true }
                        if ($age.TotalMinutes -lt -5) { $stale = $true }   # future timestamp (>now+5min)
                    }
                }
            }
            catch { $stale = $true }   # unreadable lock -> treat as stale
            if ($stale) {
                Write-Warning "Bootstrap.ps1: breaking stale apply.lock at '$lockPath' (owned by another process or poisoned)."
                Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
                continue
            }
            if ([DateTime]::UtcNow -ge $deadline) {
                Write-Warning "Bootstrap.ps1: apply.lock at '$lockPath' is held by another apply/bootstrap - giving up after $TimeoutSeconds s."
                return $false
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Remove-OSyncBootstrapLock {
    <#
      Releases the apply.lock - but ONLY when this process still owns it
      (the content PID matches $PID), so a lock taken over after our own
      acquisition is never deleted by us.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir)
    $lockPath = Join-Path (Join-Path $StateDir 'run') 'apply.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($lockPath)
        if ($raw -match "PID=$PID\s") {
            Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch { }
}

# ---- precondition: integrity + work copy ------------------------------------

function Test-OSyncBootstrapRepoCategories {
    <#
      Runs Test-OSyncRepoIntegrity and asserts the REQUIRED categories are OK.
      Required = runtime + (winget when categories.winget) + (npm when
      categories.npm). A category disabled in config skips its requirement
      (Momus r4-m7). Returns the integrity result; throws on 'Invalid' or a
      required category not 'OK'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    $integrity = Test-OSyncRepoIntegrity -RepoRoot $RepoRoot
    if ($integrity.Overall -eq 'Invalid') {
        throw "Install-OfflineBootstrap: repository trust root is INVALID: $($integrity.IndexError)"
    }
    $required = @('runtime')
    if ([bool]$Config.categories.winget) { $required += 'winget' }
    if ([bool]$Config.categories.npm) { $required += 'npm' }
    foreach ($cat in $required) {
        $catResult = $null
        if ($integrity.Categories.ContainsKey($cat)) { $catResult = $integrity.Categories[$cat] }
        if ($null -eq $catResult) {
            throw "Install-OfflineBootstrap: required category '$cat' is absent from the repository index."
        }
        if ($catResult.Status -ne 'OK') {
            $reason = if ($null -ne $catResult.Reason) { $catResult.Reason } else { "status '$($catResult.Status)'" }
            $corrupt = @($catResult.CorruptFiles)
            $missing = @($catResult.MissingFiles)
            $detail = ''
            if ($corrupt.Count -gt 0) { $detail += " corrupt: $($corrupt -join ', ')" }
            if ($missing.Count -gt 0) { $detail += " missing: $($missing -join ', ')" }
            throw ("Install-OfflineBootstrap: required category '{0}' failed repository integrity ({1}){2}." -f $cat, $reason, $detail)
        }
    }
    return $integrity
}

function New-OSyncBootstrapWorkCopy {
    <#
      Robocopies the required categories (runtime + enabled winget/npm) into
      <stateDir>\work\bootstrap\<exportedAtUtc>\. Returns the work copy root
      <bw>. Callers pipe Invoke-OSyncRobocopy to Out-Null (it returns the
      robocopy exit code - leak class, learnings.md).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$ExportedAtUtc
    )
    $bootstrapRoot = Join-Path (Join-Path $Config.stateDir 'work') 'bootstrap'
    $bw = Join-Path $bootstrapRoot $ExportedAtUtc
    if (Test-Path -LiteralPath $bw -PathType Container) {
        Remove-Item -LiteralPath $bw -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path $bw -Force | Out-Null
    foreach ($cat in @('runtime', 'winget', 'npm')) {
        $src = Join-Path $RepoRoot $cat
        # Dynamic property access (PSCustomObject ['name'] indexing is NOT
        # reliable across shells - observed empty under pwsh in this QA).
        $enabled = $cat -eq 'runtime' -or [bool]$Config.categories.$cat
        if ($enabled -and (Test-Path -LiteralPath $src -PathType Container)) {
            Invoke-OSyncRobocopy -Source $src -Destination (Join-Path $bw $cat) -ExtraArgs @('/E') | Out-Null
        }
    }
    return $bw
}

function Test-OSyncBootstrapWorkCopy {
    <#
      RE-VERIFIES the work copy: for every copied category, files.json is
      parsed and every listed file's sha256 (and byte count) is recomputed
      and compared - the same trust semantics as the apply path (Momus
      M3/Oracle M4). Returns $true when every category verifies; throws with
      details otherwise (the caller then deletes the generation - a bad
      generation must never be kept as "newest", Momus r4-B1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Bw
    )
    $bad = @()
    foreach ($cat in @('runtime', 'winget', 'npm')) {
        $catDir = Join-Path $Bw $cat
        if (-not (Test-Path -LiteralPath $catDir -PathType Container)) { continue }
        $filesJson = Join-Path $catDir 'files.json'
        if (-not (Test-Path -LiteralPath $filesJson -PathType Leaf)) {
            $bad += "${cat}: files.json missing in work copy"
            continue
        }
        $manifest = ConvertFrom-OSyncBootstrapJson -Text ([System.IO.File]::ReadAllText($filesJson))
        if ($null -eq $manifest -or -not ($manifest -is [System.Collections.IDictionary])) {
            $bad += "${cat}: files.json not a JSON object"
            continue
        }
        foreach ($entry in $manifest.GetEnumerator()) {
            $rel = [string]$entry.Key
            $meta = $entry.Value
            if ($meta -isnot [System.Collections.IDictionary]) { $bad += "${cat}/${rel}: malformed manifest entry"; continue }
            $filePath = Join-Path $catDir $rel
            if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { $bad += "${cat}/${rel}: missing"; continue }
            if ($meta.ContainsKey('bytes')) {
                try {
                    if ((Get-Item -LiteralPath $filePath -Force).Length -ne [int64]$meta['bytes']) { $bad += "${cat}/${rel}: byte-count mismatch"; continue }
                }
                catch { $bad += "${cat}/${rel}: unreadable"; continue }
            }
            if ($meta.ContainsKey('sha256')) {
                $expected = [string]$meta['sha256']
                if ((Get-OSyncFileSha256 -Path $filePath) -ne $expected) { $bad += "${cat}/${rel}: sha256 mismatch" }
            }
        }
    }
    if ($bad.Count -gt 0) {
        throw ("Bootstrap.ps1: work copy re-verification FAILED for {0} file(s): {1}" -f $bad.Count, ($bad -join '; '))
    }
    return $true
}

# ---- step 0: machine VC++ runtime -------------------------------------------

function Invoke-OSyncBootstrapStepVcRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Root,
        # Test seam: point at a fake VC_redist (a .cmd) so the exit-code
        # policy can be exercised without elevation. Production derives the
        # real payload path from the work copy.
        [Parameter(Mandatory = $false)][string]$VcRedistExe,
        # Test seam: override the registry-key presence decision (avoids
        # mocking Test-Path in unit tests). Production derives it from the
        # real HKLM key.
        [Parameter(Mandatory = $false)][bool]$VcRuntimePresent,
        [switch]$WhatIf
    )
    $key = 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64'
    $present = if ($PSBoundParameters.ContainsKey('VcRuntimePresent')) { $VcRuntimePresent } else { (Test-Path -LiteralPath $key) }
    if ($present) {
        return (New-OSyncBootstrapStepResult -Step '0-vcruntime' -Status 'skipped' -Message "VC++ runtime present (registry key '$key') - skipping VC_redist.")
    }
    $redist = $VcRedistExe
    if ([string]::IsNullOrWhiteSpace($redist)) {
        $redist = Join-Path $Root 'runtime\appinstaller\VC_redist.x64.exe'
    }
    if (-not (Test-Path -LiteralPath $redist -PathType Leaf)) {
        throw "Bootstrap.ps1 step 0: VC_redist.x64.exe not found in the work copy ('$redist') but the VC runtime is missing."
    }
    if ($WhatIf) {
        return (New-OSyncBootstrapStepResult -Step '0-vcruntime' -Status 'done' -Message "WhatIf: would run VC_redist.x64.exe /install /quiet /norestart (VC runtime key absent)." -Data @{ Redist = $redist })
    }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = @(& $redist /install /quiet /norestart 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldEap }
    if ($script:OSyncVcRedistAcceptableExitCodes -notcontains $code) {
        throw "Bootstrap.ps1 step 0: VC_redist.x64.exe failed with exit code $code (acceptable: $($script:OSyncVcRedistAcceptableExitCodes -join ', '))."
    }
    return (New-OSyncBootstrapStepResult -Step '0-vcruntime' -Status 'done' -Message "VC_redist.x64.exe completed (exit $code)." -Data @{ ExitCode = $code })
}

# ---- step 1: App Installer pieces + winget.exe ------------------------------

function Get-OSyncAppxIdentity {
    # Reads Identity {Name, Version} from an .appx/.msix (AppxManifest.xml at
    # the zip root). Throws when unreadable.
    param([Parameter(Mandatory = $true)][string]$AppxPath)
    $manifest = Read-OSyncZipEntryText -ZipPath $AppxPath -EntryName 'AppxManifest.xml'
    if ($null -eq $manifest) { throw "Bootstrap.ps1: no AppxManifest.xml inside '$AppxPath'." }
    $nameM = [regex]::Match($manifest, '<Identity\b[^>]*\bName="([^"]+)"')
    $verM = [regex]::Match($manifest, '<Identity\b[^>]*\bVersion="([^"]+)"')
    if (-not $nameM.Success -or -not $verM.Success) {
        throw "Bootstrap.ps1: cannot parse Identity Name/Version from '$AppxPath'."
    }
    return [pscustomobject]@{ Name = $nameM.Groups[1].Value; Version = $verM.Groups[1].Value }
}

function Get-OSyncBundleIdentity {
    # Reads Identity {Name, Version} from an App Installer msixbundle (the
    # manifest may live inside the inner x64 msix - Get-OSyncBundleManifestText
    # handles both layouts, todo-10 QA).
    param([Parameter(Mandatory = $true)][string]$BundlePath)
    $manifest = Get-OSyncBundleManifestText -BundlePath $BundlePath
    if ($null -eq $manifest) { throw "Bootstrap.ps1: no AppxManifest.xml found in the msixbundle '$BundlePath'." }
    $nameM = [regex]::Match($manifest, '<Identity\b[^>]*\bName="([^"]+)"')
    $verM = [regex]::Match($manifest, '<Identity\b[^>]*\bVersion="([^"]+)"')
    if (-not $nameM.Success -or -not $verM.Success) {
        throw "Bootstrap.ps1: cannot parse Identity Name/Version from the msixbundle '$BundlePath'."
    }
    return [pscustomobject]@{ Name = $nameM.Groups[1].Value; Version = $verM.Groups[1].Value }
}

function Get-OSyncAppInstallerDecisions {
    <#
      Builds the per-piece install decisions for step 1:
        piece = 'vclibs' | 'uixaml' | 'msixbundle'
        File, PayloadName, PayloadVersion, InstalledVersion, InstallNeeded
      Every piece must exist AND its sha256 must match the verified work
      copy's runtime files.json (existence + sha256 check before
      Add-AppxPackage). The version gate (Momus m7 / Oracle r5-m2): a piece
      whose installed identity version >= payload version is skipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $appInstallerDir = Join-Path $Root 'runtime\appinstaller'
    if (-not (Test-Path -LiteralPath $appInstallerDir -PathType Container)) {
        throw "Bootstrap.ps1 step 1: runtime\appinstaller missing in '$Root' (runtime category incomplete)."
    }
    $filesJson = Join-Path $Root 'runtime\files.json'
    if (-not (Test-Path -LiteralPath $filesJson -PathType Leaf)) {
        throw "Bootstrap.ps1 step 1: runtime\files.json missing - cannot verify the appInstaller pieces."
    }

    $pieces = @(
        [pscustomobject]@{ Piece = 'vclibs'; File = 'Microsoft.VCLibs.x64.14.00.Desktop.appx'; Bundle = $false },
        [pscustomobject]@{ Piece = 'uixaml'; File = 'Microsoft.UI.Xaml.2.8.appx'; Bundle = $false },
        [pscustomobject]@{ Piece = 'msixbundle'; File = 'Microsoft.DesktopAppInstaller.msixbundle'; Bundle = $true }
    )

    $decisions = @()
    foreach ($piece in $pieces) {
        $path = Join-Path $appInstallerDir $piece.File
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Bootstrap.ps1 step 1: appInstaller piece '$($piece.File)' not found at '$path'."
        }
        $actualHash = Get-OSyncFileSha256 -Path $path
        $expected = Get-OSyncBootstrapManifestEntry -FilesJsonPath $filesJson -RelPath ('appinstaller/' + $piece.File)
        if ($null -ne $expected -and $expected.Sha256 -ne $actualHash) {
            throw ("Bootstrap.ps1 step 1: appInstaller piece '{0}' sha256 mismatch (files.json '{1}' vs actual '{2}')." -f $piece.File, $expected.Sha256, $actualHash)
        }
        $identity = if ($piece.Bundle) {
            Get-OSyncBundleIdentity -BundlePath $path
        }
        else {
            Get-OSyncAppxIdentity -AppxPath $path
        }
        $installed = Get-OSyncInstalledAppxVersion -PackageName $identity.Name
        $installNeeded = $false
        if ($null -ne $installed) {
            $payloadV = $null
            try { $payloadV = [version]$identity.Version } catch { }
            if ($null -ne $payloadV -and $installed -ge $payloadV) {
                $installNeeded = $false
            }
            else {
                $installNeeded = $true
            }
        }
        else {
            $installNeeded = $true
        }
        $decisions += [pscustomobject]@{
            Piece            = $piece.Piece
            File             = $piece.File
            Path             = $path
            PayloadName      = $identity.Name
            PayloadVersion   = $identity.Version
            InstalledVersion = if ($null -ne $installed) { $installed.ToString() } else { $null }
            InstallNeeded    = $installNeeded
        }
    }
    return $decisions
}

function Invoke-OSyncBootstrapStepAppInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$WhatIf
    )
    $decisions = @(Get-OSyncAppInstallerDecisions -Config $Config -Root $Root)

    # Install order: VCLibs -> UI.Xaml -> msixbundle. Only pieces whose gate
    # says install-needed are added (per-piece version gate, Oracle r5-m2).
    $order = @{ 'vclibs' = 0; 'uixaml' = 1; 'msixbundle' = 2 }
    $needed = @($decisions | Where-Object { $_.InstallNeeded } | Sort-Object { $order[$_.Piece] })
    $skipped = @($decisions | Where-Object { -not $_.InstallNeeded })

    foreach ($d in $skipped) {
        $verText = if ($null -ne $d.InstalledVersion) { "installed $($d.InstalledVersion) >= payload $($d.PayloadVersion)" } else { 'installed version unknown' }
        Write-OSyncLog -Category 'bootstrap' -Level Info `
            -Message ("step 1: skipping Appx piece {0} ({1}, {2})" -f $d.Piece, $d.PayloadName, $verText) `
            -Data $d -Config $Config | Out-Null
    }

    # WhatIf returns BEFORE any state write - even when every piece is
    # skipped (the common case on an already-provisioned machine), the
    # winget.exe resolution + state.wingetExePath record must NOT happen.
    if ($WhatIf) {
        $names = if ($needed.Count -gt 0) { ($needed | ForEach-Object { $_.File }) -join ', ' } else { '(none - all pieces skipped by version gate)' }
        return (New-OSyncBootstrapStepResult -Step '1-appinstaller' -Status 'done' `
            -Message "WhatIf: would Add-AppxPackage (in order VCLibs -> UI.Xaml -> msixbundle): $names" -Data @{ Needed = $needed })
    }

    foreach ($d in $needed) {
        Write-OSyncLog -Category 'bootstrap' -Level Info `
            -Message ("step 1: Add-AppxPackage {0} ({1}@{2}) from '{3}'" -f $d.Piece, $d.PayloadName, $d.PayloadVersion, $d.Path) `
            -Data $d -Config $Config | Out-Null
        try {
            Add-AppxPackage -Path $d.Path -ErrorAction Stop
        }
        catch {
            throw "Bootstrap.ps1 step 1: Add-AppxPackage failed for '$($d.File)': $($_.Exception.Message)"
        }
    }

    # winget.exe resolution (Metis B1) - re-derived this run, never from state.
    $wingetExe = Resolve-OSyncWingetExePath
    if ($null -eq $wingetExe) {
        throw "Bootstrap.ps1 step 1: winget.exe not found under C:\Program Files\WindowsApps (the App Installer install appears to have failed or the glob is empty)."
    }
    # Record wingetExePath (RECORD ONLY / diagnostic - apply re-derives each run).
    $state = Get-OSyncState -Category 'winget' -Config $Config
    $state.wingetExePath = $wingetExe
    Save-OSyncState -Category 'winget' -State $state -Config $Config | Out-Null
    Write-OSyncLog -Category 'bootstrap' -Level Info `
        -Message "step 1: winget.exe resolved to '$wingetExe' and recorded (state.wingetExePath, diagnostic only)." `
        -Data @{ WingetExe = $wingetExe } -Config $Config | Out-Null

    return (New-OSyncBootstrapStepResult -Step '1-appinstaller' -Status 'done' `
        -Message ("App Installer step done: {0} piece(s) skipped by version gate, {1} installed." -f $skipped.Count, $needed.Count) `
        -Data @{ Skipped = @($skipped); Installed = @($needed); WingetExe = $wingetExe })
}

# ---- step 2: LocalManifestFiles (both contexts) -----------------------------

function Test-OSyncWingetLocalManifestEnabled {
    <#
      'winget settings export' -> true when adminSettings.localManifestFiles
      (or userSettings.localManifestFiles) is enabled. Returns $false when
      the export fails or the key is absent (caller then enables).
      NOTE: the real export JSON uses the key 'LocalManifestFiles' (capital
      L/M/F - observed winget v1.29.290); Dictionary.ContainsKey is
      case-SENSITIVE, so the lookup iterates keys with -ieq.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WingetExe)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $WingetExe settings export 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldEap }
    if ($code -ne 0) { return $false }
    $text = ($out -join "`n")
    $parsed = $null
    try { $parsed = ConvertFrom-OSyncBootstrapJson -Text $text } catch { return $false }
    if ($null -eq $parsed) { return $false }
    foreach ($scope in @('adminSettings', 'userSettings')) {
        if ($parsed -is [System.Collections.IDictionary]) {
            foreach ($key in $parsed.Keys) {
                if ([string]$key -ieq $scope) {
                    $node = $parsed[$key]
                    if ($node -is [System.Collections.IDictionary]) {
                        foreach ($inner in $node.Keys) {
                            if ([string]$inner -ieq 'localManifestFiles') {
                                try { return [bool]$node[$inner] } catch { }
                            }
                        }
                    }
                }
            }
        }
    }
    return $false
}

function Enable-OSyncWingetLocalManifest {
    <#
      Runs 'winget settings --enable LocalManifestFiles' then verifies via
      export. Observed storage (todo-13 QA, winget v1.29.290): the setting
      lives in C:\ProgramData\Microsoft\WinGet\<SID>\settings\pkg\Microsoft
      .DesktopAppInstaller\admin_settings (key localManifestFiles) - the
      sanctioned command writes it and the export reflects it. If enable +
      verify fails, abort with that location pinned (the operator can write
      the file directly as a fallback).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WingetExe)
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = @(& $WingetExe settings --enable LocalManifestFiles 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldEap }
    if ($code -ne 0) {
        throw "Bootstrap.ps1 step 2: 'winget settings --enable LocalManifestFiles' failed with exit code $code."
    }
    if (-not (Test-OSyncWingetLocalManifestEnabled -WingetExe $WingetExe)) {
        throw "Bootstrap.ps1 step 2: LocalManifestFiles enable did not take effect (winget v1.29.290 stores it at C:\ProgramData\Microsoft\WinGet\<SID>\settings\pkg\Microsoft.DesktopAppInstaller\admin_settings, key localManifestFiles)."
    }
}

function Register-OSyncWingetSettingsSystemOneShot {
    <#
      Registers + starts a ONE-SHOT SYSTEM scheduled task that enables
      LocalManifestFiles in the SYSTEM context (per-user semantics, Momus
      r3-M4 / Oracle r3-M5) and deletes itself. The runner script lives in
      <stateDir>\bin\ (SYSTEM/admin-writable, Users RX - NEVER in a
      user-writable area, Momus r6-B1). Idempotency: a marker file
      <stateDir>\run\winget-localmanifest-system.ok records a previous
      success; its presence skips the whole sub-step.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$WingetExe,
        [Parameter(Mandatory = $false)][string]$TaskName = 'PakageSync-WingetSettings-OneShot',
        [switch]$WhatIf
    )
    $marker = Join-Path (Join-Path $Config.stateDir 'run') 'winget-localmanifest-system.ok'
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        return (New-OSyncBootstrapStepResult -Step '2-localmanifest-system' -Status 'skipped' `
            -Message "SYSTEM-context LocalManifestFiles already enabled (marker '$marker') - skipping the one-shot task." -Data @{ Marker = $marker })
    }
    if ($WhatIf) {
        return (New-OSyncBootstrapStepResult -Step '2-localmanifest-system' -Status 'done' `
            -Message "WhatIf: would register + run one-shot SYSTEM task '$TaskName' enabling LocalManifestFiles then self-deleting." -Data @{ TaskName = $TaskName; Marker = $marker })
    }

    $binDir = Join-Path $Config.stateDir 'bin'
    if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    $runner = Join-Path $binDir 'enable-winget-localmanifest.ps1'
    $wQuoted = "'" + $WingetExe.Replace("'", "''") + "'"
    $mQuoted = "'" + $marker.Replace("'", "''") + "'"
    $tQuoted = "'" + $TaskName.Replace("'", "''") + "'"
    $runnerContent = @"
#Requires -Version 5.1
# One-shot SYSTEM-context LocalManifestFiles enabler (written by Install-OfflineBootstrap).
`$ErrorActionPreference = 'Stop'
`$w = $wQuoted
`$m = $mQuoted
`$t = $tQuoted
& `$w settings --enable LocalManifestFiles | Out-Null
`$code = `$LASTEXITCODE
`$ok = `$false
if (`$code -eq 0) {
    try {
        `$export = & `$w settings export 2>&1 | Out-String
        if ((`$export | ConvertFrom-Json).adminSettings.localManifestFiles) { `$ok = `$true }
    } catch { }
}
if (`$ok) {
    New-Item -ItemType Directory -Path (Split-Path -Parent `$m) -Force | Out-Null
    Set-Content -LiteralPath `$m -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding UTF8
}
& schtasks.exe /Delete /TN `$t /F | Out-Null
"@
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($runner, $runnerContent, $utf8Bom)

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $runner)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    Write-OSyncLog -Category 'bootstrap' -Level Info `
        -Message "step 2: registered one-shot SYSTEM task '$TaskName' (runner '$runner')." -Config $Config | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    # Wait for the self-deleting task to disappear (bounded).
    $deadline = [DateTime]::UtcNow.AddSeconds(60)
    while ([DateTime]::UtcNow -lt $deadline -and $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 500
    }
    $markerOk = Test-Path -LiteralPath $marker -PathType Leaf
    $leftover = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    if ($leftover) {
        Write-Warning "Bootstrap.ps1 step 2: one-shot task '$TaskName' did not self-delete; removing it."
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    }
    if (-not $markerOk) {
        Write-Warning "Bootstrap.ps1 step 2: SYSTEM-context LocalManifestFiles marker was not created by the one-shot task (enable may have failed under SYSTEM). The SYSTEM apply path re-verifies this (todo 20)."
    }
    return (New-OSyncBootstrapStepResult -Step '2-localmanifest-system' -Status 'done' `
        -Message ("one-shot SYSTEM task '{0}' ran; marker={1} leftover={2}." -f $TaskName, $markerOk, $leftover) `
        -Data @{ TaskName = $TaskName; MarkerOk = $markerOk; Leftover = $leftover })
}

function Invoke-OSyncBootstrapStepLocalManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        # AllowEmptyString: under -WhatIf a non-elevated shell cannot glob
        # winget.exe, so the orchestrator may pass an empty value.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$WingetExe,
        [Parameter(Mandatory = $false)][string]$WingetSettingsTaskName = 'PakageSync-WingetSettings-OneShot',
        [switch]$WhatIf
    )
    # Under -WhatIf a non-elevated shell cannot glob winget.exe; detection is
    # impossible then, so just report the planned action.
    if ($WhatIf -and [string]::IsNullOrWhiteSpace($WingetExe)) {
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 2 WhatIf: winget.exe not resolvable (non-elevated) - would check + enable LocalManifestFiles in both contexts." -Config $Config | Out-Null
        return (New-OSyncBootstrapStepResult -Step '2-localmanifest' -Status 'done' `
            -Message 'WhatIf: would check/enable LocalManifestFiles in the admin context and run the SYSTEM one-shot.' -Data @{})
    }
    # Admin context (this process): QA exemption - if already enabled, log + skip.
    if (Test-OSyncWingetLocalManifestEnabled -WingetExe $WingetExe) {
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 2: LocalManifestFiles already enabled in the admin context - skipping the enable (QA exemption)." -Config $Config | Out-Null
    }
    else {
        if ($WhatIf) {
            Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 2 WhatIf: would run 'winget settings --enable LocalManifestFiles' (admin context)." -Config $Config | Out-Null
        }
        else {
            Enable-OSyncWingetLocalManifest -WingetExe $WingetExe
            Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 2: LocalManifestFiles enabled in the admin context (verified via winget settings export)." -Config $Config | Out-Null
        }
    }
    $systemResult = Register-OSyncWingetSettingsSystemOneShot -Config $Config -WingetExe $WingetExe -TaskName $WingetSettingsTaskName -WhatIf:$WhatIf
    $status = if ($systemResult.Status -eq 'skipped') { 'skipped' } else { 'done' }
    return (New-OSyncBootstrapStepResult -Step '2-localmanifest' -Status $status -Message $systemResult.Message -Data $systemResult.Data)
}

# ---- step 3: runtime winget installs over local HTTP -------------------------

function Invoke-OSyncBootstrapStepRuntimeWinget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$WingetExe,
        [switch]$WhatIf
    )
    $runtimeTxt = Join-Path $Root 'runtime\runtime-winget.txt'
    if (-not (Test-Path -LiteralPath $runtimeTxt -PathType Leaf)) {
        throw "Bootstrap.ps1 step 3: runtime\runtime-winget.txt not found in '$Root'."
    }
    $entries = @(Read-OSyncWingetList -Path $runtimeTxt)
    if ($entries.Count -eq 0) {
        return (New-OSyncBootstrapStepResult -Step '3-runtime-winget' -Status 'skipped' `
            -Message 'runtime-winget.txt is empty - no runtime winget packages to install.' -Data @{ Entries = 0 })
    }

    # Port-coupling guard (Oracle r7-4): the rewritten InstallerUrl port is
    # baked at A-side export time and the B config must never override it.
    $httpPort = [int]$Config.httpPort
    $mismatch = Get-OSyncWingetPortMismatch -WorkDir $Root -HttpPort $httpPort
    if ($null -ne $mismatch) {
        throw ("Bootstrap.ps1 step 3: port-coupling guard failed - rewritten InstallerUrl '{0}' uses a port different from config.httpPort ({1})." -f $mismatch, $httpPort)
    }

    $scope = [string]$Config.winget.scope
    $arch = [string]$Config.winget.architecture

    if ($WhatIf) {
        $ids = ($entries | ForEach-Object { $_.Id }) -join ', '
        return (New-OSyncBootstrapStepResult -Step '3-runtime-winget' -Status 'done' `
            -Message "WhatIf: would start HTTP server on port $httpPort and install $($entries.Count) runtime package(s): $ids" -Data @{ Ids = @($entries) })
    }

    $stagingRoot = Join-Path (Join-Path $Config.stateDir 'run') 'bootstrap-manifests'
    if (Test-Path -LiteralPath $stagingRoot) {
        Remove-Item -Recurse -Force -LiteralPath $stagingRoot
    }
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

    $server = $null
    $installed = @()
    try {
        $server = Start-OSyncHttpServer -Root $Root -Port $httpPort
        Write-OSyncLog -Category 'bootstrap' -Level Info `
            -Message ("step 3: HTTP server started on port {0} serving {1}" -f $httpPort, $Root) -Config $Config | Out-Null

        foreach ($entry in $entries) {
            $pkgDir = Join-Path $Root ('winget\{0}' -f $entry.Id)
            $yamls = @(Get-ChildItem -LiteralPath $pkgDir -Filter '*.yaml' -File -ErrorAction SilentlyContinue)
            if ($yamls.Count -eq 0) {
                throw "Bootstrap.ps1 step 3: no manifest YAML found in package dir '$pkgDir' for runtime package '$($entry.Id)'."
            }
            # Manifest-ONLY flat staging dir (winget v1.29.290 rejects
            # non-YAML files and subdirectories in --manifest - todo-13 QA).
            $manifestDir = New-OSyncWingetManifestStaging -PackageDir $pkgDir -StagingRoot $stagingRoot
            $installArgs = @(
                'install',
                '--manifest', ('"{0}"' -f $manifestDir),
                '--scope', $scope,
                '--architecture', $arch,
                '--accept-package-agreements',
                '--accept-source-agreements',
                '--disable-interactivity'
            )
            Write-OSyncLog -Category 'bootstrap' -Level Info `
                -Message ("step 3: installing runtime winget package {0} ({1}) from manifest set {2}" -f $entry.Id, $entry.Version, $manifestDir) `
                -Data @{ Id = $entry.Id; Version = $entry.Version; ManifestDir = $manifestDir } -Config $Config | Out-Null

            $result = Invoke-OSyncWingetInstall -WingetExe $WingetExe -Arguments $installArgs

            $tail = ''
            if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
                $tailLines = @($result.Output -split "`n")
                $tail = (($tailLines | Select-Object -Last 15) -join "`n").Trim()
            }
            if ($result.TimedOut) {
                throw "Bootstrap.ps1 step 3: winget install TIMED OUT for '$($entry.Id)' - bootstrap aborted (step 7 not reached)."
            }
            # Exit-code policy (Momus M3): 0 / satisfied = ok; any other
            # non-zero FAILS the bootstrap (runtime deps are mandatory).
            if ($result.ExitCode -eq 0 -or $script:WingetSatisfiedExitCodes -contains $result.ExitCode) {
                $installed += [pscustomobject]@{ Id = $entry.Id; Version = $entry.Version; ExitCode = $result.ExitCode }
                Write-OSyncLog -Category 'bootstrap' -Level Info `
                    -Message ("step 3: runtime winget package {0} installed/satisfied (exit {1})" -f $entry.Id, $result.ExitCode) `
                    -Data @{ Id = $entry.Id; ExitCode = $result.ExitCode } -Config $Config | Out-Null
            }
            else {
                # winget source auto-update failures are logged only; a
                # genuine install failure aborts.
                Write-OSyncLog -Category 'bootstrap' -Level Error `
                    -Message ("step 3: winget install FAILED for {0} (exit {1}) - bootstrap aborted. Output tail: {2}" -f $entry.Id, $result.ExitCode, $tail) `
                    -Data @{ Id = $entry.Id; ExitCode = $result.ExitCode; OutputTail = $tail } -Config $Config | Out-Null
                throw "Bootstrap.ps1 step 3: winget install FAILED for '$($entry.Id)' (exit $($result.ExitCode)) - the runtime bootstrap is incomplete; step 7 was NOT reached."
            }
        }
    }
    finally {
        if ($null -ne $server) {
            Stop-OSyncHttpServer -Handle $server
            Write-OSyncLog -Category 'bootstrap' -Level Info -Message 'step 3: HTTP server stopped.' -Config $Config | Out-Null
        }
    }

    # Post-install: re-read the machine PATH and RECORD the resolved
    # python.exe / node.exe (RECORD ONLY; apply re-derives every run,
    # Oracle r3-B1). A tool the manifest was supposed to install but which
    # does not resolve afterwards is an explicit error (Oracle m9).
    $entryIds = @($entries | ForEach-Object { $_.Id.ToLowerInvariant() })
    $needsPython = ($entryIds | Where-Object { $_ -like 'python.python*' }).Count -gt 0
    $needsNode = ($entryIds | Where-Object { $_ -like 'openjs.nodejs*' }).Count -gt 0

    $pythonExe = $null
    try { $pythonExe = Resolve-OSyncApplyPython } catch { $pythonExe = $null }
    $nodeExe = $null
    try { $nodeExe = Join-Path (Resolve-OSyncNodeInstallDir) 'node.exe' } catch { $nodeExe = $null }

    if ($needsPython -and $null -eq $pythonExe) {
        throw "Bootstrap.ps1 step 3: python.exe does not resolve from the HKLM machine PATH after installing '$($entries[0].Id)' - the Python PATH registration did not take effect."
    }
    if ($needsNode -and $null -eq $nodeExe) {
        throw "Bootstrap.ps1 step 3: node.exe does not resolve from the HKLM machine PATH after installing '$($entries[0].Id)' - the Node PATH registration did not take effect."
    }

    $state = Get-OSyncState -Category 'winget' -Config $Config
    $state.pythonExePath = $pythonExe
    $state.nodeExePath = $nodeExe
    Save-OSyncState -Category 'winget' -State $state -Config $Config | Out-Null
    Write-OSyncLog -Category 'bootstrap' -Level Info `
        -Message ("step 3: recorded pythonExePath='{0}' nodeExePath='{1}' (diagnostic only)." -f $pythonExe, $nodeExe) -Config $Config | Out-Null

    return (New-OSyncBootstrapStepResult -Step '3-runtime-winget' -Status 'done' `
        -Message ("{0} runtime winget package(s) installed/satisfied; python='{1}' node='{2}' recorded." -f $installed.Count, $pythonExe, $nodeExe) `
        -Data @{ Installed = $installed; PythonExe = $pythonExe; NodeExe = $nodeExe })
}

# ---- step 4: Verdaccio local copies + resident task --------------------------

function Get-OSyncVerdaccioTaskAction {
    # Returns { Execute, Arguments, WorkingDirectory } for the desired
    # 'PakageSync-Verdaccio' task (SYSTEM resident service). node.exe is
    # re-derived from the machine PATH this run and pinned ABSOLUTE into the
    # task action (a SYSTEM task's environment block may be stale at boot,
    # Momus M5).
    param([Parameter(Mandatory = $true)]$Config)
    $nodeInstallDir = Resolve-OSyncNodeInstallDir
    $nodeExe = Join-Path $nodeInstallDir 'node.exe'
    $verdaccioBin = Join-Path (Join-Path $Config.stateDir 'verdaccio-bin') 'node_modules\verdaccio\bin\verdaccio'
    if (-not (Test-Path -LiteralPath $verdaccioBin -PathType Leaf)) {
        throw "Bootstrap.ps1 step 4: Verdaccio entry script not found at '$verdaccioBin' - the local payload copy is incomplete."
    }
    $yml = Join-Path (Join-Path $Config.stateDir 'verdaccio') 'verdaccio-b.yml'
    return [pscustomobject]@{
        Execute        = $nodeExe
        Arguments      = ('"{0}" --config "{1}"' -f $verdaccioBin, $yml)
        WorkingDirectory = (Join-Path $Config.stateDir 'work')
        NodeExe        = $nodeExe
        VerdaccioBin   = $verdaccioBin
        Yaml           = $yml
    }
}

function Invoke-OSyncBootstrapStepNpm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $false)][string]$VerdaccioTaskName = 'PakageSync-Verdaccio',
        [switch]$WhatIf
    )
    $npmDir = Join-Path $Root 'npm'
    $bYaml = Join-Path $npmDir 'verdaccio-b.yml'
    if (-not (Test-Path -LiteralPath $bYaml -PathType Leaf)) {
        throw "Bootstrap.ps1 step 4: '<Root>\npm\verdaccio-b.yml' not found at '$bYaml' - the npm category export is incomplete."
    }
    $bYamlText = [System.IO.File]::ReadAllText($bYaml)
    if (-not (Test-OSyncVerdaccioBYaml -Content $bYamlText)) {
        throw "Bootstrap.ps1 step 4: '$bYaml' failed the offline assertion (no uplinks/proxy, storage ./storage)."
    }

    if ($WhatIf) {
        return (New-OSyncBootstrapStepResult -Step '4-verdaccio' -Status 'done' `
            -Message "WhatIf: would copy <bw>\runtime\verdaccio -> <stateDir>\verdaccio-bin and <bw>\npm -> <stateDir>\verdaccio, then register + start task '$VerdaccioTaskName' (SYSTEM, AtStartup) and wait for port $($Config.verdaccioPort)." `
            -Data @{ TaskName = $VerdaccioTaskName; Port = $Config.verdaccioPort })
    }

    # Seed the LOCAL copies (the resident service only ever reads the local
    # copy, Oracle M4). The stop->copy->start strict order on REFRESH is the
    # apply path's job (todo 15); bootstrap does the initial seed.
    Invoke-OSyncRobocopy -Source (Join-Path $Root 'runtime\verdaccio') -Destination (Join-Path $Config.stateDir 'verdaccio-bin') -ExtraArgs @('/MIR') | Out-Null
    Invoke-OSyncRobocopy -Source $npmDir -Destination (Join-Path $Config.stateDir 'verdaccio') -ExtraArgs @('/MIR') | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $Config.stateDir 'verdaccio') 'verdaccio-b.yml') -PathType Leaf)) {
        throw "Bootstrap.ps1 step 4: the local copy refresh did not produce '<stateDir>\verdaccio\verdaccio-b.yml'."
    }
    Write-OSyncLog -Category 'bootstrap' -Level Info -Message 'step 4: seeded local Verdaccio copies (<stateDir>\verdaccio-bin from runtime payload, <stateDir>\verdaccio from npm category).' -Config $Config | Out-Null

    $desired = Get-OSyncVerdaccioTaskAction -Config $Config

    # Idempotent registration: skip when a task with the identical action
    # already exists; re-register when the action changed (e.g. port/stateDir).
    $existing = Get-ScheduledTask -TaskName $VerdaccioTaskName -ErrorAction SilentlyContinue
    $registered = $false
    if ($null -ne $existing -and $existing.Actions.Count -gt 0) {
        $act = $existing.Actions[0]
        if ($act.Execute -ieq $desired.Execute -and $act.Arguments -ieq $desired.Arguments) {
            Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 4: task '$VerdaccioTaskName' already registered with the identical action - skipping registration." -Config $Config | Out-Null
        }
        else {
            Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 4: task '$VerdaccioTaskName' exists but its action changed - re-registering." -Config $Config | Out-Null
            $registered = $true
        }
    }
    else {
        $registered = $true
    }
    if ($registered) {
        $action = New-ScheduledTaskAction -Execute $desired.Execute -Argument $desired.Arguments -WorkingDirectory $desired.WorkingDirectory
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $VerdaccioTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
        Write-OSyncLog -Category 'bootstrap' -Level Info `
            -Message ("step 4: registered task '{0}' (SYSTEM, AtStartup, RestartCount=3/1min): {1} {2}" -f $VerdaccioTaskName, $desired.Execute, $desired.Arguments) `
            -Data $desired -Config $Config | Out-Null
    }

    # Port hygiene: something else already holding the port would make the
    # service fail to bind.
    $port = [int]$Config.verdaccioPort
    if (Test-OSyncPortListening -Port $port) {
        throw "Bootstrap.ps1 step 4: port $port is already in use by another process - cannot start the Verdaccio service."
    }
    Start-ScheduledTask -TaskName $VerdaccioTaskName | Out-Null
    if (-not (Wait-OSyncPortListening -Port $port -TimeoutSeconds 30)) {
        throw "Bootstrap.ps1 step 4: Verdaccio did not open port $port within 30 s - the registry is not reachable at http://127.0.0.1:$port/."
    }
    Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 4: registry is LISTENING on 127.0.0.1:$port." -Config $Config | Out-Null

    return (New-OSyncBootstrapStepResult -Step '4-verdaccio' -Status 'done' `
        -Message ("Verdaccio service task '{0}' running; registry LISTENING on 127.0.0.1:{1}." -f $VerdaccioTaskName, $port) `
        -Data @{ TaskName = $VerdaccioTaskName; Port = $port; NodeExe = $desired.NodeExe })
}

# ---- step 5: stateDir layout + ACLs ------------------------------------------

function New-OSyncStateDirSkeleton {
    # Creates the stateDir sub-directories so earlier steps have somewhere to
    # write (work\bootstrap for the work copy, run for the lock/logs, state
    # for the system store). Full ACL hardening is step 5.
    param([Parameter(Mandatory = $true)]$Config)
    $stateDir = [string]$Config.stateDir
    foreach ($sub in @('state', 'run', 'bin', 'work', 'verdaccio', 'verdaccio-bin')) {
        $p = Join-Path $stateDir $sub
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
    $runLogs = Join-Path (Join-Path $stateDir 'run') 'logs'
    if (-not (Test-Path -LiteralPath $runLogs -PathType Container)) {
        New-Item -ItemType Directory -Path $runLogs -Force | Out-Null
    }
    $workBootstrap = Join-Path (Join-Path $stateDir 'work') 'bootstrap'
    if (-not (Test-Path -LiteralPath $workBootstrap -PathType Container)) {
        New-Item -ItemType Directory -Path $workBootstrap -Force | Out-Null
    }
}

function Invoke-OSyncBootstrapStepStateDirLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [switch]$WhatIf
    )
    $stateDir = [string]$Config.stateDir
    if ([string]::IsNullOrWhiteSpace($stateDir)) {
        throw 'Bootstrap.ps1 step 5: config.stateDir is empty.'
    }
    if (-not $WhatIf -and -not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    # Layout: subdir -> ACL policy.
    #   state\  : SYSTEM/admins RW, Users read-only
    #   run\    : both principals modify (apply.lock, user-state.json,
    #             chezmoistate.boltdb, logs\)
    #   bin\    : SYSTEM/admins write, Users RX (launch-apply.ps1)
    #   work\ verdaccio\ verdaccio-bin\ : SYSTEM/admins exclusive, Users read
    $layout = @{
        'state'         = 'SystemAdminsRead'
        'run'           = 'UsersModify'
        'bin'           = 'SystemAdminsRWUsersRX'
        'work'          = 'SystemAdminsRead'
        'verdaccio'     = 'SystemAdminsRead'
        'verdaccio-bin' = 'SystemAdminsRead'
    }

    if ($WhatIf) {
        $planned = ($layout.Keys | Sort-Object | ForEach-Object { "$_=$($layout[$_])" }) -join ', '
        return (New-OSyncBootstrapStepResult -Step '5-statedir-acl' -Status 'done' `
            -Message "WhatIf: would create/harden stateDir subdirs under '$stateDir': $planned" -Data @{ StateDir = $stateDir; Layout = $layout })
    }

    $changed = 0
    $errors = @()
    foreach ($sub in $layout.Keys) {
        $dir = Join-Path $stateDir $sub
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Anti-poisoning gate (Oracle r3-M4): pre-created dirs with an
        # unexpected owner abort the bootstrap.
        if (-not (Test-OSyncTrustedDirOwner -Dir $dir)) {
            $owner = (Get-Acl -LiteralPath $dir).Owner
            throw ("Bootstrap.ps1 step 5: directory '{0}' is owned by '{1}' - unexpected owner (CREATOR OWNER pre-create poisoning). Fix the ownership and re-run." -f $dir, $owner)
        }
        # Pre-existing dirs: icacls /reset first, then rebuild the grants.
        try {
            Invoke-OSyncBootstrapGrantAcl -Dir $dir -Policy $layout[$sub]
            $changed++
        }
        catch {
            $errors += $_.Exception.Message
        }
    }
    # run\logs also gets the UsersModify policy (logs are written by both
    # principals' flows).
    $runLogs = Join-Path (Join-Path $stateDir 'run') 'logs'
    if (-not (Test-Path -LiteralPath $runLogs -PathType Container)) {
        New-Item -ItemType Directory -Path $runLogs -Force | Out-Null
    }
    if (-not (Test-OSyncTrustedDirOwner -Dir $runLogs)) {
        throw ("Bootstrap.ps1 step 5: directory '{0}' has an unexpected owner." -f $runLogs)
    }
    try {
        Invoke-OSyncBootstrapGrantAcl -Dir $runLogs -Policy 'UsersModify'
    }
    catch { $errors += $_.Exception.Message }

    if ($errors.Count -gt 0) {
        throw ("Bootstrap.ps1 step 5: ACL hardening failed: {0}" -f ($errors -join '; '))
    }

    # <repoRoot> ACL: Users readable - WARNING only, never modified.
    $repoRoot = [string]$Config.repoRoot
    if (Test-Path -LiteralPath $repoRoot -PathType Container) {
        try {
            $oldEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            $aclText = @(& icacls.exe $repoRoot 2>&1)
            $aclOut = ($aclText -join "`n")
            $ErrorActionPreference = $oldEap
            $usersReadable = $aclOut -match 'S-1-5-32-545' -or $aclOut -match '\(R\)|\(RX\)'
            if (-not $usersReadable) {
                Write-Warning "Bootstrap.ps1 step 5: <repoRoot> '$repoRoot' ACL does not appear to grant Users read access - the sync transport may be restricted. Not modified (warning only)."
            }
        }
        catch { }
    }

    return (New-OSyncBootstrapStepResult -Step '5-statedir-acl' -Status 'done' `
        -Message ("stateDir layout hardened under '{0}' ({1} subdirs ACL'd, owner checks passed)." -f $stateDir, $changed) `
        -Data @{ StateDir = $stateDir; Hardened = $changed })
}

# ---- step 6: tool landing + C:\PakageSync family + micro launcher ------------

function Get-OSyncLaunchApplyScriptContent {
    # The one-shot micro launcher content (never renamed; lives in bin\ which
    # is SYSTEM/admin-writable and Users-RX - never in a user-writable area,
    # Momus r6-B1). Self-heals the current/.new/.old family (Oracle r7-6)
    # then executes a script under C:\PakageSync\src.
    return @'
#Requires -Version 5.1
# launch-apply.ps1 - one-shot micro launcher for the PakageSync apply tasks.
# Located in <stateDir>\bin\ (SYSTEM/admin-writable, Users RX only). Never
# renamed. Self-heals the C:\PakageSync current/.new/.old family then runs
# the requested script under C:\PakageSync\src.
param(
    [Parameter(Mandatory = $true)][string]$ScriptRel,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ScriptArgs = @()
)
$ErrorActionPreference = 'Stop'
$root = 'C:\PakageSync'
$newDir = 'C:\PakageSync.new'
$oldDir = 'C:\PakageSync.old'
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    if (Test-Path -LiteralPath $newDir -PathType Container) {
        Rename-Item -LiteralPath $newDir -NewName 'PakageSync' -Force
    }
    elseif (Test-Path -LiteralPath $oldDir -PathType Container) {
        Rename-Item -LiteralPath $oldDir -NewName 'PakageSync' -Force
    }
}
# Clean up remnants after the current copy is healthy.
foreach ($r in @($newDir, $oldDir)) {
    if (Test-Path -LiteralPath $r -PathType Container) {
        Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$script = Join-Path (Join-Path $root 'src') $ScriptRel
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
    throw "launch-apply.ps1: script not found: $script"
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @ScriptArgs
exit $LASTEXITCODE
'@
}

function Invoke-OSyncBootstrapStepToolLanding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Root,
        # Test seam: production ALWAYS lands at the fixed C:\PakageSync
        # (plan-pinned; the B product's real landing). Unit tests redirect to
        # a $TestDrive path so the real landing is never touched.
        [Parameter(Mandatory = $false)][string]$LandingRoot = 'C:\PakageSync',
        [switch]$WhatIf
    )
    $toolDir = Join-Path $Root 'runtime\tool'
    if (-not (Test-Path -LiteralPath $toolDir -PathType Container)) {
        throw "Bootstrap.ps1 step 6: <Root>\runtime\tool missing in '$Root' - the tool payload is not in the work copy."
    }

    if ($WhatIf) {
        return (New-OSyncBootstrapStepResult -Step '6-tool-landing' -Status 'done' `
            -Message "WhatIf: would robocopy '$toolDir' -> '$LandingRoot' (/MIR /XD config), first-copy config only if absent, harden the landing + .new/.old family, and place the launch-apply.ps1 micro launcher." -Data @{ ToolDir = $toolDir; LandingRoot = $LandingRoot })
    }

    # 1) Tool body landing (config dir EXCLUDED - B-side config is locally owned).
    Invoke-OSyncRobocopy -Source $toolDir -Destination $LandingRoot -ExtraArgs @('/MIR', '/XD', 'config') | Out-Null

    # 2) First-time config copy: packagesync.b.json -> <LandingRoot>\config\packagesync.json
    #    only when the config does not exist yet (a re-bootstrap never resets
    #    B-local config, Momus r3-B1).
    $localConfig = Join-Path (Join-Path $LandingRoot 'config') 'packagesync.json'
    if (-not (Test-Path -LiteralPath $localConfig -PathType Leaf)) {
        $bConfig = Join-Path $toolDir 'packagesync.b.json'
        if (Test-Path -LiteralPath $bConfig -PathType Leaf) {
            New-Item -ItemType Directory -Path (Join-Path $LandingRoot 'config') -Force | Out-Null
            Copy-Item -LiteralPath $bConfig -Destination $localConfig -Force
            Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 6: first-time config copy '$bConfig' -> '$localConfig'." -Config $Config | Out-Null
        }
        else {
            Write-OSyncLog -Category 'bootstrap' -Level Warning -Message "step 6: packagesync.b.json not found in tool payload ('$bConfig') - config first-copy skipped." -Config $Config | Out-Null
        }
    }
    else {
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 6: '$localConfig' already exists - not overwriting (B-side config is locally owned)." -Config $Config | Out-Null
    }

    # 3) Landing + .new/.old family hardening (explicit create + icacls /reset
    #    + owner check; unexpected owner aborts - Momus r7-MAJOR-1).
    foreach ($dir in @($LandingRoot, ($LandingRoot + '.new'), ($LandingRoot + '.old'))) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if (-not (Test-OSyncTrustedDirOwner -Dir $dir)) {
            throw ("Bootstrap.ps1 step 6: '{0}' is owned by '{1}' - unexpected owner (pre-create poisoning)." -f $dir, (Get-Acl -LiteralPath $dir).Owner)
        }
        Invoke-OSyncBootstrapGrantAcl -Dir $dir -Policy 'SystemAdminsRWUsersRX'
    }

    # 4) One-shot micro launcher (never renamed; bin\ is SYSTEM/admin-writable
    #    and Users-RX - executing a user-writable script as SYSTEM would be a
    #    privilege escalation, Momus r6-B1).
    $binDir = Join-Path $Config.stateDir 'bin'
    if (-not (Test-Path -LiteralPath $binDir -PathType Container)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }
    $launcher = Join-Path $binDir 'launch-apply.ps1'
    $content = Get-OSyncLaunchApplyScriptContent
    $write = $true
    if (Test-Path -LiteralPath $launcher -PathType Leaf) {
        $existingContent = [System.IO.File]::ReadAllText($launcher)
        # Strip a leading BOM before comparing.
        if ($existingContent.StartsWith([char]0xFEFF)) { $existingContent = $existingContent.Substring(1) }
        if ($existingContent -eq $content) { $write = $false }
    }
    if ($write) {
        [System.IO.File]::WriteAllText($launcher, $content, (New-Object System.Text.UTF8Encoding($true)))
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 6: placed one-shot micro launcher '$launcher'." -Config $Config | Out-Null
    }
    else {
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "step 6: micro launcher '$launcher' already up to date - skipping." -Config $Config | Out-Null
    }

    return (New-OSyncBootstrapStepResult -Step '6-tool-landing' -Status 'done' `
        -Message "Tool landed at '$LandingRoot' (/MIR /XD config), family hardened, micro launcher placed." -Data @{ Landing = $LandingRoot; Launcher = $launcher })
}

# ---- step 7: bootstrapped = true ---------------------------------------------

function Set-OSyncBootstrapComplete {
    <#
      Sets state.bootstrapped = $true plus the diagnostic fields
      (wingetExePath/pythonExePath/nodeExePath/runtimeWingetHash/
      runtimeFilesHash) in the SYSTEM store. Only called after EVERY enabled
      step succeeded (Momus M3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$Bw,
        $WingetExe = $null,
        $PythonExe = $null,
        $NodeExe = $null,
        [switch]$WhatIf
    )
    if ($WhatIf) {
        return (New-OSyncBootstrapStepResult -Step '7-bootstrapped' -Status 'done' `
            -Message 'WhatIf: would set state.bootstrapped=true and record the runtime hashes.' -Data @{})
    }
    $state = Get-OSyncState -Category 'winget' -Config $Config
    $state.bootstrapped = $true
    if (-not [string]::IsNullOrWhiteSpace([string]$WingetExe)) { $state.wingetExePath = [string]$WingetExe }
    if (-not [string]::IsNullOrWhiteSpace([string]$PythonExe)) { $state.pythonExePath = [string]$PythonExe }
    if (-not [string]::IsNullOrWhiteSpace([string]$NodeExe)) { $state.nodeExePath = [string]$NodeExe }
    $runtimeTxt = Join-Path $Bw 'runtime\runtime-winget.txt'
    $runtimeFiles = Join-Path $Bw 'runtime\files.json'
    $state.runtimeWingetHash = if (Test-Path -LiteralPath $runtimeTxt -PathType Leaf) { Get-OSyncFileSha256 -Path $runtimeTxt } else { $null }
    $state.runtimeFilesHash = if (Test-Path -LiteralPath $runtimeFiles -PathType Leaf) { Get-OSyncFileSha256 -Path $runtimeFiles } else { $null }
    Save-OSyncState -Category 'winget' -State $state -Config $Config | Out-Null
    Write-OSyncLog -Category 'bootstrap' -Level Info `
        -Message ("step 7: state.bootstrapped=true (runtimeWingetHash={0}, runtimeFilesHash={1})." -f $state.runtimeWingetHash, $state.runtimeFilesHash) `
        -Data @{ bootstrapped = $true; runtimeWingetHash = $state.runtimeWingetHash; runtimeFilesHash = $state.runtimeFilesHash } -Config $Config | Out-Null
    return (New-OSyncBootstrapStepResult -Step '7-bootstrapped' -Status 'done' -Message 'state.bootstrapped=true set in the SYSTEM store.')
}

# ---- orchestrator ------------------------------------------------------------

function Invoke-OSyncBootstrap {
    <#
      Runs the full B-side bootstrap orchestration (plan todo 12). Returns a
      result object { Success, Bootstrapped, Bw, ExportedAtUtc, Steps,
      WingetExe, PythonExe, NodeExe, Error, WhatIf }. Never sets
      bootstrapped when any enabled step fails. The apply.lock is NOT taken
      here - the entry script owns it (Momus r7-m3).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $false)][string]$RepoRoot,
        [switch]$WhatIf,
        [Parameter(Mandatory = $false)][string]$VerdaccioTaskName = 'PakageSync-Verdaccio',
        [Parameter(Mandatory = $false)][string]$WingetSettingsTaskName = 'PakageSync-WingetSettings-OneShot'
    )

    $result = [pscustomobject]@{
        Success       = $false
        Bootstrapped  = $false
        Bw            = $null
        ExportedAtUtc = $null
        Steps         = @()
        WingetExe     = $null
        PythonExe     = $null
        NodeExe       = $null
        Error         = $null
        WhatIf        = [bool]$WhatIf
    }

    try {
        if ($Config.role -ne 'B') {
            throw "Install-OfflineBootstrap: config role must be 'B' (got '$($Config.role)') - the bootstrap is a B-side operation."
        }
        if ([string]::IsNullOrWhiteSpace([string]$Config.stateDir)) {
            throw 'Install-OfflineBootstrap: config.stateDir is empty.'
        }
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = [string]$Config.repoRoot }
        $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
        if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
            throw "Install-OfflineBootstrap: repository root not found: '$RepoRoot'."
        }

        # stateDir skeleton must exist before the work copy lands (SKIPPED
        # under -WhatIf - a WhatIf run must make ZERO changes).
        if (-not $WhatIf) {
            New-OSyncStateDirSkeleton -Config $Config
        }

        $steps = @()

        # Step 5 (stateDir layout + ACLs) runs FIRST, before every other
        # step: the work copy lives under <stateDir>\work, and step 2 places
        # a runner script into <stateDir>\bin\ which a SYSTEM one-shot task
        # executes - that dir MUST already be SYSTEM/admin-writable and
        # Users-RX before anything is written into it (Momus r6-B1 elevation
        # guard). The plan lists the layout as step 5; executing it first is
        # the only order that keeps the tree hardened for every later step.
        # It is idempotent (detect-then-execute), so the numbered position in
        # the plan is observationally unchanged.
        $s5 = Invoke-OSyncBootstrapStepStateDirLayout -Config $Config -WhatIf:$WhatIf
        $steps += $s5

        # Precondition: repository integrity for the required categories.
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "bootstrap starting (repoRoot='$RepoRoot', whatIf=$WhatIf)." -Config $Config | Out-Null
        $integrity = Test-OSyncBootstrapRepoCategories -Config $Config -RepoRoot $RepoRoot
        $result.ExportedAtUtc = $integrity.ExportedAtUtc
        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "repository integrity OK for required categories (exportedAtUtc=$($integrity.ExportedAtUtc))." -Config $Config | Out-Null

        $bw = $null
        if ($WhatIf) {
            # WhatIf reads the repo root directly; ZERO changes.
            $bw = $RepoRoot
            $result.Bw = $bw
        }
        else {
            $bw = New-OSyncBootstrapWorkCopy -Config $Config -RepoRoot $RepoRoot -ExportedAtUtc $result.ExportedAtUtc
            try {
                $null = Test-OSyncBootstrapWorkCopy -Bw $bw
                Write-OSyncLog -Category 'bootstrap' -Level Info -Message "work copy re-verification PASSED at '$bw'." -Config $Config | Out-Null
            }
            catch {
                # A bad generation must never be kept as the newest.
                if (Test-Path -LiteralPath $bw -PathType Container) {
                    Remove-Item -LiteralPath $bw -Recurse -Force -ErrorAction SilentlyContinue
                }
                throw
            }
            $result.Bw = $bw
        }

        $wingetEnabled = [bool]$Config.categories.winget
        $npmEnabled = [bool]$Config.categories.npm
        $wingetExe = $null
        $pythonExe = $null
        $nodeExe = $null

        if ($wingetEnabled) {
            # Step 0: machine VC++ runtime.
            $s = Invoke-OSyncBootstrapStepVcRuntime -Config $Config -Root $bw -WhatIf:$WhatIf
            $steps += $s

            # Step 1: App Installer pieces + winget.exe resolution.
            $s1 = Invoke-OSyncBootstrapStepAppInstaller -Config $Config -Root $bw -WhatIf:$WhatIf
            $steps += $s1
            $wingetExe = if ($null -ne $s1.Data) { $s1.Data.WingetExe } else { $null }
            if ($null -eq $wingetExe -and -not $WhatIf) {
                throw 'Bootstrap.ps1: winget.exe was not resolved after the App Installer step.'
            }
            if ($WhatIf -and $null -eq $wingetExe) {
                # WhatIf: resolve read-only for reporting.
                $wingetExe = Resolve-OSyncWingetExePath
            }

            # Step 2: LocalManifestFiles in both contexts.
            $s2 = Invoke-OSyncBootstrapStepLocalManifest -Config $Config -WingetExe $wingetExe -WingetSettingsTaskName $WingetSettingsTaskName -WhatIf:$WhatIf
            $steps += $s2

            # Step 3: runtime winget installs over local HTTP.
            $s3 = Invoke-OSyncBootstrapStepRuntimeWinget -Config $Config -Root $bw -WingetExe $wingetExe -WhatIf:$WhatIf
            $steps += $s3
            if ($null -ne $s3.Data -and $null -ne $s3.Data.PythonExe) { $pythonExe = $s3.Data.PythonExe }
            if ($null -ne $s3.Data -and $null -ne $s3.Data.NodeExe) { $nodeExe = $s3.Data.NodeExe }
        }

        if ($npmEnabled) {
            # Step 4: Verdaccio local copies + resident task.
            $s4 = Invoke-OSyncBootstrapStepNpm -Config $Config -Root $bw -VerdaccioTaskName $VerdaccioTaskName -WhatIf:$WhatIf
            $steps += $s4
        }

        # Step 6: tool landing + C:\PakageSync family + micro launcher (always).
        $s6 = Invoke-OSyncBootstrapStepToolLanding -Config $Config -Root $bw -WhatIf:$WhatIf
        $steps += $s6

        # Step 7: bootstrapped = true (only when every enabled step succeeded).
        $s7 = Set-OSyncBootstrapComplete -Config $Config -Bw $bw -WingetExe $wingetExe -PythonExe $pythonExe -NodeExe $nodeExe -WhatIf:$WhatIf
        $steps += $s7

        $result.Steps = $steps
        $result.WingetExe = $wingetExe
        $result.PythonExe = $pythonExe
        $result.NodeExe = $nodeExe
        $result.Bootstrapped = $true
        $result.Success = $true

        Write-OSyncLog -Category 'bootstrap' -Level Info -Message "bootstrap SUCCESS (bootstrapped=$($result.Bootstrapped))." -Config $Config | Out-Null
        return $result
    }
    catch {
        $result.Success = $false
        $result.Bootstrapped = $false
        $result.Error = $_.Exception.Message
        Write-OSyncLog -Category 'bootstrap' -Level Error -Message ("bootstrap FAILED: {0}" -f $result.Error) -Config $Config | Out-Null
        return $result
    }
}
