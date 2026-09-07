#Requires -Version 5.1
<#
  DotfilesApply.ps1 - B-side dotfiles apply via chezmoi (USER context, conflict-safe).
  Windows PowerShell 5.1 compatible: no PS7-only syntax.

  Invoke-OSyncDotfilesApply -WorkDir [-Config] [-Destination] [-WhatIf]

  Runs in the USER context (the dotfiles scheduled task is a user task, see
  plan todo 17). Consumes the latest VERIFIED work copy built by the packages
  task - it never creates a work copy itself.

  CONFLICT SAFETY (plan todo 16, Momus M1 / Oracle M4): the guarantee is
  TOOL-SIDE, never a bet on a single chezmoi behavior. Before every apply we
  sha256 every managed target file and compare against (a) the hash recorded
  in state.dotfiles.files from the last successful apply and (b) the freshly
  rendered source hash (chezmoi cat). A target whose current hash differs
  from BOTH is locally modified -> excluded from this round and recorded in
  state.dotfiles.skipped. First run (no baseline): pre-existing files whose
  content differs from the source are ALL treated as locally modified ->
  skipped + reported.

  EMPIRICAL GATE (chezmoi v2.72.0, observed 2026-09-04, pinned here):
    - `chezmoi apply --keep-going` on a LOCALLY-MODIFIED target PROMPTS
      "<target> has changed since chezmoi last wrote it
      (diff/overwrite/all-overwrite/skip/quit)?" and HANGS forever without a
      TTY (stdin closed -> "chezmoi: <target>: EOF", exit 1, file NOT
      overwritten). This is exactly why the tool-side exclusion above is
      mandatory - never rely on chezmoi's own conflict handling.
    - Happy apply: exit 0. Second no-op apply: exit 0, no output.
    - Broken template: error on stderr, exit 1, --keep-going still applies
      the other targets.
    - `chezmoi managed --include=files,symlinks` prints RELATIVE target paths
      (files only - scripts and directories are NOT listed; `managed` without
      the filter DOES list scripts). Works with a missing destination dir.
    - `chezmoi cat <target>` needs the ABSOLUTE path inside the destination
      directory (relative paths resolve against the CWD and fail with "not in
      destination directory", exit 1). Renders from the source state, so it
      works even when the destination file does not exist yet. Broken
      template -> exit 1 + stderr error.
    - `chezmoi target-path <source path>` maps a source path to its absolute
      target path (used for run_* scripts and directories).
    - Selective apply targets MUST be absolute paths inside the destination
      (relative -> "not in destination directory", exit 1); a target not in
      the source -> "not managed", exit 1.
    - The [data] section of chezmoi.toml maps to the TEMPLATE DATA ROOT:
      source templates use {{ .name }}, NOT {{ .data.name }}.
    - run_once_/run_onchange_ script idempotency lives in the persistent
      state bolt DB (run_once runs once ever; run_onchange only when its
      source changed).

  BYTE SAFETY (Oracle r5-M1): `chezmoi cat` output is redirected to a FILE
  via Start-Process -RedirectStandardOutput (the child writes raw bytes -
  no OEM/UTF-16 mangling) and the file is hashed. Any CAPTURED text output
  (managed / apply) is read after [Console]::OutputEncoding = UTF8.

  PS 5.1 process plumbing (verified under powershell.exe 5.1):
    - Start-Process -PassThru ExitCode is ALWAYS $null under PS 5.1 - even
      after WaitForExit(ms) returns true. ONLY Start-Process -Wait -PassThru
      populates it (used for `cat`, which needs no timeout).
    - The apply call (10-minute hard timeout) uses
      [System.Diagnostics.Process]::Start(ProcessStartInfo) +
      WaitForExit(ms) + Kill() on timeout - ExitCode populates correctly.
    - ProcessStartInfo.ArgumentList does NOT exist on .NET Framework
      (PS 5.1) - the argument string is built manually (each arg double-
      quoted, " escaped as \", joined by spaces). Verified with paths
      containing spaces.

  SAFE-SET EMPTY (Oracle M-2): when every managed file is locally modified
  the apply call is SKIPPED entirely and logged. PS 5.1 splats an empty
  array as ZERO arguments, so `chezmoi apply @() ` would be a FULL apply =
  silent overwrite of everything - this must never happen.

  State (user store, State.ps1): on success
    state.dotfiles = { lastSourceHash, at, skipped, files }
  where files maps each APPLIED target's RELATIVE path to the POST-APPLY raw
  sha256 of the destination file (NOT the cat-rendered value - keeping the
  comparison domain consistent with the next round's current-hash check).
  Skipped/failed targets are deliberately NOT recorded in files: recording
  them would make the next round treat the local modification as "last
  applied" and overwrite it. -WhatIf never touches the state.

  Must NOT: never enable the chezmoi symlink feature; never pass --force;
  never run under SYSTEM context (this is a user-context task).
#>

# 10-minute hard timeout for the chezmoi apply process (plan todo 16).
$script:OSyncChezmoiApplyTimeoutMs = 600000

# ---- private helpers --------------------------------------------------------

function ConvertTo-OSyncQuotedArgs {
    <#
      Builds a single command-line argument string for ProcessStartInfo /
      Start-Process -ArgumentList. Each argument is double-quoted and any
      embedded double quote is escaped as \" (the .NET command-line parsing
      rule). ProcessStartInfo.ArgumentList does not exist on .NET Framework,
      so PS 5.1 requires this manual quoting (verified with space-containing
      paths).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgList
    )

    $quoted = foreach ($a in $ArgList) { '"' + $a.Replace('"', '\"') + '"' }
    return ($quoted -join ' ')
}

function Get-OSyncChezmoiCommonArgs {
    <#
      The chezmoi global flags shared by every invocation:
      --source <work>\dotfiles\source, --config <work>\dotfiles\chezmoi.toml,
      --persistent-state <stateDir>\run\chezmoistate.boltdb (FIXED on B,
      Oracle B1), --destination <dest>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [string]$PersistentState,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    return @(
        '--source', $SourceDir,
        '--config', $ConfigFile,
        '--persistent-state', $PersistentState,
        '--destination', $Destination
    )
}

function Invoke-OSyncChezmoiTextCommand {
    <#
      Runs a chezmoi command and captures its stdout/stderr as TEXT.
      [Console]::OutputEncoding is set to UTF8 BEFORE the process starts so
      the captured text decodes correctly (PS 5.1 defaults to the OEM
      codepage). stdin is closed so any interactive prompt fails fast with
      EOF instead of hanging. Returns { ExitCode, Stdout, Stderr }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChezmoiExe,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = 0
    )

    # Captured text must decode as UTF8 (Oracle r5-M1).
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ChezmoiExe
    $psi.Arguments = ConvertTo-OSyncQuotedArgs -ArgList $Arguments
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $p = [System.Diagnostics.Process]::Start($psi)
    # Close stdin: a chezmoi prompt then fails with EOF instead of hanging
    # (observed: apply on a modified target prompts forever without a TTY).
    $p.StandardInput.Close()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()

    $exited = $true
    if ($TimeoutMs -gt 0) {
        $exited = $p.WaitForExit($TimeoutMs)
        if (-not $exited) {
            $p.Kill()
            return [pscustomobject]@{
                ExitCode = -1
                TimedOut = $true
                Stdout   = ''
                Stderr   = "chezmoi process timed out after $TimeoutMs ms and was killed."
            }
        }
    }
    else {
        $null = $p.WaitForExit()
    }

    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        TimedOut = $false
        Stdout   = $outTask.Result
        Stderr   = $errTask.Result
    }
}

function Get-OSyncChezmoiManagedTargets {
    <#
      Files baseline: `chezmoi managed --include=files,symlinks` returns the
      RELATIVE target paths of every managed file/symlink (one per line).
      Scripts are NOT included (product behavior verified: `managed` without
      the filter lists them, with the filter it does not - Oracle M-4 /
      Momus r6-4), so run_* entries are enumerated separately from the source
      dir. Directories are not listed either (only the files inside them).
      Returns an array of relative target paths normalized to backslashes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChezmoiExe,

        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [string]$PersistentState,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    $common = Get-OSyncChezmoiCommonArgs -SourceDir $SourceDir -ConfigFile $ConfigFile -PersistentState $PersistentState -Destination $Destination
    $result = Invoke-OSyncChezmoiTextCommand -ChezmoiExe $ChezmoiExe -Arguments ($common + @('managed', '--include=files,symlinks'))

    if ($result.ExitCode -ne 0) {
        throw "Get-OSyncChezmoiManagedTargets: 'chezmoi managed' failed (exit $($result.ExitCode)): $($result.Stderr)"
    }

    $targets = @()
    foreach ($line in ($result.Stdout -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
            # chezmoi prints forward slashes; normalize for Windows joins.
            $targets += $trimmed.Replace('/', '\')
        }
    }
    return $targets
}

function Get-OSyncChezmoiSourceEntryTargets {
    <#
      Maps source-state entries (run_* scripts and directories) to their
      ABSOLUTE target paths via `chezmoi target-path <source path>`. The
      source-name -> target-name mapping is non-trivial (dot_/private_/
      exact_ prefixes, run_once_/run_onchange_/run_before_/run_after_
      prefixes), so the product's own mapping is used instead of a heuristic.
      Entries whose mapping fails are skipped (returned in $Failed).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChezmoiExe,

        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [string]$PersistentState,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        # Source paths to map. Non-mandatory with an empty default: binding
        # @() to a MANDATORY [string[]] throws ParameterBindingValidation-
        # Exception under PS 5.1, and a source state without scripts or
        # directories legitimately passes an empty list.
        [Parameter(Mandatory = $false)]
        [string[]]$SourcePaths = @()
    )

    $common = Get-OSyncChezmoiCommonArgs -SourceDir $SourceDir -ConfigFile $ConfigFile -PersistentState $PersistentState -Destination $Destination

    $targets = @()
    $failed = @()
    foreach ($srcPath in $SourcePaths) {
        $result = Invoke-OSyncChezmoiTextCommand -ChezmoiExe $ChezmoiExe -Arguments ($common + @('target-path', $srcPath))
        if ($result.ExitCode -ne 0) {
            $failed += [pscustomobject]@{ source = $srcPath; error = $result.Stderr.Trim() }
            continue
        }
        $target = $result.Stdout.Trim()
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            $targets += $target.Replace('/', '\')
        }
    }
    return [pscustomobject]@{ Targets = $targets; Failed = $failed }
}

function Get-OSyncChezmoiRenderedHash {
    <#
      Renders a managed target with `chezmoi cat <absolute target path>` and
      returns the sha256 of the RENDERED content (template source != rendered
      result). BYTE SAFETY (Oracle r5-M1): the output is redirected to a FILE
      via Start-Process -RedirectStandardOutput - the child process writes
      raw bytes, so no OEM/UTF-16 mangling can corrupt the hash. PS 5.1's
      `>` operator would write UTF-16LE and `&` capture would OEM-decode -
      both forbidden here. Returns { Ok, Hash, Error }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChezmoiExe,

        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [string]$PersistentState,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $true)]
        [string]$TargetAbsPath
    )

    $tmpDir = [System.IO.Path]::GetTempPath()
    $tmpOut = Join-Path $tmpDir ('osync-cat-{0}.out' -f [guid]::NewGuid().ToString('N'))
    $tmpErr = Join-Path $tmpDir ('osync-cat-{0}.err' -f [guid]::NewGuid().ToString('N'))
    try {
        $common = Get-OSyncChezmoiCommonArgs -SourceDir $SourceDir -ConfigFile $ConfigFile -PersistentState $PersistentState -Destination $Destination
        $argStr = ConvertTo-OSyncQuotedArgs -ArgList ($common + @('cat', $TargetAbsPath))

        # -Wait is REQUIRED: Start-Process -PassThru ExitCode is $null under
        # PS 5.1 without it (verified). The file redirect is byte-exact.
        $p = Start-Process -FilePath $ChezmoiExe -ArgumentList $argStr `
            -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr `
            -Wait -PassThru -NoNewWindow

        if ($p.ExitCode -ne 0) {
            $errText = ''
            if (Test-Path -LiteralPath $tmpErr -PathType Leaf) {
                $errText = [System.IO.File]::ReadAllText($tmpErr).Trim()
            }
            return [pscustomobject]@{ Ok = $false; Hash = ''; Error = $errText }
        }

        return [pscustomobject]@{ Ok = $true; Hash = (Get-OSyncFileSha256 -Path $tmpOut); Error = '' }
    }
    finally {
        Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OSyncChezmoiApply {
    <#
      The selective apply call:
        chezmoi --source <src> --config <toml> --persistent-state <bolt>
                apply --keep-going <absolute target paths...>
      -WhatIf maps to `apply --dry-run --verbose` (Metis m3).
      NEVER passes --force (Metis M2). Hard 10-minute timeout: on expiry the
      process is killed and the failure is recorded (Momus M1).
      Returns { ExitCode, TimedOut, Stdout, Stderr }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChezmoiExe,

        [Parameter(Mandatory = $true)]
        [string]$SourceDir,

        [Parameter(Mandatory = $true)]
        [string]$ConfigFile,

        [Parameter(Mandatory = $true)]
        [string]$PersistentState,

        [Parameter(Mandatory = $true)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [string[]]$Targets = @(),

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutMs = $script:OSyncChezmoiApplyTimeoutMs
    )

    $common = Get-OSyncChezmoiCommonArgs -SourceDir $SourceDir -ConfigFile $ConfigFile -PersistentState $PersistentState -Destination $Destination
    if ($WhatIf) {
        $arguments = $common + @('apply', '--dry-run', '--verbose')
    }
    else {
        $arguments = $common + @('apply', '--keep-going')
    }
    $arguments += $Targets

    return (Invoke-OSyncChezmoiTextCommand -ChezmoiExe $ChezmoiExe -Arguments $arguments -TimeoutMs $TimeoutMs)
}

# ---- public API -------------------------------------------------------------

function Invoke-OSyncDotfilesApply {
    <#
      Applies the dotfiles source state of a verified work copy to the
      destination (default: $HOME - USER context) with tool-side conflict
      safety. See the module header for the full algorithm and the pinned
      empirical findings.

      Returns a report object:
        { category, status ('ok'|'skipped'|'failed'), sourceHash, at,
          applied[], skipped[], failed[], files{}, dryRun, exitCode, timedOut }
      On success the user store is updated:
        state.dotfiles = { lastSourceHash, at, skipped, files }
      -WhatIf runs `apply --dry-run --verbose` and NEVER touches the state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$WorkDir,

        # B-side config (stateDir + logging). Optional: falls back to
        # <WorkDir>\config\packagesync.json when present (the orchestrator
        # always passes the real B config).
        [Parameter(Mandatory = $false)]
        $Config,

        # Where chezmoi applies to. Defaults to $HOME (user context); QA
        # redirects this to a temp directory.
        [Parameter(Mandatory = $false)]
        [string]$Destination,

        [Parameter(Mandatory = $false)]
        [switch]$WhatIf
    )

    # --- resolve config / stateDir ------------------------------------------
    if ($null -eq $Config) {
        $workConfigPath = Join-Path $WorkDir 'config\packagesync.json'
        if (Test-Path -LiteralPath $workConfigPath -PathType Leaf) {
            $Config = Get-OSyncConfig -Path $workConfigPath
        }
        else {
            throw "Invoke-OSyncDotfilesApply: -Config is required (no config found at '$workConfigPath')."
        }
    }
    $stateDir = [string]$Config.stateDir
    if ([string]::IsNullOrWhiteSpace($stateDir)) {
        throw "Invoke-OSyncDotfilesApply: config.stateDir is empty."
    }
    if ([string]::IsNullOrWhiteSpace($Destination)) {
        $Destination = $HOME
    }

    # --- work copy layout ----------------------------------------------------
    $chezmoiExe = Join-Path $WorkDir 'runtime\chezmoi\chezmoi.exe'
    $sourceDir = Join-Path $WorkDir 'dotfiles\source'
    $configFile = Join-Path $WorkDir 'dotfiles\chezmoi.toml'
    $filesJson = Join-Path $WorkDir 'dotfiles\files.json'
    $persistentState = Join-Path (Join-Path $stateDir 'run') 'chezmoistate.boltdb'

    foreach ($required in @(
            @{ Path = $chezmoiExe; Kind = 'Leaf'; Label = 'chezmoi.exe payload' },
            @{ Path = $sourceDir; Kind = 'Container'; Label = 'dotfiles source state' },
            @{ Path = $configFile; Kind = 'Leaf'; Label = 'chezmoi.toml' },
            @{ Path = $filesJson; Kind = 'Leaf'; Label = 'dotfiles files.json' }
        )) {
        if (-not (Test-Path -LiteralPath $required.Path -PathType $required.Kind)) {
            throw "Invoke-OSyncDotfilesApply: missing $($required.Label) at '$($required.Path)'."
        }
    }

    # --- 1. source hash gate -------------------------------------------------
    # Root hash of the dotfiles files.json: unchanged source state -> skip.
    $sourceHash = Get-OSyncFileSha256 -Path $filesJson
    $state = Get-OSyncState -Category 'dotfiles' -Config $Config
    $lastSourceHash = $null
    if ($null -ne $state.dotfiles -and $state.dotfiles -is [System.Collections.IDictionary]) {
        $lastSourceHash = $state.dotfiles['lastSourceHash']
    }

    if ($null -ne $lastSourceHash -and [string]$lastSourceHash -eq $sourceHash) {
        Write-OSyncLog -Category 'dotfiles' -Level Info -Message "dotfiles apply skipped: source hash unchanged ($sourceHash)." -Data @{ sourceHash = $sourceHash } -Config $Config | Out-Null
        return [pscustomobject]@{
            category   = 'dotfiles'
            status     = 'skipped'
            sourceHash = $sourceHash
            at         = [DateTime]::UtcNow.ToString('o')
            applied    = @()
            skipped    = @()
            failed     = @()
            files      = [ordered]@{}
            dryRun     = [bool]$WhatIf
            exitCode   = $null
            timedOut   = $false
        }
    }

    $hasBaseline = ($null -ne $lastSourceHash) -and
                   ($null -ne $state.dotfiles['files']) -and
                   ($state.dotfiles['files'] -is [System.Collections.IDictionary]) -and
                   ($state.dotfiles['files'].Count -gt 0)
    Write-OSyncLog -Category 'dotfiles' -Level Info -Message "dotfiles apply starting: sourceHash=$sourceHash, hasBaseline=$hasBaseline, whatIf=$WhatIf." -Data @{ sourceHash = $sourceHash; hasBaseline = $hasBaseline; whatIf = [bool]$WhatIf } -Config $Config | Out-Null

    # --- 2. enumerate the managed target set --------------------------------
    # Files baseline: `chezmoi managed --include=files,symlinks` (scripts are
    # NOT included - verified). Scripts (run_*) and directories are added
    # from the source state via `chezmoi target-path`.
    $managedRel = @(Get-OSyncChezmoiManagedTargets -ChezmoiExe $chezmoiExe -SourceDir $sourceDir -ConfigFile $configFile -PersistentState $persistentState -Destination $Destination)

    $scriptSourcePaths = @(Get-ChildItem -LiteralPath $sourceDir -File | Where-Object { $_.Name -like 'run_*' } | ForEach-Object { $_.FullName })
    $dirSourcePaths = @(Get-ChildItem -LiteralPath $sourceDir -Directory -Recurse | ForEach-Object { $_.FullName })

    $scriptMap = Get-OSyncChezmoiSourceEntryTargets -ChezmoiExe $chezmoiExe -SourceDir $sourceDir -ConfigFile $configFile -PersistentState $persistentState -Destination $Destination -SourcePaths $scriptSourcePaths
    $dirMap = Get-OSyncChezmoiSourceEntryTargets -ChezmoiExe $chezmoiExe -SourceDir $sourceDir -ConfigFile $configFile -PersistentState $persistentState -Destination $Destination -SourcePaths $dirSourcePaths

    # --- 3. conflict detection (tool-side guarantee) -------------------------
    # For every managed file: current target hash vs last-applied hash (state)
    # vs freshly rendered source hash (chezmoi cat). Current != both ->
    # locally modified -> excluded + recorded in skipped. Missing target ->
    # safe (chezmoi rebuilds it). Broken template (cat fails) -> excluded +
    # recorded in failed (cannot compute the rendered hash, cannot safely
    # apply).
    $safeTargets = @()
    $skipped = @()
    $failed = @()
    $newHashes = [ordered]@{}

    foreach ($rel in $managedRel) {
        $targetAbs = Join-Path $Destination $rel
        $cat = Get-OSyncChezmoiRenderedHash -ChezmoiExe $chezmoiExe -SourceDir $sourceDir -ConfigFile $configFile -PersistentState $persistentState -Destination $Destination -TargetAbsPath $targetAbs
        if (-not $cat.Ok) {
            $failed += [pscustomobject]@{ target = $rel; error = $cat.Error }
            Write-OSyncLog -Category 'dotfiles' -Level Error -Message "dotfiles: cannot render '$rel' (broken template?) - excluded from this round." -Data @{ target = $rel; error = $cat.Error } -Config $Config | Out-Null
            continue
        }
        $newHashes[$rel] = $cat.Hash

        if (Test-Path -LiteralPath $targetAbs -PathType Leaf) {
            $currentHash = Get-OSyncFileSha256 -Path $targetAbs
            $lastApplied = $null
            if ($hasBaseline) {
                $lastApplied = $state.dotfiles['files'][$rel]
            }

            $locallyModified = $true
            if ($null -ne $lastApplied -and [string]$lastApplied -eq $currentHash) {
                # Matches what we last applied -> safe (chezmoi no-ops it).
                $locallyModified = $false
            }
            elseif ($currentHash -eq $cat.Hash) {
                # Already matches the rendered source -> safe (no-op).
                $locallyModified = $false
            }

            if ($locallyModified) {
                $skipped += $rel
                Write-OSyncLog -Category 'dotfiles' -Level Warning -Message "dotfiles: '$rel' is locally modified (current != last-applied and != source) - excluded from this round." -Data @{ target = $rel; current = $currentHash; lastApplied = $lastApplied; source = $cat.Hash } -Config $Config | Out-Null
                continue
            }
        }
        # Missing target file -> chezmoi default rebuild (Oracle m4).
        $safeTargets += $targetAbs
    }

    # Scripts (run_*) are ALWAYS in the apply set - their idempotency is
    # guaranteed by the persistent state bolt DB (run_once runs once ever,
    # run_onchange only on source change - verified).
    foreach ($t in $scriptMap.Targets) {
        $safeTargets += $t
    }
    foreach ($f in $scriptMap.Failed) {
        $failed += [pscustomobject]@{ target = $f.source; error = $f.error }
    }

    # Non-file entries (directories) are outside the baseline protection:
    # applied directly and noted (Oracle m6/m2).
    foreach ($t in $dirMap.Targets) {
        $safeTargets += $t
    }
    foreach ($f in $dirMap.Failed) {
        $failed += [pscustomobject]@{ target = $f.source; error = $f.error }
    }

    # --- 4. safe-set empty -> skip the apply call entirely -------------------
    # PS 5.1 splats an empty array as ZERO arguments: `chezmoi apply @()`
    # would be a FULL apply = silent overwrite of every managed target
    # (Oracle M-2). This must never happen.
    if ($safeTargets.Count -eq 0) {
        Write-OSyncLog -Category 'dotfiles' -Level Warning -Message "dotfiles: safe set is EMPTY (all managed files locally modified) - apply call skipped, zero changes made." -Data @{ skipped = $skipped; failed = @($failed | ForEach-Object { $_.target }) } -Config $Config | Out-Null

        if (-not $WhatIf) {
            $state.dotfiles = [ordered]@{
                lastSourceHash = $sourceHash
                at             = [DateTime]::UtcNow.ToString('o')
                skipped        = @($skipped)
                files          = [ordered]@{}
            }
            Save-OSyncState -Category 'dotfiles' -State $state -Config $Config | Out-Null
        }

        return [pscustomobject]@{
            category   = 'dotfiles'
            status     = 'ok'
            sourceHash = $sourceHash
            at         = [DateTime]::UtcNow.ToString('o')
            applied    = @()
            skipped    = @($skipped)
            failed     = @($failed)
            files      = [ordered]@{}
            dryRun     = [bool]$WhatIf
            exitCode   = $null
            timedOut   = $false
        }
    }

    # --- 5. execute the selective apply --------------------------------------
    $applyResult = Invoke-OSyncChezmoiApply -ChezmoiExe $chezmoiExe -SourceDir $sourceDir -ConfigFile $configFile -PersistentState $persistentState -Destination $Destination -Targets $safeTargets -WhatIf:$WhatIf

    if ($applyResult.TimedOut) {
        Write-OSyncLog -Category 'dotfiles' -Level Error -Message "dotfiles: chezmoi apply TIMED OUT after $script:OSyncChezmoiApplyTimeoutMs ms - process killed, state NOT updated (retry next round)." -Config $Config | Out-Null
        return [pscustomobject]@{
            category   = 'dotfiles'
            status     = 'failed'
            sourceHash = $sourceHash
            at         = [DateTime]::UtcNow.ToString('o')
            applied    = @()
            skipped    = @($skipped)
            failed     = @($failed)
            files      = [ordered]@{}
            dryRun     = [bool]$WhatIf
            exitCode   = -1
            timedOut   = $true
        }
    }

    if ($applyResult.ExitCode -ne 0) {
        Write-OSyncLog -Category 'dotfiles' -Level Error -Message "dotfiles: chezmoi apply failed (exit $($applyResult.ExitCode)) - state NOT updated (retry next round)." -Data @{ exitCode = $applyResult.ExitCode; stderr = $applyResult.Stderr } -Config $Config | Out-Null
        return [pscustomobject]@{
            category   = 'dotfiles'
            status     = 'failed'
            sourceHash = $sourceHash
            at         = [DateTime]::UtcNow.ToString('o')
            applied    = @()
            skipped    = @($skipped)
            failed     = @($failed)
            files      = [ordered]@{}
            dryRun     = [bool]$WhatIf
            exitCode   = $applyResult.ExitCode
            timedOut   = $false
        }
    }

    Write-OSyncLog -Category 'dotfiles' -Level Info -Message "dotfiles: chezmoi apply succeeded (exit 0)." -Data @{ targets = @($safeTargets) } -Config $Config | Out-Null

    # --- 6. record state -----------------------------------------------------
    # files records the POST-APPLY raw sha256 of each applied destination
    # file (NOT the cat-rendered value) - keeping the comparison domain
    # consistent with the next round's current-hash check (Oracle r5-M1).
    # Skipped/failed targets are deliberately absent from files: recording a
    # locally-modified file's hash would make the next round treat it as
    # "last applied" and overwrite it. Scripts/dirs never materialize as
    # files, so the Test-Path -PathType Leaf filter keeps them out too.
    $appliedRel = @()
    foreach ($t in $safeTargets) {
        if ($t.StartsWith($Destination, [System.StringComparison]::OrdinalIgnoreCase)) {
            $appliedRel += $t.Substring($Destination.Length).TrimStart('\')
        }
    }
    $postApplyFiles = [ordered]@{}
    foreach ($rel in $appliedRel) {
        $targetAbs = Join-Path $Destination $rel
        if (Test-Path -LiteralPath $targetAbs -PathType Leaf) {
            $postApplyFiles[$rel] = Get-OSyncFileSha256 -Path $targetAbs
        }
    }

    if (-not $WhatIf) {
        $state.dotfiles = [ordered]@{
            lastSourceHash = $sourceHash
            at             = [DateTime]::UtcNow.ToString('o')
            skipped        = @($skipped)
            files          = $postApplyFiles
        }
        Save-OSyncState -Category 'dotfiles' -State $state -Config $Config | Out-Null
        Write-OSyncLog -Category 'dotfiles' -Level Info -Message "dotfiles: state updated (lastSourceHash=$sourceHash, applied=$($postApplyFiles.Count), skipped=$($skipped.Count))." -Data @{ sourceHash = $sourceHash; appliedCount = $postApplyFiles.Count; skipped = @($skipped) } -Config $Config | Out-Null
    }

    return [pscustomobject]@{
        category   = 'dotfiles'
        status     = 'ok'
        sourceHash = $sourceHash
        at         = [DateTime]::UtcNow.ToString('o')
        applied    = @($safeTargets)
        skipped    = @($skipped)
        failed     = @($failed)
        files      = $postApplyFiles
        dryRun     = [bool]$WhatIf
        exitCode   = $applyResult.ExitCode
        timedOut   = $false
    }
}