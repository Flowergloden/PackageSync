# Proposal

## Why

B 端安装 portable winget 包（`InstallerType: zip` + `NestedInstallerType: portable`，如
`OpenAI.Codex`、`BurntSushi.ripgrep.MSVC`、`SST.opencode`）时，machine scope 需要写 HKLM
Uninstall 项与 `C:\Program Files\WinGet\Links`。在无提权 token / SYSTEM 主体下这些写入被拒
（`0x80070005`），安装失败；失败残留的机器级 ARP 项使后续尝试升级为
`0x8A150057`（PORTABLE_UNINSTALL_FAILED），持续毒化重试。B 端实测另有机器级**空 ARP 键**残留
（如 `OpenAI.Codex__DefaultSource`：`PortableInstaller` 构造期先建键、随后写值被拒），令后续
machine-scope 尝试直接抛 `0x8A150054`（PORTABLE_PACKAGE_ALREADY_EXISTS）并长期卡死；因 054
天然只可能来自 portable，把它纳入同一条 user-scope 降级白名单即可绕过（user scope 读写 HKCU
同名键，跨 hive 不复用坏键）。

现有 scope 兜底恰好绕开这一类：A 端导出只在「找不到适用的安装程序」时重试 user scope，B 端
apply 只在 manifest 声明 `Scope: user` 或类型为 MSIX/AppX 时覆盖 user scope；portable 两条都
不命中，于是每次都以 machine scope 硬失败，且 B 端无任何自愈路径。

## What Changes

- B 端 winget apply 对 **portable 包**新增反应式 scope 降级：machine scope 首次尝试因权限/portable
  类错误失败时，先做一次 best-effort 的残破状态清理（L1），再以 user scope 重试一次。
- 新增失败码识别：仅对 `0x80070005` / `0x8A150052` / `0x8A150054` / `0x8A150057` 触发降级；确定性错误
  （版本不存在、无适用安装器等）不触发。
- 降级严格门控在 portable 类型：MSI/EXE 的权限类失败不重试（user scope 救不了）。
- apply 报告与日志记录 scope 降级事实（两次 exit code、`ScopeAttempts`、`ScopeFallback`）。
- 不改全局 `winget.scope` 默认值；不改变非 portable 包的现有行为；不引入预防性清理（保持对
  健康已装包的幂等/修复语义）。
- README 补充 portable 降级语义与 profile 可见性 caveat。

## Capabilities

### New Capabilities
- `winget-install-scope`: 定义 PakageSync 在 B 端如何为 winget 安装选择与降级 scope，包括
  portable 包在 machine scope 权限失败时的 user scope 降级、残破状态清理与报告语义。

### Modified Capabilities
<!-- 项目当前 openspec/specs 为空，无既有 capability 需要修改 -->

## Impact

- 代码：`src/lib/Winget.Common.ps1`（新增类型/失败码纯函数）、`src/lib/WingetApply.ps1`
  （per-package 循环新增 attempt 助手、L1 清理、user 重试与报告字段）。
- 测试：`tests/WingetApply.Tests.ps1`（新增降级/门控/清理不阻断用例）。
- 文档：`README.md`（已知限制新增 portable 降级条目，4.1 scope 说明补充）。
- 运行时行为仅影响 B 端 portable 包在默认 machine scope 下的失败路径；不影响 A 端导出、其他
  类别（pip/npm/dotfiles）与成功路径。
- 风险边界：user scope 落在任务主体对应的 profile；若 packages 任务为 SYSTEM 主体，alias/PATH
  会写入 SYSTEM profile 而非日常用户（详见 design.md 风险节）。