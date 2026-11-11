# Spec Delta

## Purpose

让 B 端依据各类别实际应用状态选择性创建工作副本，并对 winget 仅复制变化的安装器和清单文件，同时保留现有安装器所需的完整目录语义与校验边界。

## ADDED Requirements

### Requirement: 按 B 端实际基线生成类别复制计划

系统 SHALL 对每类分别使用其 `lastApplied` 对应的已验证工作副本作为 delta 基线，并输出 `delta`、`full` 或 `skip` 计划；MUST NOT 假设 B 已应用 A 的上一代。

#### Scenario: 不同类别停留在不同代数

- **WHEN** winget 已应用 G10、npm 因失败仍停留在 G7，而当前仓库为 G12
- **THEN** winget 计划以 G10 为基线
- **AND** npm 计划以 G7 为基线或按基线可用性回退全量

#### Scenario: 未 pending 类别不复制

- **WHEN** 仅 winget 在当前代 pending
- **THEN** 系统不因本轮 winget 更新复制未 pending 的 pip、npm 或 dotfiles 类别

### Requirement: 内容未变化类别不重复复制或应用

当索引时间戳较新但某类当前 `files.json` 与该类的已验证应用基线内容一致时，系统 SHALL 将该类计划为 `skip`，不复制、不运行该类安装，也不把 `lastApplied` 改指向一个未创建的工作副本。

#### Scenario: winget 更新但 npm 内容未变

- **WHEN** 新索引仅包含 winget 内容变化，npm 当前清单与 npm 基线一致
- **THEN** npm 计划为 skip 且不复制 npm storage
- **AND** npm 的 `lastApplied` 继续指向实际已验证基线

#### Scenario: 多轮其他类别更新后保留复用基线

- **WHEN** 某类连续多轮内容未变化而其他类别产生了新工作副本
- **THEN** 工作副本清理保留该类 `lastApplied` 引用的已验证基线
- **AND** 该类后续发生内容变化时仍可尝试 delta，而不是因基线被例行清理被迫全量

### Requirement: winget 按文件执行 delta 复制

对具有有效基线的 winget 类别，系统 SHALL 仅从现在 repo 复制新增或内容变化文件，复用未变化文件，并排除当前清单已删除文件；比较 SHALL 使用相对路径、字节数和 SHA256。

#### Scenario: 单个安装器更新

- **WHEN** 当前 winget 清单中仅一个安装器及其 YAML 相对基线发生变化
- **THEN** 系统仅从 repo 复制该安装器、该 YAML 和必要的当前控制文件
- **AND** 其他未变化安装器从基线复用而不从 repo 复制

#### Scenario: 仅 YAML 内容变化

- **WHEN** 某包 YAML 变化但安装器 SHA256 与基线相同
- **THEN** 系统复制当前 YAML
- **AND** 复用基线中的安装器

#### Scenario: 包或依赖文件被移除

- **WHEN** 基线中的包或依赖文件不再出现于当前 winget 清单
- **THEN** 该文件不进入新工作副本
- **AND** 新工作副本不错误保留旧内容

### Requirement: delta 工作副本保持逻辑完整

系统 SHALL 使 winget delta 工作副本包含当前清单引用的全部文件；未变化文件 SHALL 优先通过 NTFS 硬链接从已验证基线复用，使现有 winget 安装、本地 HTTP 服务和 runtime 包布局无需消费 delta-only 目录。

#### Scenario: 硬链接复用未变化安装器

- **WHEN** 基线与新 work 位于支持硬链接的同一 NTFS 卷且基线文件可用
- **THEN** 新 work 中的未变化文件引用基线内容而不复制其实际字节

#### Scenario: 硬链接不可用时安全回退

- **WHEN** 某个未变化文件无法创建硬链接
- **THEN** 系统从已验证基线复制该文件
- **AND** 基线副本不可用时从现在 repo 取得该文件
- **AND** 不将复用失败直接视为整轮 apply 失败

### Requirement: 基线不可信时回退全量

首次应用、无对应 `lastApplied` 基线、基线缺少有效验证标记或基线清单不可用时，系统 SHALL 对受影响类别执行全量复制，并 MUST NOT 生成不完整 delta 工作副本。

#### Scenario: 首次 winget 应用

- **WHEN** B 没有已验证的 winget 应用基线
- **THEN** 系统全量复制当前 winget 类别
- **AND** 将计划标记为 full 及对应原因

#### Scenario: 类别失败后旧基线已被清理

- **WHEN** 某类 `lastApplied` 指向的工作副本已不存在
- **THEN** 该类回退全量复制
- **AND** 其他具有效基线的类别仍可使用各自 delta 计划

### Requirement: delta 复制不削弱完整性校验

系统 SHALL 按当前索引和 `files.json` 校验工作副本；从当前 repo 复制的文件 MUST 在复制后重新核验字节数和 SHA256，校验失败 MUST 使新代失败且不推进该类 `lastApplied`。

#### Scenario: delta 文件复制后损坏

- **WHEN** 任一从 repo 复制的变化文件未通过当前清单复核
- **THEN** 系统删除或隔离该未通过验证的新工作副本
- **AND** 不使用该副本安装
- **AND** 不更新受影响类别的 `lastApplied`

#### Scenario: delta 工作副本通过校验

- **WHEN** 当前清单引用的全部工作副本内容满足既有验证契约
- **THEN** 系统才写入该代的已验证标记并允许后续 apply 消费

### Requirement: 非 winget 类别保持兼容的复制语义

本能力 SHALL 仅要求 winget 支持文件级 delta；其他 pending 类别和需要交付的 runtime SHALL 使用其受支持的完整复制或后续明确实现的 delta 语义，MUST NOT 将不完整目录交给现有安装流程。

#### Scenario: npm 与 winget 同时 pending

- **WHEN** 同一轮 winget 和 npm 均需要应用
- **THEN** winget 可使用文件级 delta
- **AND** npm 仍以完整存储快照进入其工作副本

#### Scenario: runtime 因漂移需要交付

- **WHEN** 当前 runtime 内容相对 B 状态发生漂移
- **THEN** 系统将 bootstrap 所需 runtime 和相关 winget 内容纳入工作副本计划
- **AND** 不因普通 winget delta 筛选而遗漏 runtime winget 包

### Requirement: 工作副本优化量可观测

系统 SHALL 在 apply 报告和日志中按类别记录复制模式、实际复制与复用的文件数和字节数、删除文件数以及全量回退原因。

#### Scenario: 运维确认 winget 仅复制变化内容

- **WHEN** 一次 winget delta 工作副本创建完成
- **THEN** 报告包含实际复制和复用的文件数与字节数
- **AND** 实际复制字节数等于变化文件及必要控制文件的字节总量
