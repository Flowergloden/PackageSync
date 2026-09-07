# PakageSync — A→B 单向离线同步 运维手册

> 配套工作计划：`.omo/plans/ab-one-way-sync.md`。本文档面向部署/运维人员，覆盖架构、威胁模型、首次部署、清单编辑、日常运维动作与全部已知限制。
> 角色：**A** = 外网机（可联网，负责导出）；**B** = 内网机（不可联网，负责校验与安装）。A↔B 之间无任何直连，文件只能经**既有 SMB 单向服务**从 A 流向 B。

---

## 一、架构总览

```
[外网机 A]                                        [内网机 B]
  Export-OfflineRepo.ps1                             (SMB 单向镜像后)
  读取四份人读清单 ──┐                                  |
  + winget 白名单    │                                 v
  + requirements.txt │                          Test-OSyncRepoIntegrity 校验
  + npm 清单         │                          (index.json → files.json → 逐文件 SHA256)
  + dotfiles 源态    │                                 |  失败 → 该类别整体跳过
                     v                                 v
  构建 staging 仓库 ─┼─► 落盘区 D:\OfflineRepo     robocopy → 本地工作副本
  (winget YAML 改    │   (含 index.json 信任根、     <stateDir>\work\<exportedAtUtc>\
   写为 localhost    │    runtime\tool\ 工具本体)        |  逐文件复核 hash → .verified
   URL + files.json) │                                 v
                     v                                 |  一律从工作副本执行
   既有 SMB 单向服务 ───────────────► B 落盘区 C:\OfflineRepo
                                              Invoke-OfflineApply.ps1
                                              winget --manifest（本地 HTTP 8788）
                                              pip --no-index --find-links
                                              npm 本地 Verdaccio（4873）
                                              chezmoi apply（用户上下文）
```

文字链路：**A export → 落盘区（D:\OfflineRepo）→ 既有 SMB 单向服务 → B 落盘区（C:\OfflineRepo）→ 校验 → 工作副本 → apply**。

核心不变量：

- 仓库由 `index.json`（信任根）+ 每类别 `files.json`（SHA256 完整性清单）+ 实际载荷构成；校验顺序严格为 index → 各类 files.json 哈希 → 逐文件哈希。
- B 端 apply 一律「先校验 → 复制到本地工作副本 → 再校验 → 才安装」，**绝不直接从同步目录安装**（防 SMB 镜像中途改写/删除）。
- 工具本体随仓库自举进 `runtime\tool\`，B 端 bootstrap 落位固定本地路径 `C:\PakageSync\`，计划任务与手动命令一律从该本地副本执行。
- B 端不做任何 A↔B 回传：状态与日志只留在 B。
- 单类失败不阻断其他类别，也不误标已应用（`state.json` 按类别单调记录 `lastApplied`）。

## 二、威胁模型

仓库内容不加密、依赖「可信内网」前提：同步链路（SMB 共享）与 B 端落盘目录都视为可信边界内；本方案不内置任何密钥/凭据，B 端任何监听仅绑定 `127.0.0.1`。

## 三、首次部署

### 3.1 A 端（外网机）

1. 安装 Node.js/npm（npm 类别导出与预热需要；B 端 runtime 的 Node 由 winget 管线安装，A 侧自身需可用 npm）。
2. 按「四、清单编辑指南」编辑四份清单：`manifests\winget-packages.txt`、`manifests\requirements.txt`、`manifests\npm-packages.txt`、`manifests\dotfiles\`（chezmoi 源态）。
3. （可选）核对 `config\packagesync.json`：`repoRoot`、`stagingRoot`、端口（8788/4873/4874）、`categories`、运行时钉版 `pins.*`。
4. 注册 A 端计划任务（每日 02:00 自动导出）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Register-SyncTasks.ps1 -Role A
```

   - 注册任务 `PakageSync-Export`：当前用户、LogonType S4U（注销也运行）、RunLevel Highest、StartWhenAvailable。
   - 也可手动触发验证：`powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Export-OfflineRepo.ps1 [-ConfigPath <path>] [-Category winget,pip,npm,dotfiles]`。

### 3.2 B 端（内网机）

1. **等待首次同步**：SMB 把 A 的落盘区镜像到 B 的落盘区（默认 `C:\OfflineRepo`）。
2. **首次引导必须先手工复制工具本体**（工具还没到本地，见 5.7 / 已知限制 L12）：

```powershell
# 管理员 PowerShell
New-Item -ItemType Directory -Path C:\PakageSync -Force | Out-Null
Copy-Item -Path C:\OfflineRepo\runtime\tool\* -Destination C:\PakageSync\ -Recurse -Force
```

3. 从**本地副本**运行一次性引导（管理员身份，全程幂等）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Install-OfflineBootstrap.ps1
```

   - 引导内容：机器级 VC_redist → App Installer 链（VCLibs/UI.Xaml/msixbundle）→ 本地 HTTP 服务 → winget 方式A 安装 Python/Node → 注册 Verdaccio 常驻任务 → 落位 `C:\PakageSync\`。
   - 完成判断：输出 `SUCCESS (bootstrapped=True ...)` 且 `C:\ProgramData\PakageSync\state\system-state.json` 中 `bootstrapped=true`。
4. 注册 B 端计划任务：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Register-SyncTasks.ps1 -Role B
```

   - `PakageSync-Apply-Packages`：SYSTEM 主体、每 4h + 开机、最高权限，`-Category winget,pip,npm`（自愈 bootstrap 也由它触发）。
   - `PakageSync-Apply-Dotfiles`：当前用户、登录 + 每 4h，`-Category dotfiles`；若 B 日常用户不是管理员，用 `-DotfilesUser <name>` 显式指定（本方案为**单用户前提**）。
5. （可选）手动触发一次全量 apply 验证：`powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Invoke-OfflineApply.ps1`。

### 3.3 降级路径：SYSTEM 主体 winget 不可用

若 SYSTEM 上下文下 winget 不可用（SYSTEM 任务安装失败），改用 User 主体降级注册：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Register-SyncTasks.ps1 -Role B -PackagesTaskPrincipal User
```

   - 降级语义钉死：主体 = 执行注册的管理员账户、LogonType S4U、RunLevel Highest。

## 四、清单编辑指南

### 4.1 winget 白名单（manifests\winget-packages.txt）

每行一个包：`Id` 或 `Id@version`（`#` 注释与空行忽略，自动去重）。

```
# 示例
7zip.7zip@26.02
Microsoft.PowerToys
```

- 强烈建议钉版 `Id@version`，保证 A/B 版本一致；查版本用 `winget show --id <Id> -e`（本机 winget 输出为中文，勿 grep 英文 `Version:` 标签，直接正则版本号）。
- 只有**本轮导出成功**的 Id 才会写进交付清单 `winget\packages.txt`；失败的包仅记入导出报告 `failed` 数组，不中断其他包，也不进 B 端安装清单。
- 换版本 = 改这一行，下次导出自动生效。

### 4.2 pip requirements.txt（manifests\requirements.txt）

每行一个**钉版**依赖 `pkg==x.y.z`（离线可重现的硬性要求，解析器对未钉版行只告警）：

```
six==1.17.0
```

- 禁止 `-e/--editable`、`-r/--requirement`、`-c/--constraint` 行——离线不可重现/引用文件不入仓，解析器直接报错（含行号）。
- 平台/解释器由 config `pip.downloadArgs` 钉死（`--only-binary=:all: --platform win_amd64 --python-version 3.12 --implementation cp --abi cp312`），清单里无需写平台参数；B 端安装 `pip install --no-index --find-links=...`，**绝不加网络源参数**。

### 4.3 npm 清单（manifests\npm-packages.txt）

支持 `name`、`name@version`、`@scope/name[@version]`（包名必须小写）：

```
is-odd@3.0.1
```

- A 端用一次性 Verdaccio（4874）预热整棵依赖树并快照 storage；B 端由常驻本地 Verdaccio（4873）从**校验过的本地副本**供给（`verdaccio-b.yml` 无 `uplinks`/`proxy`，绝无外网依赖）。
- **B 端不自动全局安装 npm 包**（SYSTEM 上下文装全局包会落错用户 profile）——registry 供给即交付语义；B 上按需 `npm install`（默认已指向本地 registry，见 5.2 内置 npmrc）。

### 4.4 chezmoi dotfiles 源态（manifests\dotfiles\）

- 目录即 chezmoi 源态：普通文件 = 目标文件；`.plain_` 前缀 = 不渲染；`run_*` 前缀 = 脚本（`run_once_`/`run_onchange_` 幂等由 chezmoi 持久状态库保证）。
- **externals 禁用**：源态内不得出现任何 `.chezmoiexternal*` 文件，导出直接报错「离线不支持 externals」（空气隔离机 externals 不可用）。
- 模板变量：`chezmoi.toml` 的 `[data]` 节映射到模板数据根，用 `{{ .name }}`（不是 `{{ .data.name }}`）。
- 维护流程：A 上编辑 `manifests\dotfiles\` 源态 → 下次导出自动打包（`robocopy /MIR`）→ SMB 同步 → B 上 `chezmoi apply`。**B 上被本地改过的目标文件会被保守跳过并记录，绝不覆盖**（见 5.3）。

## 五、运维手册

### 5.1 日志位置

- **B 端日志：`C:\ProgramData\PakageSync\run\logs`**（人类可读 + JSONL 事件双写，目录自动创建）。
- A 端日志：`<repoRoot>\logs`（默认 `D:\OfflineRepo\logs`）。
- B 端状态（双存储）：
  - `C:\ProgramData\PakageSync\state\system-state.json`：仅 SYSTEM/管理员可写；`bootstrapped`、winget/python/node 路径记录、winget/pip/npm 的 `lastApplied`。
  - `C:\ProgramData\PakageSync\run\user-state.json`：双主体可写；dotfiles 的 `lastApplied`/基线/锁。
  - 任一存储损坏 → 自动备份为 `.bak` 并重建空态 + Warning。

### 5.2 手动运行：-WhatIf 与 -Category

```powershell
# 预演：零变更——只读 index+state，输出每类"将安装/更新"差异报告；不起服务、不复制、不改任何文件
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Invoke-OfflineApply.ps1 -WhatIf

# 只跑某类（-Category 取值：winget,pip,npm,dotfiles，逗号分隔）
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Invoke-OfflineApply.ps1 -Category winget
powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Invoke-OfflineApply.ps1 -Category dotfiles -WhatIf
```

- 引导预演：`powershell -NoProfile -ExecutionPolicy Bypass -File C:\PakageSync\src\Install-OfflineBootstrap.ps1 -WhatIf`（零变更：只读仓库与 state，不写任何东西——注：会创建日志目录这个运维产物）。
- 全程互斥：入口脚本先取 `<stateDir>\run\apply.lock`（拿不到最多等 60s 后本轮跳过；锁龄 >2h 或时间戳为未来视为残留毒锁自动打破）。

### 5.3 dotfiles 冲突处理（skipped）

- B 上目标文件被本地修改（与上次应用 hash **及**新源 hash 都不同）→ **保守跳过并记入 `skipped`**，绝不传 `--force`、绝不静默覆盖。
- 首轮无基线时预存的异内容文件同样跳过并报告。
- skipped/failed 的文件**不会**记入 state 基线——下一轮仍按「本地改动」对待，防止误覆盖。
- 安全集合为空 → 不调用 chezmoi apply（零覆盖）。
- 查看发生了什么：B 端日志（5.1）+ 该轮 `state.dotfiles.skipped` 记录。

### 5.4 下载失败（UA-403）与 Microsoft Store 应用限制

- **UA-403**：部分 ISV 按 User-Agent 封锁 winget 下载（HTTP 403）——该包记入导出报告 `failed`，不中断其他包；遇此类包需人工评估替代方案。
- **Microsoft Store UWP 应用**：仅发布者勾选「离线分发」的才能 `winget download`；其余 Store 应用不支持离线分发，**不在本方案范围**（B 端不同步 Store 应用）。

### 5.5 端口占用处理（8788 / 4873 / 4874）

| 端口 | 用途 | 占用方 |
|---|---|---|
| 8788 | B 端本地 HTTP 静态服务（winget `--manifest` 安装源） | apply/bootstrap 期间按次启停 |
| 4873 | B 端常驻 Verdaccio（npm 离线 registry） | 计划任务 `PakageSync-Verdaccio` 常驻 |
| 4874 | A 端一次性 Verdaccio 预热（仅导出期占用） | 导出期间短暂占用 |

- **三个端口均为双端一致常量**：改端口须在 A 侧改 `config\packagesync.json` 并**重新导出**（InstallerUrl 的端口在 A 端导出时烙死，B 端 config 永不覆盖），B 侧 config 同步一致。
- 端口被占 → 相关步骤明确报错（错误消息含端口号）；释放占用后重跑即可。
- A 端预热端口（4874）与 B 端供给端口（4873）物理隔离，互不冲突；涉 4873 的 QA 一律用独立 config 副本改非 4873 值，防撞车。

### 5.6 运行时钉版重钉流程（PIN-ME）

chezmoi 与 App Installer 四件套（msixbundle/VCLibs/UI.Xaml/VC_redist）都靠 config `pins.*.sha256` 哈希校验：

1. 把对应 `XxxSha256`（App Installer 四件）或 `sha256`（chezmoi）置为 `"PIN-ME"`。
2. 重跑 A 端导出 → 下载真实文件、打印实际 sha256 并**非零退出**（提示钉入）。
3. 把打印的 64 位 hex 写回 config 对应键。
4. 重跑导出 → 哈希校验通过后正常继续（文件已下载，不重复下载）。

- 升级**运行时钉版**（Python/Node/Verdaccio/chezmoi 版本）后，B 端须**手动重跑一次 bootstrap**（幂等；packages 任务也有内容漂移自愈兜底，见已知限制 L10）。

### 5.7 工具本体到 B 的部署渠道（runtime\tool → C:\PakageSync\）

- A 端导出时把 `src\` + `config\packagesync.b.json` + 本 README 快照进 `runtime\tool\`（随仓库自举）。
- B 端 bootstrap 把该副本复制到**固定本地路径 `C:\PakageSync\`**；`C:\PakageSync\config` 归 B 本地所有，自刷新**永不覆盖**（A 侧 schema 变更需人工合并）。
- 计划任务与手动命令一律从 `C:\PakageSync\src\` 执行（任务指向 `bin\` 中永不换名的微启动器）。
- 每次 apply 在完整性通过后自刷新该副本（先 `.new` 再换名 `.old`，顺序钉死；刷新前重验 `C:\PakageSync` 属主/ACL）——**下一周期生效**。
- **首次引导必须手工复制**（见 3.2 步 2，已知限制 L12）。

## 六、已知限制

## 六、已知限制

1. **L1. winget 包依赖离线解析仅经合成 fixture 验证**：`Dependencies` 子目录依赖的端到端离线解析只用合成清单 fixture 覆盖，未经真实复杂依赖包实测（真实 7zip 无依赖，未出现 `Dependencies\` 目录）。
2. **L2. SYSTEM 上下文需机器级 VC_redist**：Appx 版 VCLibs 不覆盖 SYSTEM；SYSTEM 计划任务运行 winget 的前提是机器级 VC++ 运行库（bootstrap 步骤⓪在 App Installer 链之前静默安装）。
3. **L3. LocalManifestFiles 为 per-user 设置**：bootstrap 按**双上下文分别启用**（管理员 + 一次性 SYSTEM 任务）。winget v1.29.290 上它位于 `C:\ProgramData\Microsoft\WinGet\<SID>\settings\pkg\Microsoft.DesktopAppInstaller\admin_settings`（哈希保护文件，用 `winget settings export` 查看/备份）；SYSTEM 上下文路径不同：`C:\ProgramData\Microsoft\WinGet\S-1-5-18\settings\win\defaultState\admin_settings`——两处均以首次真实安装验证生效。
4. **L4. winget 版 Python 的 PATH 注册由 bootstrap 步骤③显式验证**：装后重读 machine PATH 验证 python.exe 可解析并记录，失败即明确报错（提示 bootstrap 未完成），绝不静默。
5. **L5. 离线 B 上 winget source 更新超时只记日志**：`winget install` 的 source 自动更新失败仅记日志，不阻断安装。
6. **L6. VC_redist 可接受退出码 {0, 3010, 1638}**：3010（需重启）与 1638（更高版本已装）均视为成功。
7. **L7. 端口 8788/4873/4874 为双端一致常量**：改端口须 A 侧改 config 并**重新导出**（见 5.5），B 端 config 永不覆盖 URL 中烙死的端口。
8. **L8. B 端 `C:\PakageSync\config` 归本地所有**：自刷新永不覆盖它；A 侧 config schema 变更需人工合并。
9. **L9. chezmoi 首轮语义**：首轮无基线时，预存且内容与源不同的文件一律视为本地改动，**保守跳过并报告**，绝不覆盖。
10. **L10. 升级运行时钉版后 B 须手动重跑 bootstrap**：Python/Node/Verdaccio/chezmoi 版本升级后手动重跑（幂等）；此外 packages 任务有内容漂移自愈兜底——`runtimeWingetHash`/`runtimeFilesHash` 相对 system-state 记录漂移时自动重跑 bootstrap ③④（SYSTEM 自愈路径见 L13）。
11. **L11. App Installer 三件套真实安装链在 A 机不可执行**：A 上只能静态校验（解包读 AppxManifest 依赖版本与 VCLibs/UI.Xaml 比对）；**B 端首次安装即首次真实测试**。
12. **L12. B 端首次引导必须先手工复制 runtime\tool**：`Copy-Item C:\OfflineRepo\runtime\tool\* C:\PakageSync\` 后再从本地副本运行 bootstrap（见 3.2 / 5.7）。
13. **L13. SYSTEM 自愈 bootstrap 路径未经完整 QA**：该自动路径仅作自愈兜底，QA 不覆盖完整链；失败不阻断完成判定（手动 bootstrap 仍是受支持路径）。
14. **L14.（todo-10 QA）App Installer 依赖版本缺口**：aka.ms 钉定的 VCLibs（14.0.33321.0）**旧于** App Installer 1.29.290 的 bundle 需求（14.0.33728.0），且 UI.Xaml 2.8 已不是当前 bundle 依赖（改为 WindowsAppRuntime 1.8）；Windows 10/11 一般自带 VCLibs，但**全新 B 上钉定 VCLibs 可能不满足 bundle**——若 B 安装失败请换新 URL 重钉（PIN-ME 流程见 5.6）。
15. **L15.（todo-13 QA）`winget install --manifest <dir>` 拒绝非 YAML 文件/子目录**：winget 会把目录里每个文件当清单解析，二进制安装器会触发 `0x8a150004`；工具在 apply/bootstrap 前把每个包 staging 成**纯清单扁平目录**（只含 `*.yaml`）再传 `--manifest`，安装器保留在工作副本供本地 HTTP 服务读取（本限制仅在相关报错排查时涉及）。


16. **L16. Node MSI 同名修复限制（todo-20 QA）**：导出会把安装器改名为 YAML 主干名（如 Node.js_26.7.0_Machine_X64_wix_zh-CN.msi）；实测该改名后的 Node MSI 在"同版本已装"的修复路径上以 1603 失败（Wix4RollbackInternetShortcuts 动作返回 3），原名（node-v26.7.0-x64.msi）则成功——B 端首次引导（全新安装）预期不受影响（失败动作仅在修复/卸载序列运行），但 B 端对已装 Node 的重复引导会命中同一 1603，属部署期验证项。
17. **L17. SYSTEM 自愈 bootstrap 幂等冒烟在 A 机 QA 中失败（todo-20）**：临时 SYSTEM 任务重跑 bootstrap 在步骤 1 失败（Add-AppxPackage 在 SYSTEM 上下文被拒，0x80073CF9——本地系统账户不允许执行部署 Add 操作）；该自动路径仍仅作自愈兜底，手动 bootstrap 是受支持路径（详见 task-20 evidence）。
18. **L18. SYSTEM 上下文 winget 安装失败（todo-20 QA 结论）**：A 机上 SYSTEM 主体执行 winget install --manifest 在"Starting package install..."处挂起（未生成 msiexec、无安装日志；直接 msiexec 在 SYSTEM 下可正常安装，挂起点在 winget 的安装器执行环节）——SYSTEM 主体 apply 路径在本机不可用，降级路径 Register-SyncTasks -Role B -PackagesTaskPrincipal User（管理员账户 S4U/Highest）实测可用；真实 B 机若 SYSTEM 安装同样挂起，请使用 User 降级注册（README 3.3）。
19. **L19. 离线模拟限制（todo-20 QA）**：A 机上 winget.exe 为打包应用（App Installer），其流量豁免 Windows 防火墙规则（程序/端口/全协议规则均实测无效），且 winget source update 对抓取失败吞错返回 0——离线 source 更新失败场景无法在 A 机复现；manifest 安装路径已实测不依赖 source 连通性（安装日志无 source 活动，仅需 loopback HTTP），真实离线 B 的 source 更新行为仍属部署期验证项。