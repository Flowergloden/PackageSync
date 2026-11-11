# Proposal

## Why

当前默认导出每轮都在共享 UNC staging 中全量构建新代，winget 的既有复用也只减少下载，不减少复制；B 端只要任一类别 pending，就复制所有启用类别和 runtime。日常同步因此反复传输大量未变化的 winget 安装器，交换带宽和 B 端本地复制已成为明显瓶颈。

## What Changes

- 将 A 端逐代 staging、`.verdaccio-a` 和可复用载荷缓存放在 A 本地，共享路径只承载正式发布仓库。
- A 端发布时依据现有 `files.json` 的相对路径、字节数和 SHA256 识别新增、变化和删除文件，仅写入实际变化内容，并保持 `index.json` 最后发布。
- 当本轮全部交付文件内容与已发布仓库一致时，不更新 `index.json`、不产生新代，也不触发 B 端新应用轮次。
- B 端按各类别自己的 `lastApplied` 和已验证工作副本确定基线，生成 `delta`、`full` 或 `skip` 复制计划；基线不可用或不受信任时自动回退全量。
- B 端不再因单个类别 pending 而复制所有启用类别；runtime 按漂移、bootstrap 和工具交付需求纳入计划。
- winget 支持文件级 delta：仅从 repo 复制新增或变化的 YAML、安装器及依赖文件，未变化文件从已验证基线通过 NTFS 硬链接复用，失败时回退复制；删除文件不进入新工作副本。
- 新工作副本在逻辑上保持完整，使现有 winget 安装、runtime 包布局、本地 HTTP 服务和校验路径继续消费相同目录结构。
- 导出与 apply 报告记录实际复制、复用、删除的字节数和文件数，以及全量回退原因，便于验证优化效果。
- 保持现有 `index.json → files.json → 逐文件 SHA256` 信任链、B 端复制后校验和单向离线边界不变。

## Capabilities

### New Capabilities

- `incremental-repository-export`: A 端本地暂存、基于内容哈希的增量发布、无变化不发布及发布量观测。
- `delta-work-copy`: B 端按实际应用基线生成复制计划，并为 winget 物化逻辑完整的文件级 delta 工作副本。

### Modified Capabilities

无。既有 `winget-install-scope` 的安装与降级要求不变。

## Impact

- A 端导出编排、winget/runtime 复用来源、pip/npm/dotfiles 的本地暂存，以及正式仓库发布流程。
- B 端 apply 工作副本创建、状态基线解析、winget 文件复制与复核、runtime/bootstrap 衔接和清理流程。
- `config/packagesync.json` 的 A 端 `stagingRoot` 部署值；不新增外部服务或第三方依赖。
- 相关 Pester 单元测试、端到端测试、导出/apply 报告和 README 运维说明。
- 既有 SMB 单向镜像服务不在本变更实现范围内；本变更保证正式仓库中的未变化文件不被 A 端重写，使支持文件级增量的镜像服务能够只同步变化内容。
