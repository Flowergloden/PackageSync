# Incremental Repository Export Specification

## Purpose

让 A 端在本地完成逐代导出与复用，并按交付内容而非时间戳向共享仓库发布变化，减少未变化载荷占用的交换带宽，同时维持现有完整性信任链。

## Requirements

### Requirement: 导出暂存与 A 专用缓存不写入共享路径

系统 SHALL 将逐代 staging、`.verdaccio-a` 和可复用载荷缓存保存在 A 本地；共享路径 SHALL 仅承载正式发布仓库及明确的发布文件。

#### Scenario: 默认导出使用本地暂存

- **WHEN** A 端以默认配置执行一次完整导出
- **THEN** 新 staging 代和 `.verdaccio-a` 均位于 A 本地路径
- **AND** 不向共享 staging 路径写入这些内容

#### Scenario: 本地复用源可用时不从共享仓库读回

- **WHEN** winget 或 runtime 载荷可从受支持的 A 本地先前导出复用
- **THEN** 系统从本地复用源构造本轮 staging
- **AND** 不为了取得这些未变化载荷而读取共享仓库副本

### Requirement: 按交付内容增量发布

系统 SHALL 使用各类别当前与已发布 `files.json` 中的相对路径、字节数和 SHA256 判定新增、变化、未变化和删除文件；未变化文件 MUST NOT 因时间戳或新 staging 代不同而重写。

#### Scenario: 内容相同但时间戳不同

- **WHEN** 本轮文件与已发布文件的相对路径、字节数和 SHA256 相同但修改时间不同
- **THEN** 发布过程不重写该共享仓库文件

#### Scenario: 仅发布新增和变化文件

- **WHEN** 本轮仅一个 winget 安装器及其 YAML 发生变化
- **THEN** 系统仅写入这些变化文件和必要的当前清单
- **AND** 其他未变化安装器不被重写

#### Scenario: 当前代删除旧文件

- **WHEN** 已发布文件在当前交付清单中不再存在
- **THEN** 发布过程从对应正式仓库类别移除该文件
- **AND** 不移除当前清单仍引用的文件

### Requirement: 无交付内容变化时不产生新代

当全部交付文件内容与已发布仓库一致时，系统 SHALL 将本轮报告为成功的无变化结果，并 MUST NOT 更新正式仓库 `index.json` 或其 `exportedAtUtc`。

#### Scenario: 每日重复导出相同内容

- **WHEN** 本轮所有交付文件与已发布版本逐项相同
- **THEN** 正式仓库继续引用原 `index.json` 和原 `exportedAtUtc`
- **AND** B 端不会因本轮导出看到新代

#### Scenario: 运维元数据变化不构成交付变化

- **WHEN** 仅导出耗时、临时路径或报告生成时间发生变化
- **THEN** 系统仍按无交付内容变化处理
- **AND** 不发布新代

### Requirement: 增量发布保持完整性与失败安全

系统 SHALL 在发布前完成本轮完整完整性校验，并最后更新 `index.json`；任何类别失败或发布写入失败 MUST NOT 让新索引引用未完成内容。

#### Scenario: 变化文件发布失败

- **WHEN** 任一必要文件无法完整写入正式仓库
- **THEN** 本轮发布报告失败
- **AND** 不写入指向该未完成新一代的 `index.json`

#### Scenario: 本轮完整性校验失败

- **WHEN** staging 的任一启用类别未通过完整性校验
- **THEN** 系统不执行增量发布
- **AND** 已发布索引保持不变

### Requirement: 发布量与回退原因可观测

系统 SHALL 在导出报告和日志中记录本轮复制、复用及删除的文件数和字节数，以及无法使用增量路径时的全量回退原因。

#### Scenario: 运维核对本轮实际发布量

- **WHEN** 一次增量发布完成
- **THEN** 报告包含实际复制、复用和删除的文件数与字节数
- **AND** 可复制字节数与发布计划中的变化文件一致
