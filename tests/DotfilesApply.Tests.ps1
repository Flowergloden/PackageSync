#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 unit tests for src\lib\DotfilesApply.ps1 - the B-side dotfiles
    apply via chezmoi (USER context, conflict-safe).

.DESCRIPTION
    The chezmoi process boundary is MOCKED (Invoke-OSyncChezmoiTextCommand /
    Invoke-OSyncChezmoiApply / Get-OSyncChezmoiRenderedHash / Start-Process) -
    unit tests never run the real chezmoi.exe; the real binary is exercised
    in the QA evidence run. State.ps1 and the file hashing are REAL, running
    under $TestDrive only - the real state dir is never touched.

    Two top-level Describes:
      - 'DotfilesApply'            : Invoke-OSyncDotfilesApply integration
                                     (mocked chezmoi boundary) + the managed /
                                     source-entry helpers.
      - 'DotfilesApply - plumbing' : the raw process helpers (byte-exact cat
                                     redirect, apply arg assembly, quoting).
                                     Kept separate so the integration
                                     BeforeEach mocks cannot intercept them.

    Run:
      powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\DotfilesApply.Tests.ps1 -PassThru"
      pwsh      -NoProfile -Command "Invoke-Pester tests\DotfilesApply.Tests.ps1 -PassThru"

.NOTES
    Pester 5 runs BeforeAll/It in their own script scopes: the lib files are
    dot-sourced and helper functions are defined INSIDE BeforeAll; data shared
    with the It blocks uses $script: scope (same pattern as the other test
    files in this plan). Mocks are (re)established in BeforeEach so every It
    gets a fresh invocation history.
#>

Describe 'DotfilesApply' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')

        # --- fixture work copy (what the packages task would have built) ---
        $script:WorkDir = Join-Path $TestDrive 'work'
        $script:SourceDir = Join-Path $script:WorkDir 'dotfiles\source'
        New-Item -ItemType Directory -Path $script:SourceDir -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'dot_plain.txt') -Value 'source content' -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'run_once_hello.ps1') -Value "Write-Output 'hi'" -Encoding UTF8 -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:SourceDir '.chezmoiscripts') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceDir '.chezmoiscripts\run_foo.ps1') -Value "Write-Output 'foo'" -Encoding UTF8 -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:SourceDir 'dot_confdir') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:SourceDir 'dot_confdir\settings.txt') -Value 'setting=1' -Encoding UTF8 -NoNewline
        New-Item -ItemType Directory -Path (Join-Path $script:WorkDir 'dotfiles') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkDir 'dotfiles\chezmoi.toml') -Value '[data]' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:WorkDir 'dotfiles\files.json') -Value '{"dot_plain.txt":{"sha256":"x"}}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:WorkDir 'runtime\chezmoi') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkDir 'runtime\chezmoi\chezmoi.exe') -Value 'fake chezmoi binary' -Encoding ASCII
        $script:SourceHash = Get-OSyncFileSha256 -Path (Join-Path $script:WorkDir 'dotfiles\files.json')

        # --- minimal work copy (files only, no scripts/dirs) for the
        #     safe-set-empty scenario ---
        $script:WorkDirMin = Join-Path $TestDrive 'work-min'
        New-Item -ItemType Directory -Path (Join-Path $script:WorkDirMin 'dotfiles\source') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkDirMin 'dotfiles\source\dot_plain.txt') -Value 'source content' -Encoding UTF8 -NoNewline
        Set-Content -LiteralPath (Join-Path $script:WorkDirMin 'dotfiles\chezmoi.toml') -Value '[data]' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:WorkDirMin 'dotfiles\files.json') -Value '{"dot_plain.txt":{"sha256":"x"}}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $script:WorkDirMin 'runtime\chezmoi') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:WorkDirMin 'runtime\chezmoi\chezmoi.exe') -Value 'fake chezmoi binary' -Encoding ASCII
        $script:SourceHashMin = Get-OSyncFileSha256 -Path (Join-Path $script:WorkDirMin 'dotfiles\files.json')

        $script:DestDir = Join-Path $TestDrive 'dest'
        New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null
        $script:StateDir = Join-Path $TestDrive 'state'
        $script:Config = [pscustomobject]@{
            role     = 'B'
            stateDir = $script:StateDir
            repoRoot = $TestDrive
        }

        # --- helpers -----------------------------------------------------
        function Set-OTestState {
            # Pre-populates the user store's dotfiles category. The default
            # lastSourceHash is a FAKE previous-generation hash (all-zero
            # hex): a baseline only exists when the source has CHANGED since
            # the last apply, so it must differ from the current files.json
            # hash or the source-hash gate would skip the round.
            param(
                [hashtable]$Files = @{},
                [string]$LastSourceHash = ('0' * 64),
                [string[]]$Skipped = @()
            )
            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles = [ordered]@{
                lastSourceHash = $LastSourceHash
                at             = '2026-09-04T00:00:00.0000000Z'
                skipped        = @($Skipped)
                files          = [ordered]@{}
            }
            foreach ($k in $Files.Keys) {
                $state.dotfiles.files[$k] = $Files[$k]
            }
            Save-OSyncState -Category 'dotfiles' -State $state -StateDir $script:StateDir | Out-Null
        }

        function Get-OTestRenderedHash {
            # The hash the rendered-hash mock returns for a target rel path:
            # sha256 of the UTF-8 (no BOM) string "rendered:<rel>".
            param([string]$Rel)
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('osync-test-rh-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
            try {
                [System.IO.File]::WriteAllText($tmp, "rendered:$Rel", (New-Object System.Text.UTF8Encoding($false)))
                return (Get-OSyncFileSha256 -Path $tmp)
            }
            finally {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }

        function Invoke-OTestThrowing {
            param([scriptblock]$ScriptBlock)
            $caught = $null
            try { & $ScriptBlock }
            catch { $caught = $_ }
            return $caught
        }
    }

    BeforeEach {
        # Fresh per-test state: reset the user store and the destination.
        Remove-Item -LiteralPath $script:StateDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:DestDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $script:DestDir -Force | Out-Null

        $script:ApplyCalls = @()
        $script:ApplyWhatIf = $false
        $script:ApplyExitCode = 0
        $script:ApplyTimedOut = $false
        $script:ManagedOutput = ".plain.txt`n.confdir/settings.txt`n"

        # chezmoi text commands (managed / target-path) - mocked.
        Mock Invoke-OSyncChezmoiTextCommand {
            param($ChezmoiExe, $Arguments, $TimeoutMs)
            if ($Arguments -contains 'managed') {
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = $script:ManagedOutput; Stderr = '' }
            }
            if ($Arguments -contains 'target-path') {
                $idx = [Array]::IndexOf($Arguments, 'target-path')
                $src = $Arguments[$idx + 1]
                $rel = $src.Substring($script:SourceDir.Length).TrimStart('\')
                # chezmoi maps the LAST path segment: dot_ -> ., run_once_/run_onchange_/
                # run_before_/run_after_ -> '', plain run_ -> '' (verified
                # v2.72.0, incl. .chezmoiscripts\run_* -> .chezmoiscripts\<name>).
                $leaf = Split-Path -Leaf $rel
                $mappedLeaf = $leaf -replace '^dot_', '.' -replace '^run_(once|onchange|before|after)_', '' -replace '^run_', ''
                $parent = Split-Path -Parent $rel
                $mappedRel = if ([string]::IsNullOrWhiteSpace($parent)) { $mappedLeaf } else { Join-Path $parent $mappedLeaf }
                $target = Join-Path $script:DestDir $mappedRel
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = $target; Stderr = '' }
            }
            throw "unexpected chezmoi text command: $($Arguments -join ' ')"
        }

        # The apply call - mocked. Records the target set it was given and
        # MATERIALIZES the targets as files (simulating what chezmoi does),
        # so the post-apply hash recording has real files to hash. Existing
        # files/dirs are left untouched (a no-op apply must not rewrite).
        Mock Invoke-OSyncChezmoiApply {
            param($ChezmoiExe, $SourceDir, $ConfigFile, $PersistentState, $Destination, $Targets, $WhatIf, $TimeoutMs)
            $script:ApplyCalls += , @($Targets)
            $script:ApplyWhatIf = [bool]$WhatIf
            foreach ($t in @($Targets)) {
                if (Test-Path -LiteralPath $t -PathType Container) { continue }
                if (-not (Test-Path -LiteralPath $t -PathType Leaf)) {
                    $parent = Split-Path -Parent $t
                    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                        New-Item -ItemType Directory -Path $parent -Force | Out-Null
                    }
                    [System.IO.File]::WriteAllText($t, "applied:$([System.IO.Path]::GetFileName($t))", (New-Object System.Text.UTF8Encoding($false)))
                }
            }
            return [pscustomobject]@{ ExitCode = $script:ApplyExitCode; TimedOut = $script:ApplyTimedOut; Stdout = ''; Stderr = '' }
        }

        # Rendered source hash: sha256 of "rendered:<rel>" (UTF-8 no BOM).
        Mock Get-OSyncChezmoiRenderedHash {
            param($ChezmoiExe, $SourceDir, $ConfigFile, $PersistentState, $Destination, $TargetAbsPath)
            $rel = $TargetAbsPath.Substring($Destination.Length).TrimStart('\')
            return [pscustomobject]@{ Ok = $true; Hash = (Get-OTestRenderedHash -Rel $rel); Error = '' }
        }
    }

    Context 'Invoke-OSyncDotfilesApply - source hash gate' {
        It 'skips the whole round when lastSourceHash matches (no apply call)' {
            Set-OTestState -Files @{} -LastSourceHash $script:SourceHash
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'skipped'
            $report.sourceHash | Should -Be $script:SourceHash
            $script:ApplyCalls.Count | Should -Be 0
        }

        It 'throws when chezmoi.exe is missing from the work copy' {
            $bad = Join-Path $TestDrive 'work-noexe'
            New-Item -ItemType Directory -Path (Join-Path $bad 'dotfiles\source') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bad 'dotfiles\source\dot_plain.txt') -Value 'x' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bad 'dotfiles\chezmoi.toml') -Value '[data]' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bad 'dotfiles\files.json') -Value '{}' -Encoding UTF8
            $err = Invoke-OTestThrowing { Invoke-OSyncDotfilesApply -WorkDir $bad -Config $script:Config -Destination $script:DestDir }
            $err.Exception.Message | Should -BeLike '*chezmoi.exe*'
        }

        It 'throws when dotfiles files.json is missing' {
            $bad = Join-Path $TestDrive 'work-nofilesjson'
            New-Item -ItemType Directory -Path (Join-Path $bad 'dotfiles\source') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bad 'dotfiles\source\dot_plain.txt') -Value 'x' -Encoding UTF8
            Set-Content -LiteralPath (Join-Path $bad 'dotfiles\chezmoi.toml') -Value '[data]' -Encoding UTF8
            New-Item -ItemType Directory -Path (Join-Path $bad 'runtime\chezmoi') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $bad 'runtime\chezmoi\chezmoi.exe') -Value 'fake' -Encoding ASCII
            $err = Invoke-OTestThrowing { Invoke-OSyncDotfilesApply -WorkDir $bad -Config $script:Config -Destination $script:DestDir }
            $err.Exception.Message | Should -BeLike '*files.json*'
        }
    }

    Context 'Invoke-OSyncDotfilesApply - happy path' {
        It 'applies all managed files plus scripts and dirs, then records state' {
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'ok'
            $report.skipped.Count | Should -Be 0
            $report.failed.Count | Should -Be 0

            $script:ApplyCalls.Count | Should -Be 1
            $targets = $script:ApplyCalls[0]
            $targets | Should -Contain (Join-Path $script:DestDir '.plain.txt')
            $targets | Should -Contain (Join-Path $script:DestDir '.confdir\settings.txt')
            # run_* scripts are ALWAYS in the apply set (idempotency via the
            # persistent state bolt DB).
            $targets | Should -Contain (Join-Path $script:DestDir 'hello.ps1')
            # non-file entries (dirs) are applied directly and noted.
            $targets | Should -Contain (Join-Path $script:DestDir '.confdir')

            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.lastSourceHash | Should -Be $script:SourceHash
            $state.dotfiles.files['.plain.txt'] | Should -Not -BeNullOrEmpty
            $state.dotfiles.files['.confdir\settings.txt'] | Should -Not -BeNullOrEmpty
            $state.dotfiles.skipped.Count | Should -Be 0
        }

        It 'includes .chezmoiscripts\run_* scripts in the apply set and excludes the dir itself' {
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'ok'
            $targets = $script:ApplyCalls[0]
            # .chezmoiscripts\run_foo.ps1 maps to <dest>\.chezmoiscripts\foo.ps1
            # (verified v2.72.0) and must enter the apply set.
            $targets | Should -Contain (Join-Path $script:DestDir '.chezmoiscripts\foo.ps1')
            # The .chezmoiscripts DIRECTORY itself is not a managed target -
            # applying it fails with 'not managed' (verified v2.72.0).
            $targets | Should -Not -Contain (Join-Path $script:DestDir '.chezmoiscripts')
        }

        It 'records the POST-APPLY raw file hash, not the rendered value' {
            # Destination file exists with content that differs from the
            # rendered source; baseline says we applied exactly that content.
            $appliedContent = 'applied content'
            $plainPath = Join-Path $script:DestDir '.plain.txt'
            [System.IO.File]::WriteAllText($plainPath, $appliedContent, (New-Object System.Text.UTF8Encoding($false)))
            $appliedHash = Get-OSyncFileSha256 -Path $plainPath
            Set-OTestState -Files @{ '.plain.txt' = $appliedHash }

            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'ok'

            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.files['.plain.txt'] | Should -Be $appliedHash
            # ... and NOT the cat-rendered value (comparison domain stays
            # consistent: current-hash vs last-applied-hash).
            $state.dotfiles.files['.plain.txt'] | Should -Not -Be (Get-OTestRenderedHash -Rel '.plain.txt')
        }
    }

    Context 'Invoke-OSyncDotfilesApply - conflict safety' {
        It 'excludes a locally modified file (baseline present) and records it in skipped' {
            $plainPath = Join-Path $script:DestDir '.plain.txt'
            [System.IO.File]::WriteAllText($plainPath, 'applied content', (New-Object System.Text.UTF8Encoding($false)))
            $appliedHash = Get-OSyncFileSha256 -Path $plainPath
            Set-OTestState -Files @{ '.plain.txt' = $appliedHash }
            # local modification AFTER the baseline was recorded
            [System.IO.File]::WriteAllText($plainPath, 'LOCAL EDIT', (New-Object System.Text.UTF8Encoding($false)))

            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'ok'
            $report.skipped | Should -Contain '.plain.txt'

            $targets = $script:ApplyCalls[0]
            $targets | Should -Not -Contain $plainPath
            # other files still applied
            $targets | Should -Contain (Join-Path $script:DestDir '.confdir\settings.txt')

            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.skipped | Should -Contain '.plain.txt'
            # the locally modified file must NOT be recorded in files - that
            # would make the next round treat it as "last applied" and
            # overwrite the local edit.
            $state.dotfiles.files.Keys | Should -Not -Contain '.plain.txt'
        }

        It 'first run (no baseline): pre-existing different-content file is skipped + reported' {
            [System.IO.File]::WriteAllText((Join-Path $script:DestDir '.plain.txt'), 'user file', (New-Object System.Text.UTF8Encoding($false)))

            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.skipped | Should -Contain '.plain.txt'
            $script:ApplyCalls[0] | Should -Not -Contain (Join-Path $script:DestDir '.plain.txt')
        }

        It 'first run (no baseline): pre-existing file matching the source is safe (no-op)' {
            [System.IO.File]::WriteAllText((Join-Path $script:DestDir '.plain.txt'), 'rendered:.plain.txt', (New-Object System.Text.UTF8Encoding($false)))

            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.skipped | Should -Not -Contain '.plain.txt'
            $script:ApplyCalls[0] | Should -Contain (Join-Path $script:DestDir '.plain.txt')
        }

        It 'missing target file is safe (chezmoi rebuilds it)' {
            # destination is empty - .plain.txt does not exist
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.skipped.Count | Should -Be 0
            $script:ApplyCalls[0] | Should -Contain (Join-Path $script:DestDir '.plain.txt')
        }

        It 'broken template (cat fails) is excluded and recorded in failed' {
            Mock Get-OSyncChezmoiRenderedHash {
                param($ChezmoiExe, $SourceDir, $ConfigFile, $PersistentState, $Destination, $TargetAbsPath)
                $rel = $TargetAbsPath.Substring($Destination.Length).TrimStart('\')
                if ($rel -eq '.plain.txt') {
                    return [pscustomobject]@{ Ok = $false; Hash = ''; Error = 'template: function "bad" not defined' }
                }
                return [pscustomobject]@{ Ok = $true; Hash = (Get-OTestRenderedHash -Rel $rel); Error = '' }
            }

            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.failed | Where-Object { $_.target -eq '.plain.txt' } | Should -Not -BeNullOrEmpty
            $script:ApplyCalls[0] | Should -Not -Contain (Join-Path $script:DestDir '.plain.txt')
            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.files.Keys | Should -Not -Contain '.plain.txt'
        }

        It 'safe set EMPTY -> apply call skipped entirely, state still updated' {
            # minimal work copy: files only (no scripts/dirs), the only file
            # locally modified -> safe set would be empty.
            $script:ManagedOutput = ".plain.txt`n"
            [System.IO.File]::WriteAllText((Join-Path $script:DestDir '.plain.txt'), 'user file', (New-Object System.Text.UTF8Encoding($false)))
            Mock Invoke-OSyncChezmoiApply { throw 'apply must not be called when the safe set is empty' }

            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDirMin -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'ok'
            $report.skipped | Should -Contain '.plain.txt'
            $report.applied.Count | Should -Be 0

            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.lastSourceHash | Should -Be $script:SourceHashMin
            $state.dotfiles.files.Count | Should -Be 0
            $state.dotfiles.skipped | Should -Contain '.plain.txt'
        }
    }

    Context 'Invoke-OSyncDotfilesApply - apply failures' {
        It 'apply exit != 0 -> status failed, state NOT updated (retry next round)' {
            $script:ApplyExitCode = 1
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'failed'
            $report.exitCode | Should -Be 1
            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.lastSourceHash | Should -BeNullOrEmpty
        }

        It 'apply timeout -> status failed, timedOut, state NOT updated' {
            $script:ApplyTimedOut = $true
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir
            $report.status | Should -Be 'failed'
            $report.timedOut | Should -BeTrue
            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.lastSourceHash | Should -BeNullOrEmpty
        }
    }

    Context 'Invoke-OSyncDotfilesApply - WhatIf' {
        It 'maps to dry-run and NEVER touches the state' {
            $report = Invoke-OSyncDotfilesApply -WorkDir $script:WorkDir -Config $script:Config -Destination $script:DestDir -WhatIf
            $report.status | Should -Be 'ok'
            $report.dryRun | Should -BeTrue
            $script:ApplyWhatIf | Should -BeTrue
            $state = Get-OSyncState -Category 'dotfiles' -StateDir $script:StateDir
            $state.dotfiles.lastSourceHash | Should -BeNullOrEmpty
        }
    }

    Context 'Get-OSyncChezmoiManagedTargets' {
        It 'parses managed output into normalized relative target paths' {
            $targets = Get-OSyncChezmoiManagedTargets -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd'
            $targets | Should -Contain '.plain.txt'
            $targets | Should -Contain '.confdir\settings.txt'
            $targets.Count | Should -Be 2
        }

        It 'throws when chezmoi managed fails' {
            Mock Invoke-OSyncChezmoiTextCommand {
                return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'boom' }
            }
            $err = Invoke-OTestThrowing { Get-OSyncChezmoiManagedTargets -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' }
            $err.Exception.Message | Should -BeLike '*boom*'
        }
    }

    Context 'Get-OSyncChezmoiSourceEntryTargets' {
        It 'maps source paths to absolute target paths via target-path' {
            Mock Invoke-OSyncChezmoiTextCommand {
                param($Arguments)
                $idx = [Array]::IndexOf($Arguments, 'target-path')
                $src = $Arguments[$idx + 1]
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = "$src-target"; Stderr = '' }
            }
            $r = Get-OSyncChezmoiSourceEntryTargets -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -SourcePaths @('a', 'b')
            $r.Targets | Should -Contain 'a-target'
            $r.Targets | Should -Contain 'b-target'
            $r.Failed.Count | Should -Be 0
        }

        It 'records failed mappings instead of throwing' {
            Mock Invoke-OSyncChezmoiTextCommand {
                param($Arguments)
                $idx = [Array]::IndexOf($Arguments, 'target-path')
                $src = $Arguments[$idx + 1]
                if ($src -eq 'bad') {
                    return [pscustomobject]@{ ExitCode = 1; TimedOut = $false; Stdout = ''; Stderr = 'not managed' }
                }
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = "$src-target"; Stderr = '' }
            }
            $r = Get-OSyncChezmoiSourceEntryTargets -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -SourcePaths @('good', 'bad')
            $r.Targets | Should -Contain 'good-target'
            $r.Failed.Count | Should -Be 1
            $r.Failed[0].source | Should -Be 'bad'
        }

        It 'accepts an empty SourcePaths list (no scripts/dirs in the source)' {
            $r = Get-OSyncChezmoiSourceEntryTargets -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -SourcePaths @()
            $r.Targets.Count | Should -Be 0
            $r.Failed.Count | Should -Be 0
        }
    }
}

Describe 'DotfilesApply - process plumbing' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '..\src\lib\Util.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Logging.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\Config.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\State.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesExport.ps1')
        . (Join-Path $PSScriptRoot '..\src\lib\DotfilesApply.ps1')
    }

    Context 'Get-OSyncChezmoiRenderedHash - byte safety' {
        It 'hashes the RAW redirected bytes (no text decoding in between)' {
            Mock Start-Process {
                param($RedirectStandardOutput, $RedirectStandardError)
                # "hello" as raw bytes - exactly what the child would write
                [System.IO.File]::WriteAllBytes($RedirectStandardOutput, [byte[]](0x68, 0x65, 0x6C, 0x6C, 0x6F))
                return [pscustomobject]@{ ExitCode = 0 }
            }
            $r = Get-OSyncChezmoiRenderedHash -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -TargetAbsPath 't'
            $r.Ok | Should -BeTrue
            $r.Hash | Should -Be '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
        }

        It 'returns Ok=false with the stderr text when cat fails' {
            Mock Start-Process {
                param($RedirectStandardOutput, $RedirectStandardError)
                [System.IO.File]::WriteAllText($RedirectStandardError, 'template: function "bad" not defined', (New-Object System.Text.UTF8Encoding($false)))
                return [pscustomobject]@{ ExitCode = 1 }
            }
            $r = Get-OSyncChezmoiRenderedHash -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -TargetAbsPath 't'
            $r.Ok | Should -BeFalse
            $r.Error | Should -BeLike '*function "bad" not defined*'
        }
    }

    Context 'Invoke-OSyncChezmoiApply' {
        It 'assembles apply --keep-going with the absolute target set' {
            Mock Invoke-OSyncChezmoiTextCommand {
                param($Arguments)
                $script:CapturedArgs = $Arguments
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = ''; Stderr = '' }
            }
            $null = Invoke-OSyncChezmoiApply -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -Targets @('t1', 't2')
            $script:CapturedArgs | Should -Contain 'apply'
            $script:CapturedArgs | Should -Contain '--keep-going'
            $script:CapturedArgs | Should -Contain 't1'
            $script:CapturedArgs | Should -Contain 't2'
            $script:CapturedArgs | Should -Not -Contain '--force'
        }

        It 'WhatIf maps to apply --dry-run --verbose (never --keep-going)' {
            Mock Invoke-OSyncChezmoiTextCommand {
                param($Arguments)
                $script:CapturedArgs = $Arguments
                return [pscustomobject]@{ ExitCode = 0; TimedOut = $false; Stdout = ''; Stderr = '' }
            }
            $null = Invoke-OSyncChezmoiApply -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd' -Targets @('t1') -WhatIf
            $script:CapturedArgs | Should -Contain '--dry-run'
            $script:CapturedArgs | Should -Contain '--verbose'
            $script:CapturedArgs | Should -Not -Contain '--keep-going'
        }

        It 'propagates the timeout result' {
            Mock Invoke-OSyncChezmoiTextCommand {
                return [pscustomobject]@{ ExitCode = -1; TimedOut = $true; Stdout = ''; Stderr = 'timed out' }
            }
            $r = Invoke-OSyncChezmoiApply -ChezmoiExe 'x' -SourceDir 's' -ConfigFile 'c' -PersistentState 'p' -Destination 'd'
            $r.TimedOut | Should -BeTrue
        }
    }

    Context 'ConvertTo-OSyncQuotedArgs' {
        It 'double-quotes every argument (space-safe)' {
            ConvertTo-OSyncQuotedArgs -ArgList @('a b', 'c') | Should -Be '"a b" "c"'
        }
    }
}