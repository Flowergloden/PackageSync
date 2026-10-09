# winget-install-scope Specification

## Purpose

PakageSync 在 B 端安装 winget 包时需要按包类型选择正确的安装 scope，并在 machine scope 因权限
被拒时对 portable 包自动降级到 user scope，使离线部署不会因机器级写入受限而整体失败。

## Requirements

### Requirement: Portable 包 machine scope 失败时降级 user scope

当 `winget.scope` 配置为 `machine`，且某个 portable 包（`InstallerType: zip` 搭配
`NestedInstallerType: portable`）的 machine scope 安装尝试因权限或 portable 类错误失败时，B 端
SHALL 对该包以 user scope 重试一次，且 MUST NOT 改变全局 `winget.scope` 配置值。

#### Scenario: Portable machine scope 权限失败后 user scope 成功

- **WHEN** portable 包以 machine scope 安装返回 `0x80070005`（E_ACCESSDENIED）
- **THEN** 系统以 user scope 重试该包
- **AND** user scope 成功时该包记入 apply 报告的 ok 集合，并标记发生了 scope 降级
- **AND** 不修改 `winget.scope` 配置

#### Scenario: 非 portable 包不受降级影响

- **WHEN** 非 portable 包（例如 msi/exe/wix/inno/burn/nullsoft/msix）以 machine scope 安装返回 `0x80070005`
- **THEN** 系统不对该包以 user scope 重试
- **AND** 该包仍记入 failed 集合

#### Scenario: Portable machine scope 首次即成功时不降级

- **WHEN** portable 包以 machine scope 安装返回成功退出码
- **THEN** 系统不再发起 user scope 尝试
- **AND** 该包记入 ok 集合且不标记 scope 降级

### Requirement: 仅对权限与 portable 类错误触发降级

系统 SHALL 仅将 `0x80070005`（E_ACCESSDENIED）、`0x8A150052`
（PORTABLE_INSTALL_FAILED）、`0x8A150054`（PORTABLE_PACKAGE_ALREADY_EXISTS）、
`0x8A150057`（PORTABLE_UNINSTALL_FAILED）视为可降级信号；
确定性错误（例如版本不存在、无适用安装器）MUST NOT 触发 scope 降级重试。

#### Scenario: 确定性错误不触发降级

- **WHEN** portable 包安装返回版本不存在或无适用安装器失败
- **THEN** 系统不对该包以 user scope 重试
- **AND** 该包记入 failed 集合

#### Scenario: 升级后的 portable 卸载失败错误也触发降级

- **WHEN** portable 包安装返回 `0x8A150057`（PORTABLE_UNINSTALL_FAILED）
- **THEN** 系统将其视为可降级信号并进入 user scope 重试路径

#### Scenario: 残留空键导致的 portable 冲突也触发降级

- **WHEN** portable 包安装返回 `0x8A150054`（PORTABLE_PACKAGE_ALREADY_EXISTS，机器级残留空 ARP 键所致）
- **THEN** 系统将其视为可降级信号并进入 user scope 重试路径

### Requirement: 降级前执行 best-effort 残破状态清理

在发起 user scope 重试前，系统 SHALL 对该包执行一次 best-effort 的残破安装状态清理，且清理失败
MUST NOT 阻断后续 user scope 重试。

#### Scenario: 清理失败仍继续重试

- **WHEN** portable 包 machine scope 失败且清理操作本身也失败
- **THEN** 系统仍以 user scope 重试一次
- **AND** 清理失败仅记入日志，不作为降级中止理由

#### Scenario: 清理不针对健康已装包

- **WHEN** 某包在 machine scope 首次尝试即成功
- **THEN** 系统不执行任何预防性清理

### Requirement: 降级事实在报告与日志中可观测

系统 SHALL 在 apply 报告与日志中记录 scope 降级事实，包括各次尝试的 scope 与退出码，
使运维可判断某包最终以哪个 scope 安装。

#### Scenario: 报告记录降级尝试

- **WHEN** 某 portable 包经 machine 失败后以 user scope 成功
- **THEN** 该包的 ok 条目包含 scope 降级标记
- **AND** 日志记录首次 machine 尝试的退出码与最终成功 scope

#### Scenario: 两次均失败时报告保留两次退出码

- **WHEN** 某 portable 包 machine 与 user 两次尝试均失败
- **THEN** 该包的 failed 条目包含两次尝试的 scope 与退出码
- **AND** 处理继续到下一个包，不中断整轮 apply
