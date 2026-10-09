# Tasks

## 1. 共享识别函数（Winget.Common.ps1）

- [x] 1.1 新增 `Test-OSyncWingetIsPortable -PackageDir`：在包目录 `*.yaml` 中匹配 `InstallerType:\s*portable` 或 `NestedInstallerType:\s*portable`；验证：对 zip+portable 清单返回 `$true`，对 wix/inno/msix 清单返回 `$false`。
- [x] 1.2 新增 `Test-OSyncWingetNeedsUserScopeRetry -ExitCode [-Output]`：命中 `-2147024891`（0x80070005）、`-1978335150`（0x8A150052）、`-1978335148`（0x8A150054）、`-1978335145`（0x8A150057），并附 locale 容错文本兜底；验证：四个码各自返回 `$true`，`0` 与版本不存在/无适用安装器返回 `$false`。
- [x] 1.3 在 `tests/WingetApply.Tests.ps1` 为本组两个函数补单测并运行 `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests\WingetApply.Tests.ps1 -PassThru"` 通过。

## 2. 循环内 attempt 助手与降级接线（WingetApply.ps1）

- [x] 2.1 把「构造 `--scope` 相关 args → `Invoke-OSyncWingetInstall` → 分类 ok/satisfied/timedout/failed」抽成内部助手，保持 UAC hint、tail 截断、state 写入逻辑单一实现；验证：既有 exit-code 映射单测全绿（行为无回归）。
- [x] 2.2 在 per-package 失败分支前置降级判断：`Test-OSyncWingetIsPortable` 且 `Test-OSyncWingetNeedsUserScopeRetry` 且当前 attempt scope 为 machine 时进入降级路径；验证：非 portable 的 `0x80070005` 仅一次调用且记 failed。
- [x] 2.3 降级路径执行 user scope 重试（同 `$manifestDir`，`--scope user`）；成功写入 state 与 ok 条目，失败记 failed 并保留两次尝试；验证：首调用返 `-2147024891`、次调用返 `0` 时 ok 数量为 1，且 fake winget 记录的第二条命令含 `--scope user`。
- [x] 2.4 降级路径不修改 `winget.scope` 配置，不影响非 portable 包与成功路径；验证：新增单测覆盖 2.2/2.3 场景并断言配置对象未被改写，运行 `Invoke-Pester tests\WingetApply.Tests.ps1 -PassThru` 通过。

## 3. L1 残破状态清理（WingetApply.ps1）

- [x] 3.1 新增产品码解析：只读扫描 `HKLM\...\Uninstall\*` 与 `HKCU\...\Uninstall\*` 子键，匹配 `WinGetPackageIdentifier` 等于该包 Id 取子键名；验证：对合成注册表快照/注入的桩数据返回期望 GUID，查不到时返回 `$null`。
- [x] 3.2 在降级路径、user 重试之前执行 best-effort 卸载（优先 `uninstall --product-code <GUID>`，回退 `--id`），吞错并只记日志；验证：清理调用也返 `0x80070005` 时 user 重试仍发生且最终结果按 user 尝试判定。
- [x] 3.3 断言清理不发生于成功路径（无预防性清理）；验证：machine 首次成功的用例中断言未出现 `uninstall` 调用，`Invoke-Pester tests\WingetApply.Tests.ps1 -PassThru` 通过。

## 4. 报告与日志字段（WingetApply.ps1）

- [x] 4.1 ok 条目新增可选 `Scope` 与 `ScopeFallback`；failed 条目新增可选 `ScopeAttempts`（含两次 scope 与退出码），不删既有字段；验证：降级成功用例的 ok 条目含降级标记，两次均失败的用例含 `ScopeAttempts`。
- [x] 4.2 日志记录首次 machine 尝试的退出码与最终成功 scope；验证：运行 `Invoke-Pester tests\WingetApply.Tests.ps1 -PassThru` 通过，抽查 JSONL 日志含降级相关条目。

## 5. 文档（README.md）

- [x] 5.1 在「六、已知限制」新增 L27：portable machine-scope 失败自动降级 user scope、L1 清理为 best-effort、**profile 可见性 caveat**（SYSTEM 主体下 user scope 落到 SYSTEM profile）、与 L18 的关联、以及 chezmoi 双重安装路径提示；验证：README 渲染与现有 L1–L26 编号连续。
- [x] 5.2 在 4.1 scope 说明处补充 portable 降级分支（现仅描述 MSIX/AppX 与 A 端 machine→user 下载重试）；验证：文档描述与 spec/design 一致。

## 6. 集成验证

- [x] 6.1 运行完整 `Invoke-Pester tests\WingetApply.Tests.ps1 -PassThru` 与 `Invoke-Pester tests\WingetExport.Tests.ps1 -PassThru`，确认无回归；验证：两套测试全绿。
- [x] 6.2 用假 winget 跑一次「portable 首次 machine 失败 → 清理 → user 成功」的端到端口径用例，确认报告与日志可观测降级；验证：产出报告含 `ScopeFallback=$true` 且日志含两次尝试。

## 7. 0x8A150054 回退白名单扩展（B 端实测补充）

- [x] 7.1 将 `-1978335148`（0x8A150054 PORTABLE_PACKAGE_ALREADY_EXISTS）加入 `Test-OSyncWingetNeedsUserScopeRetry`（数字白名单 + hex 文本兜底），并同步该函数描述与 `WingetApply.ps1` 头注释错误码枚举；验证：`tests/WingetApply.Tests.ps1` 新增 054 断言且整套测试全绿。
- [x] 7.2 README 第 4.1 节与 L27 的 portable 降级错误码枚举补 `0x8A150054`；验证：文档枚举与 spec/design 一致。

## Workflow follow-up

- 本变更归档后，若其名字被某线程卷宗的 `## Changes` 列表引用，按线程看板约定三从其提案/设计/任务蒸馏一段总结追加到该线程 `## 已完成的工作`。