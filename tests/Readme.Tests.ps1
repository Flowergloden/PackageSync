#Requires -Version 5.1
# Readme.Tests.ps1 - Pester 5 tests asserting README.md contains every mandatory
# section heading required by plan todo 19 (运维手册 README).
#
# QA seam (failure scenario): set $env:OSYNC_README_PATH to a modified copy of
# README.md (e.g. one section deleted) and the assertions must fail - proving
# the assertions actually bite.

Describe 'README.md mandatory sections (plan todo 19)' {
    BeforeAll {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $envOverride = [Environment]::GetEnvironmentVariable('OSYNC_README_PATH')
        $readmePath = if ($envOverride) { $envOverride } else { Join-Path $repoRoot 'README.md' }
        $readmePath = [System.IO.Path]::GetFullPath($readmePath)
        if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
            throw "README not found at '$readmePath'"
        }
        $script:ReadmePath = $readmePath
        $script:ReadmeContent = [System.IO.File]::ReadAllText($readmePath)

        # NOTE: these arrays MUST live in BeforeAll as $script: vars - Pester 5
        # runs It blocks via Invoke-InNewScriptScope, so Context-level variables
        # are invisible inside It (a vacuous-passing assertion trap).
        $script:Headings = @(
            '## 一、架构总览',
            '## 二、威胁模型',
            '## 三、首次部署',
            '## 四、清单编辑指南',
            '## 五、运维手册',
            '## 六、已知限制',
            '### 3.1 A 端（外网机）',
            '### 3.2 B 端（内网机）',
            '### 3.3 降级路径：SYSTEM 主体 winget 不可用',
            '### 4.1 winget 白名单（manifests\winget-packages.txt）',
            '### 4.2 pip requirements.txt（manifests\requirements.txt）',
            '### 4.3 npm 清单（manifests\npm-packages.txt）',
            '### 4.4 chezmoi dotfiles 源态（manifests\dotfiles\）',
            '### 5.1 日志位置',
            '### 5.2 手动运行：-WhatIf 与 -Category',
            '### 5.3 dotfiles 冲突处理（skipped）',
            '### 5.4 下载失败（UA-403）与 Microsoft Store 应用限制',
            '### 5.5 端口占用处理（8788 / 4873 / 4874）',
            '### 5.6 运行时钉版重钉流程（PIN-ME）',
            '### 5.7 工具本体到 B 的部署渠道（runtime\tool → C:\PakageSync\）'
        )
        $script:Limitations = @(
            'L1. winget 包依赖离线解析仅经合成 fixture 验证',
            'L2. SYSTEM 上下文需机器级 VC_redist',
            'L3. LocalManifestFiles 为 per-user 设置',
            'L4. winget 版 Python 的 PATH 注册由 bootstrap 步骤③显式验证',
            'L5. 离线 B 上 winget source 更新超时只记日志',
            'L6. VC_redist 可接受退出码 {0, 3010, 1638}',
            'L7. 端口 8788/4873/4874 为双端一致常量',
            'L8. B 端 `C:\PakageSync\config` 归本地所有',
            'L9. chezmoi 首轮语义',
            'L10. 升级运行时钉版后 B 须手动重跑 bootstrap',
            'L11. App Installer 安装链已移除（2026-09 决策）',
            'L12. B 端首次引导必须先手工复制 runtime\tool',
            'L13. SYSTEM 自愈 bootstrap 路径未经完整 QA',
            'L14.（todo-10 QA）App Installer 依赖版本缺口：已随安装链移除而解决（2026-09 决策）',
            'L15.（todo-13 QA）`winget install --manifest <dir>` 拒绝非 YAML 文件/子目录'
        )
    }

    Context 'mandatory section headings' {
        It 'contains every mandatory section heading' {
            $missing = @($script:Headings | Where-Object { -not $script:ReadmeContent.Contains($_) })
            $missing | Should -BeNullOrEmpty
        }
    }

    Context 'known limitations - every item must appear' {
        It 'contains every known-limitation item' {
            $missing = @($script:Limitations | Where-Object { -not $script:ReadmeContent.Contains($_) })
            $missing | Should -BeNullOrEmpty
        }
    }

    Context 'CLI surface matches on-disk scripts / plan-pinned CLI' {
        It 'documents A-side export CLI (Export-OfflineRepo.ps1)' {
            $script:ReadmeContent | Should -Match 'Export-OfflineRepo\.ps1'
            $script:ReadmeContent | Should -Match '-ConfigPath'
            $script:ReadmeContent | Should -Match '-Category winget,pip,npm,dotfiles'
        }
        It 'documents B-side bootstrap CLI (Install-OfflineBootstrap.ps1)' {
            $script:ReadmeContent | Should -Match 'Install-OfflineBootstrap\.ps1'
            $script:ReadmeContent | Should -Match '-WhatIf'
        }
        It 'documents task registration CLI (Register-SyncTasks.ps1)' {
            $script:ReadmeContent | Should -Match 'Register-SyncTasks\.ps1 -Role A'
            $script:ReadmeContent | Should -Match 'Register-SyncTasks\.ps1 -Role B'
            $script:ReadmeContent | Should -Match '-PackagesTaskPrincipal'
        }
        It 'documents apply CLI (Invoke-OfflineApply.ps1 -Category/-WhatIf)' {
            $script:ReadmeContent | Should -Match 'Invoke-OfflineApply\.ps1'
            $script:ReadmeContent | Should -Match '-WhatIf'
            $script:ReadmeContent | Should -Match '-Category'
        }
        It 'documents the B-side log location C:\ProgramData\PakageSync\run\logs' {
            $script:ReadmeContent | Should -Match 'C:\\ProgramData\\PakageSync\\run\\logs'
        }
    }
}
