# Tasks

## 1. A 端本地暂存、复用与稳定交付内容

- [x] 1.1 将默认 A 配置的 `stagingRoot` 改为本地 NTFS 路径并更新部署说明；验证：`tests/Config.Tests.ps1` 覆盖新默认值，README 明确 staging/`.verdaccio-a` 不再写共享路径，相关测试通过。
- [x] 1.2 实现本地最新成功导出代解析，并让 winget 复用与 `-SkipRuntime` 优先使用该代、缺失时才回退 `repoRoot`；验证：`tests/WingetExport.Tests.ps1` 和 `tests/ExportOrchestrator.Tests.ps1` 覆盖本地命中、共享回退及损坏本地代，运行两套 Pester 测试通过。
- [x] 1.3 将 winget/pip 类别报告移至本代本地 `reports`，并在 npm 包清单和 tarball 未变时复用先前成功代的 Verdaccio 数据库与包元数据；验证：相关导出单测证明报告不进入类别清单、相同 tarball 不产生随机元数据差异、实际 tarball 变化时保留本轮元数据，并更新 README 报告位置说明。

## 2. A 端内容级增量发布

- [x] 2.1 实现按类别解析当前/已发布 `files.json` 的 `copy`、`reuse`、`delete` 计划和字节统计；验证：在 `tests/ExportOrchestrator.Tests.ps1` 覆盖同内容不同时间戳、新增、变化、删除、目标缺失及旧清单损坏回退，测试通过。
- [x] 2.2 用发布计划替换逐类别 robocopy `/MIR`，仅复制变化载荷并删除失效文件；未变化类别复用旧 `files.json` 与索引记录，变化类别更新清单且 `index.json` 最后写入；验证：单测检查实际写入文件集合、旧索引类别记录保留、复制/删除失败时不写新索引，测试通过。
- [x] 2.3 实现全类别无变化时 `success=true`、`published=false`、`noOp=true`，保持正式 `index.json` 和 `exportedAtUtc` 不变，并在报告/日志输出发布统计与回退原因；验证：入口退出码、索引内容/mtime 和统计字段均有测试，README 说明无变化导出语义，相关测试通过。

## 3. B 端内容感知计划与类别级选择

- [x] 3.1 实现按类别解析 `lastApplied`、`.verified` 和基线 `files.json` 的计划器，以当前索引类别哈希识别内容等价 `skip`，并供 packages 与 dotfiles round 共用；验证：`tests/ApplyOrchestrator.Tests.ps1` 覆盖不同类别不同基线、跨多代更新、内容等价不复制/不安装/不虚推进 `lastApplied`，测试通过。
- [x] 3.2 修改 packages 工作副本创建，使其仅包含 runtime 与实际内容 pending 的类别，非 winget pending 类别继续完整复制；验证：单测证明仅 winget 变化时 pip/npm/dotfiles 不复制，npm 与 winget 同时 pending 时 npm 仍完整，runtime 和自刷新消费路径不缺失，测试通过。
- [x] 3.3 修改 work 清理，在保留最新两代之外保护 system/user state 中各类 `lastApplied` 引用的已验证基线；验证：单测覆盖多轮其他类别更新、失败类别旧基线和基线已缺失时的 full 回退，测试通过并更新 README 的保留策略。

## 4. B 端 winget 文件级 delta 工作副本

- [x] 4.1 实现 winget 物化器：新增/变化文件从当前 repo 复制，未变化文件优先硬链接到基线，依次回退基线复制和 repo 复制，删除文件不进入新代；验证：`tests/ApplyOrchestrator.Tests.ps1` 使用真实临时文件覆盖单安装器更新、仅 YAML 变化、依赖/包删除、硬链接失败及 runtime winget 文件保留，并断言从 repo 复制的字节数，测试通过。
- [x] 4.2 将 winget 物化器接入工作副本创建，继续执行现有全量哈希复核，并写出本地 `copy-plan.json` 与各类复制/复用/删除统计；验证：损坏变化文件会删除或隔离新代且不写 `.verified`、不推进 `lastApplied`，有效 delta 代保持逻辑完整且统计准确，测试通过。
- [x] 4.3 更新 README 的 B 端 delta 行为、首次/基线失效全量回退、首版仍全量哈希及 bootstrap 不优化边界；验证：文档命令与报告字段和实现一致，`tests/Readme.Tests.ps1` 及相关文档检查通过。

## 5. 跨端集成与回归验证

- [x] 5.1 更新 `tests/e2e/Invoke-E2EPublish.ps1` 的重复导出断言：第二次无变化发布不再推进索引，再制造单个 winget 文件变化以验证仅该类别发布及统计；验证：以隔离 landing 运行 `powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e\Invoke-E2EPublish.ps1 -SkipScheduledTask -SkipFailureScenario`，完整性检查与新增断言通过。
- [x] 5.2 扩展 winget/apply 集成场景，连续建立两代且仅变化一个安装器或 YAML，验证 B 端从 repo 的实际复制量、硬链接/回退、完整校验和现有安装结果；验证：运行相应 `tests/e2e/Invoke-E2EWinget.ps1` 隔离场景，证据显示未变化 winget 文件未从 repo 复制且安装成功。
- [x] 5.3 执行完整单元回归并检查变更交付物；验证：`powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester tests -PassThru"` 全部通过，上述 E2E 证据无失败，且未遗留测试日志、临时任务或计划外生成文件。验收备注：最终回归 667 通过、1 个既有 `ManifestGenerate.Tests.ps1:861` chezmoi 候选计数失败；用户明确接受该失败并决定后续单独修复，临时任务、规则、进程与测试日志均已清理。
