# Design

## Context

B 端 winget apply 的现状（`src/lib/WingetApply.ps1` per-package 循环）：

- 一律以 `config.winget.scope`（默认 `machine`）调用
  `winget install --manifest <staging> --scope <scope> ...`。
- scope 覆盖只存在两条路径，且都绕开 portable：
  - `Test-OSyncWingetNeedsUserScope`（`Winget.Common.ps1`）只匹配 manifest 声明
    `Scope: user` 或 `InstallerType: msix|appx`；
  - A 端导出端的 machine→user 重试只针对「找不到适用的安装程序」。
- 离线仓 6 个 portable 包（`ast-grep.ast-grep`、`BurntSushi.ripgrep.MSVC`、
  `jftuga.less`、`OpenAI.Codex`、`SST.opencode`、`twpayne.chezmoi`）manifest 均无
  `Scope:` 字段，故全部走 machine scope 且无兜底。

winget 侧事实（对照 `microsoft/winget-cli` 源码核实）：

- portable 在 machine scope 下写 `HKLM\...\Uninstall`（ARP）、
  `C:\Program Files\WinGet\Links`、机器 PATH（HKLM Environment）、
  `C:\Program Files\WinGet\Packages`；user scope 对应 `HKCU` +
  `%LOCALAPPDATA%\Microsoft\WinGet\{Links,Packages}`。
- `PortableInstaller::Install()` 在 install 操作时**先** `RegisterARPEntry()`
  （写 HKLM），因此机器级权限缺失时首个写入即抛 `0x80070005`。
- `0x8A150057` = `PORTABLE_UNINSTALL_FAILED`，出现在卸载/状态回滚路径；用户报告
  「反复失败后升级到 0x8A150057」，说明上一轮在机器级留下了需被卸载的残破状态。
- `0x8A150054` = `PORTABLE_PACKAGE_ALREADY_EXISTS`，由 `VerifyPackageAndSourceMatch` 在
  「产品码 ARP 键已存在、但其 `WinGetPackageIdentifier` 与当前 manifest 不符」时抛出；
  `PortableInstaller` 构造期的 `Key::Create` 会先建键、随后写值失败，故机器级残留的空键
  （如 `OpenAI.Codex__DefaultSource`）会让此后每次 machine-scope 尝试立即 054。user scope
  读写 HKCU 同名键、跨 hive 不复用坏键，因此降级可绕过，且 054 天然只来自 portable。

约束：B 端 packages 任务主体可为 `SYSTEM`（默认）或管理员 `User`（S4U/Highest 降级），
见 `Register-SyncTasks.ps1`。user scope 写入落在**任务主体对应的 profile**。

## Goals / Non-Goals

**Goals:**

- portable 包在 machine scope 因权限失败时自动降级 user scope，使 6 个 CLI 包不再整体卡死。
- 降级只对 portable 且只对权限/portable 类错误触发，不削弱其他包的现有行为。
- 降级前 best-effort 清理残破状态，且清理失败不阻断重试。
- 降级事实在报告/日志可观测。

**Non-Goals:**

- 不改变全局 `winget.scope` 默认值，不改变 A 端导出行为。
- 不做预防性清理（不在首次 machine 尝试前清理），以保留对健康已装包的幂等/修复语义。
- 不实现「让 machine scope 真正成功」的治本方案（principal/token 提权），该根因单列风险。
- 不改变非 portable 包、pip/npm/dotfiles 类别。

## Decisions

### D1. 反应式降级（失败后重试），而非主动把 portable 一律定为 user scope

失败后才降级，保留 machine 为默认。**备选**：把 `Test-OSyncWingetNeedsUserScope` 扩展成
「portable 一律 user」。否决原因：若任务主体是 SYSTEM，主动 user scope 会把 alias/PATH 写进
SYSTEM profile，是「静默装错 profile」而非修复；反应式降级只在 machine 确实失败时才触发，
且失败本身即证明 machine 路径不可用。

### D2. 降级门控三元条件：portable 类型 + 权限/portable 类错误 + 当前 attempt 为 machine

三者同时满足才重试。**理由**：MSI/EXE 的 `0x80070005` 用 user scope 救不了，重试只会多一次
无意义失败（与既有「确定性错误不重试」原则一致）。

### D3. 识别函数下沉到 `Winget.Common.ps1`

新增 `Test-OSyncWingetIsPortable -PackageDir`（匹配 `InstallerType: portable` 或
`NestedInstallerType: portable`）与 `Test-OSyncWingetNeedsUserScopeRetry -ExitCode [-Output]`
（命中 `-2147024891` / `-1978335150` / `-1978335148` / `-1978335145`，附 locale 容错文本兜底）。
**理由**：与既有 `Test-OSyncWingetNeedsUserScope`、`Test-OSyncWingetDownloadRetryable`
并列，纯函数、可单测，且被 B 端 apply 复用。

### D4. L1 清理用 `winget uninstall --product-code`，产品码从 ARP 注册表读取

清理 = 对该包 best-effort 执行一次卸载，以清掉机器级/用户级残破 ARP 与索引。优先
`--product-code <GUID>`：离线 B 无 source，`--id` 可能因 source 解析失败而无效。GUID 通过
**只读**扫描 `HKLM\...\Uninstall\*` 与 `HKCU\...\Uninstall\*`，匹配 `WinGetPackageIdentifier`
等于该包 Id，取子键名；读注册表通常不需提权。查不到产品码时回退 `--id`。
**备选**：直接删注册表键 + 目录（L2）。否决为首选：触碰 HKLM/Program Files、误伤真实旧装
风险高，且与 winget 逻辑重复；仅在 L1 仍失败时作为人工补救项记入文档。

### D5. 清理只发生在重试路径上，且永不阻断

清理失败（很可能仍是同一 access denied）仅记日志，继续 user 重试。**理由**：清不掉机器级
残破是预期内的；user scope 会另建 `HKCU`/`%LOCALAPPDATA%` 状态，不依赖机器级残破被清除。
同时避免预防性清理破坏健康包的幂等。

### D6. 循环内抽 attempt 助手，避免重复 args 构造与结果分类

把「构造 `--scope` 相关 args → 调用 `Invoke-OSyncWingetInstall` → 分类 ok/satisfied/failed」
抽成内部小助手，使同一包可跑两次。**理由**：现有失败分支逻辑（UAC hint、tail 截断、
state 写入）必须两条路径共用，避免复制粘贴漂移。

### D7. 报告向后兼容地增字段

`ok` 条目新增可选 `Scope`、`ScopeFallback`；`failed` 条目新增可选 `ScopeAttempts`。
不删既有字段（`Id/Version/Sha256/ExitCode`、`Id/ExitCode/Output`），保持既有消费者兼容。

## Risks / Trade-offs

- **[真因未除] →** A+L1 是止血：machine scope 失败的根因是 principal/token 无权写
  HKLM/Program Files。**缓解**：该风险单独登记为 README 已知限制（L27），并建议排查
  packages 任务主体（SYSTEM vs 管理员 S4U/Highest），与既有 L18（SYSTEM 下 winget 异常）关联。
- **[装错 profile] →** 若任务主体为 SYSTEM，user scope 落到 SYSTEM profile，日常用户看不到
  alias/PATH。**缓解**：报告/日志显式记录降级与最终 scope；README L27 明确该 caveat，并指出
  正确 principal 才是治本。
- **[清理无效] →** 同一权限既然拦住写入，也多半拦住删除，L1 对机器级残破常无效。
  **缓解**：D5 明确规定「清理失败不阻断」，重试价值来自 user scope 另建状态。
- **[双重安装路径] →** `chezmoi` 既在 winget portable 又在 bootstrap 落到 `<stateDir>`，
  排查时易互相掩盖。**缓解**：README L27 提示。
- **[报告消费者] →** 新增字段若被严格 schema 校验会受影响。**缓解**：D7 只增可选字段。

## Migration Plan

- 纯 B 端行为增强，无数据迁移；state 记录格式不变。
- 发布后无需重跑 bootstrap；下一轮 packages 任务自然对仍失败的 portable 包降级。
- 回滚：还原 `Winget.Common.ps1` / `WingetApply.ps1` / README 三处即可；无持久化副作用。

## Open Questions

- 无阻塞性未决项。Q1/Q2/Q3 已在 D3/D4/D5 决议：清理走 `--product-code`（回退 `--id`）、
  产品码读 ARP 子键、清理仅置于重试路径。