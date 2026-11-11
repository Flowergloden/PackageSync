# Design

## Context

当前 A 配置把 `stagingRoot` 和 `repoRoot` 都指向 UNC。导出编排每次创建空的新时间戳目录，winget 复用和 `-SkipRuntime` 也从已发布仓库复制完整载荷；发布后还保留三代共享 staging。B 的 packages round 以时间戳判断所有类别是否 pending，任一类别 pending 就复制 runtime 与所有启用类别，再全量复核。

现有 `files.json` 已提供相对路径、字节数和 SHA256，可同时作为 A 发布差异与 B 工作副本差异的内容依据。B 的 `lastApplied` 按类别记录，且旧工作副本已有 `.verified` 验证标记。实现必须继续支持 Windows PowerShell 5.1，不引入外部服务或新依赖。

## Goals / Non-Goals

**Goals:**

- A 的构建、暂存和复用主要发生在本地，共享仓库仅接收实际变化。
- 内容未变化时不推进正式仓库代；部分类别变化时不重写其他类别。
- B 按内容而非仅按时间戳选择类别，并为 winget 建立文件级 delta。
- winget 新工作副本保持逻辑完整，继续兼容安装器、本地 HTTP、runtime ID 排除和 dotfiles 消费方式。
- 首版保持现有工作副本全量哈希复核，以复制字节数为主要优化指标。

**Non-Goals:**

- 不修改既有 SMB 单向镜像服务，不承诺该服务一定具备块级或文件级 delta 能力。
- 不实现 pip、npm、dotfiles 或 runtime 的文件级 delta；这些类别 pending 时仍使用完整类别复制。
- 不优化首次 bootstrap 或 bootstrap self-heal 的独立工作副本；其首版继续全量复制。
- 不采用整仓压缩、安装器二进制差分或内容寻址仓库重构。
- 不改变 winget 安装 scope、包卸载语义或既有信任根结构。

## Decisions

### 1. A 使用本地 NTFS staging 和本地先前成功代

将默认 A 配置的 `stagingRoot` 改为本地 NTFS 路径（默认规划为 `C:\PakageSync-staging`，部署可覆盖），`repoRoot` 保持现有共享 UNC。`.verdaccio-a` 因位于 `stagingRoot` 下而自然留在本地，无需新增配置键。

winget 复用和 `-SkipRuntime` 优先选择本地最新成功导出代。候选代必须存在且其导出报告显示成功；缺失或不可用时保留一次从 `repoRoot` 回退复用的能力，用于首次迁移和本地缓存丢失后的恢复。后续成功代继续保留三代，但这些代不再占共享空间。

备选方案是只改 `stagingRoot` 而继续从共享 `repoRoot` 复用；该方案会把未变化载荷变成共享→A 的全量读取，因此不采用。

### 2. 消除报告和 npm 运行元数据造成的伪变化

winget 和 pip 的类别导出报告目前包含带新代时间戳的绝对 staging 路径，会使无变化比较始终失败。将这些报告写到本代本地 `<staging>\reports\` 下，不再写入 `<staging>\winget` 或 `<staging>\pip`，也不发布到正式仓库。B 端 apply 不消费这两份报告，现有诊断内容保留在 A 本地。

现有发布 E2E 还证明 npm storage 的 `.verdaccio-db.json` 会生成随机 secret，包 `package.json` 的 `_rev`/presence 也可能随一次性实例变化。最终生成清单前，若当前 npm 的包清单、tarball 集合及其哈希与本地先前成功代一致，则从这些先前代恢复对应 Verdaccio 数据库和包元数据，使本轮继续代表同一份冻结 registry 内容；tarball 或包清单有实际变化时使用本轮元数据。没有本地先前代时不做该稳定化处理。

无变化比较使用解析后的文件映射，而非 JSON 文本字节或序列化顺序。临时路径、耗时、报告生成时间和上述已稳定的运行元数据不参与交付内容判断。

### 3. A 发布采用计划驱动的逐类别内容差异

发布前为每个当前类别生成计划：

- `copy`：当前新增，或相对已发布清单字节数/SHA256 变化的文件。
- `reuse`：清单内容相同且正式仓库目标仍存在、长度一致的文件。
- `delete`：已发布清单存在而当前清单不存在的文件。

已发布索引或类别清单缺失、不可解析时，该类别回退全量发布。正常增量路径不重新读取并哈希全部未变化远端文件，否则会把写入瓶颈转化为共享读取瓶颈；B 的既有完整性校验仍是远端损坏的最终门禁。

执行顺序为：复制当前新增/变化载荷，移除 `delete` 文件，写入变化类别的当前 `files.json`，所有类别成功后最后写入 `index.json`。无 `copy`/`delete` 的类别复用已发布的 `files.json` 和旧索引类别记录，避免 JSON 序列化差异或已稳定的 npm 元数据让 B 误判内容变化；变化类别使用新清单记录。任一必要步骤失败则本轮失败且不写入新索引；旧索引与未完成新内容并存时，B 的既有完整性检查会拒绝不一致类别。

若所有类别计划均无 `copy`/`delete`，返回 `success=true`、`published=false`、`noOp=true`，保留原 `index.json` 和 `exportedAtUtc`。入口脚本仍以 `success` 映射退出码，因此无变化导出返回 0。

备选方案是 robocopy `/MIR` 加时间戳规则；它无法识别“内容相同但时间戳更新”的 pip/npm/runtime 文件，因此不采用。

### 4. B 先按内容决定类别是否真正 pending

保留 `lastApplied` 指向实际成功应用且存在验证基线的代。对当前索引较新的类别：

1. 解析该类 `lastApplied` 对应的 `work\<ts>\.verified` 和类别 `files.json`。
2. 若当前索引记录的类别清单哈希与基线 `files.json` 哈希一致，计划为 `skip`，不复制、不安装，也不推进 `lastApplied`。
3. 内容不同且基线有效时，winget 为 `delta`，其他类别为 `full`。
4. 内容不同但基线不存在、未验证或不可解析时，该类为 `full` 并记录原因。

不推进内容等价类别的 `lastApplied` 是关键：否则它会指向一个未创建的新 work 目录，下一轮反而失去 delta 基线。packages 和独立 dotfiles round 共用这一内容等价判断，避免 packages 未复制未变化 dotfiles 后，user round 仍试图从新 work 应用它。

工作副本清理除保留最新两代外，还必须保留 system/user state 中各类 `lastApplied` 引用的已验证代。保留集合按类别有限，避免长期未变化类别的基线被其他类别的频繁更新清除。

### 5. winget delta 物化为逻辑完整目录

当前 winget `files.json` 是目标文件集合，基线 `files.json` 是复用来源。新 work 不按 `packages.txt` 筛选，因此普通包、依赖子目录及 runtime winget 包都包含在同一算法中。

对当前清单逐项处理：

- 新增/变化：从当前 repo 复制到目标相对路径。
- 未变化：优先对基线文件创建 NTFS 硬链接；失败则从基线复制，基线文件不可用时从当前 repo 复制。
- 基线有而当前没有：不创建目标文件。
- 当前类别 `files.json` 本身从当前 repo 复制，作为目标验证清单。

硬链接只用于 `stateDir\work` 内被视为不可变的已验证代。首版继续调用现有工作副本全量复核，对所有目标文件检查当前清单，因而无需为“复用文件免哈希”引入新的信任例外。未来若要省略基线文件哈希，应另立变更并明确验证语义。

备选方案是让 winget apply 直接消费 delta-only 目录。该方案需要改变安装器、HTTP 服务和 runtime 消费契约，也不能推广到当前 npm `/MIR` 与 pip 完整 wheel repo，因此不采用。

### 6. 首版保留 runtime 与 bootstrap 的保守路径

常规 packages work 代仍完整复制 runtime，以支持 winget 的 runtime ID 排除、dotfiles 的 chezmoi、自刷新和失败恢复；但只有实际内容 pending 的启用类别才加入该 work 代。winget 使用 delta，其他 pending 类别完整复制。

首次 bootstrap 和 runtime 漂移触发的 self-heal 仍先走其现有独立全量工作副本。这样不会改变 bootstrap 的执行顺序和运行时交付保证；其优化不是解决日常 winget 瓶颈的前置条件。

### 7. 计划与报告提供可核验指标

A 导出报告按类别记录 `copiedFiles/copiedBytes`、`reusedFiles/reusedBytes`、`deletedFiles/deletedBytes`、发布模式和回退原因。

B 在本代根目录写本地 `copy-plan.json`，并在 apply 结果和日志中记录每类 `mode`、`baseExportedAtUtc`、复制/复用/删除统计及回退原因。该文件只是 B 本地运维产物，不进入类别 `files.json`，也不成为新的信任根。

## Risks / Trade-offs

- [正式仓库中同尺寸但已损坏的未变化文件可能被复用] → 复用至少要求旧清单匹配、目标存在且长度一致；B 在每轮安装前执行完整性检查并拒绝损坏类别，必要时通过全量恢复路径重建。
- [增量发布中途失败会留下旧索引与部分新载荷] → 继续以索引最后写入和 B 完整性门禁保护；下一轮重试同一当前代可补齐缺失文件。
- [硬链接会让新旧 work 共享物理内容] → work 代按不可变快照管理并沿用 ACL；首版全量复核可发现目标内容不符合当前清单，安装流程不得写入包体文件。
- [内容等价类别不推进 `lastApplied` 会让时间戳持续显旧] → 报告明确区分内容等价与落后；清理保护真实基线，避免后续无谓全量。
- [首版仍全量读取工作副本做哈希] → 本轮只承诺复制字节下降；哈希 I/O 优化留待后续，避免同时扩大信任语义变化。
- [既有 SMB 服务若总是全量镜像，共享→B 网络量仍可能不下降] → A 保证不重写未变化文件并输出发布统计；是否需显式 delta 传输通道由外部服务能力另行决定。

## Migration Plan

1. 更新 A 配置到本地 NTFS `stagingRoot`，首次运行允许从现有共享仓库回退复用并建立本地成功代。
2. 启用本地报告布局和哈希发布；仓库索引及类别清单 schema 不变，旧 B 工具仍能读取。
3. 通过既有 `runtime\tool` 自刷新交付新 B apply；升级那一次允许按旧逻辑全量复制。
4. 在 B 首轮新逻辑中，缺少适用基线的类别全量复制，后续 winget 自动进入 delta。
5. 回滚时可恢复旧脚本和 A 配置。新仓库仍保持旧目录与索引契约，硬链接 work 对旧工具表现为普通文件；回滚只会恢复全量复制，不需要状态迁移。
