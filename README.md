# PakageSync — A→B 单向离线同步 运维手册

> 配套工作计划：`.omo/plans/ab-one-way-sync.md`。本文档面向部署/运维人员，覆盖架构、威胁模型、首次部署、清单编辑、日常运维动作与全部已知限制。
> 角色：**A** = 外网机（可联网，负责导出）；**B** = 内网机（不可联网，负责校验与安装）。A↔B 之间无任何直连，文件只能经**既有 SMB 单向服务**从 A 流向 B。

---

## 一、架构总览

```
[外网机 A]                                        [内网机 B]
  Export-OfflineRepo.ps1                             (SMB 单向镜像后)
  读取五份人读清单 ──┐                                  |
  + winget 白名单    │                                 v
  + requirements.txt │                          Test-OSyncRepoIntegrity 校验
  + npm 清单         │                          (index.json → files.json → 逐文件 SHA256)
  + bun 清单（可空）  │                                 |  失败 → 该类别整体跳过
  + dotfiles 源态    │                                 v
                     v                          robocopy → 本地工作副本
  构建 staging 仓库 ─┼─► 落盘区 D:\OfflineRepo     <stateDir>\work\<exportedAtUtc>\
  (winget YAML 改    │   (含 index.json 信任根、         |  逐文件复核 hash → .verified
   写为 localhost    │    runtime\tool\ 工具本体)        v
   URL + files.json) │                                 |  一律从工作副本执行
                     v
   既有 SMB 单向服务 ───────────────► B 落盘区 C:\OfflineRepo
                                              Invoke-OfflineApply.ps1
                                              winget --manifest（本地 HTTP 8788）
                                              pip --no-index --find-links
                                              npm 本地 Verdaccio（4873）
                                              bun add -g（按需，同一 registry 4873）
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
2. 按「四、清单编辑指南」编辑五份清单：`manifests\winget-packages.txt`、`manifests\requirements.txt`、`manifests\npm-packages.txt`、`manifests\bun-packages.txt`（可空，见 4.5）、`manifests\dotfiles\`（chezmoi 源态）。
3. （可选）核对 `config\packagesync.json`：`repoRoot`、`stagingRoot`、端口（8788/4873/4874）、`categories`、运行时钉版 `pins.*`（含 `pins.bun`——bun 运行时本体的钉版下载，`sha256` 走 5.6 的 PIN-ME 流程；**整节删除 `pins.bun` 即整体关闭 bun**，旧 config 无 bun 键不受影响）。
4. 注册 A 端计划任务（每日 02:00 自动导出）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Register-SyncTasks.ps1 -Role A
```

   - 注册任务 `PakageSync-Export`：当前用户、LogonType S4U（注销也运行）、RunLevel Highest、StartWhenAvailable。
   - 也可手动触发验证：`powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Export-OfflineRepo.ps1 [-ConfigPath <path>] [-Category winget,pip,npm,dotfiles]`。
   - 手动运行时控制台**默认实时回显**进度（里程碑日志行 + winget/pip/npm 子进程输出，winget 侧 250ms 节流 + CR 折叠），无需另开窗口尾随日志；需要静默（只看日志文件）时加 `-Quiet`。无人值守计划任务不受此开关影响。
   - `-SkipRuntime`：跳过 runtime 重导出（VC_redist/bun 下载、Python/Node winget 下载、Verdaccio 构建、tool 快照），改为**复用落盘区上一代已发布载荷**（`runtime\` + `winget\` 下的 Python/Node 目录复制进新 staging 代并重新入清单）——信任链（index → files.json → 逐文件 SHA256）完全不变，仅省去下载/构建耗时；`runtime\tool` 快照随之保持上一代内容。要求已做过至少一次完整导出，否则 fail-fast 报错（不做任何 staging 工作）。

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

   - 引导内容：机器级 VC_redist → 校验 winget.exe 存在（App Installer 不再由引导安装，现代 Windows 自带）→ 本地 HTTP 服务 → winget 安装 Python/Node → 注册 Verdaccio 常驻任务 → （仓库含 bun 载荷时）bun 运行时落位 `<stateDir>\bun` + 机器 PATH + 机器级 `BUN_CONFIG_REGISTRY` → 落位 `C:\PakageSync\`。
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

### 4.0 从本机已安装包交互生成清单（Export-Manifests.ps1）

A 端手动运维工具：从本机包管理器采集已安装包（`winget export` / `pip freeze` / `npm ls -g` / `bun pm ls -g`），在控制台以编号多选方式勾选需要的条目，按**已安装版本钉版**写回对应清单（首建或增补均可）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File <repo>\src\Export-Manifests.ps1 [-Category winget,pip,npm,bun,dotfiles]
```

- 流程：采集已安装包 → 编号多选（`1,3,5-8` / `all` / `none`，回车保持预选）→ 按已装版本钉版回写（winget `Id@version`、pip `name==version`、npm/bun `name@version`）。
- bun 是**可选类别**（不在默认 `-Category winget,pip,npm` 中，需显式 `-Category bun`），且 presence-gated：config 无 `paths.bunList` 键时该类直接跳过（Info 日志，不报错）——bun 清单格式与 npm 清单完全相同（见 4.5）。
- `dotfiles` 默认包含在类别筛选中；也可显式传入 `-Category dotfiles`。进入该类别后，Export-Manifests 先调用 `chezmoi unmanaged` 列出顶层未纳入源态的文件、目录和符号链接；第一轮编号筛选选择文件或需要展开的目录，选中的目录随后递归展开，在第二轮筛选中逐项选择其中的文件/符号链接，最后调用 `chezmoi add` 写入 `manifests\dotfiles\`。目录不会再作为整体添加，长路径列表会自动分批调用 chezmoi，避免命令行超长；实际仓库导出仍由 `Export-OfflineRepo.ps1` 完成。
- `paths.dotfilesSource` 必须指向独立的 chezmoi source state（默认 `manifests\dotfiles`），不能填写当前用户目录；用户目录由 chezmoi 作为 destination 自动处理。
- 既有清单条目默认预选；已安装但不在清单里的条目默认不选；清单里有但本机未安装的条目显示 `(not installed)` 标记。
- 回写前自动备份为 `<清单>.bak-<yyyyMMddTHHmmssZ>`（UTC）；选中结果与原清单逐行一致时不写不备份。
- 某类全部不选则该类清单保持原样不动（绝不写空清单）。
- 需要交互式控制台（计划任务/非交互会话直接报错退出）；仅 A 端使用，不进计划任务。

### 4.0.1 导出前自动刷新已选包版本

手动运行 `Export-OfflineRepo.ps1` 与 A 端计划任务共用同一流程：**先非交互刷新 manifests，再导出包体**，无需提前运行交互式 `Export-Manifests.ps1`。

- 仅更新本轮启用类别清单里已列出、且本机能确定已安装版本的包；未钉版条目会钉到本机版本，不自动添加新包，也不删除本机未安装的条目。以本机版本为准，不查询仓库最新版本、不执行软件升级。
- 刷新 winget、pip、npm 清单；npm 类别同时刷新已启用的非空 bun 清单。完整导出还会刷新 `runtime-winget.txt`；`-SkipRuntime` 保留 runtime 清单及已发布载荷。dotfiles 继续使用现有源态，不自动运行交互选择或 `chezmoi add`。
- 保留清单条目顺序、空行、注释和换行格式；有版本变化才写入并生成唯一的 `.bak-<UTC时间>-<唯一标识>` 备份，无变化不写不备份。缺失、未知或多安装实例版本冲突的包保留原条目。
- pip 自动刷新普通包名、`==` 精确版本（含 extras、环境标记）；版本范围、URL/本地引用、带 `--hash` 的锁定清单保留原样，避免破坏约束或哈希校验，这些条目需手动维护。
- 某类采集或回写失败时，该类不继续导出，其他类别仍可处理，但本轮整体不发布；错误进入导出日志和报告，不会静默使用旧清单交付。
- 采集的是**运行导出的账户及其环境**可见的已安装包；自动任务应继续使用 A 端配置的用户环境。

### 4.1 winget 白名单（manifests\winget-packages.txt）

每行一个包：`Id` 或 `Id@version`（`#` 注释与空行忽略，自动去重）。

```
# 示例
7zip.7zip@26.02
Microsoft.PowerToys
```

- 强烈建议钉版 `Id@version`，保证 A/B 版本一致；查版本用 `winget show --id <Id> -e`（本机 winget 输出为中文，勿 grep 英文 `Version:` 标签，直接正则版本号）。
- 只有**本轮导出成功**的 Id 才会写进交付清单 `winget\packages.txt`；失败的包仅记入导出报告 `failed` 数组，不中断其他包，也不进 B 端安装清单。
- 当 `winget.scope=machine` 返回“找不到适用的安装程序”时，A 端仅对该包自动重试一次 `--scope user`，不会改变全局 scope；下载命令固定指定 `--source winget`，避免误走 Microsoft Store 源；B 端根据 YAML 的 `Scope: user` 或 MSIX/AppX 类型同步使用 user scope。
- winget 下载遇到瞬时下载/依赖下载/服务不可用/零字节载荷错误时，按与通用 HTTP 下载一致的策略最多尝试 3 次（首次 + 5 秒、15 秒退避重试）；版本不存在、无适用安装器等确定性错误不重试。
- **钉版条目启用增量导出（P1）**：钉版版本与上一版已发布载荷一致时直接复用落盘区现有文件、跳过 `winget download`（判定条件见 5.8）；未钉版条目每轮仍全量下载。
- 换版本：本机升级后下次导出自动刷新这一行；本机未安装的包可手动修改钉版。已安装包的手动钉版会在导出前同步为本机版本（见 4.0.1）。

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
- bun 是本类别的**并行前端**：bun 与 npm 消费同一棵 Verdaccio 依赖树（同一 storage 快照），bun 专属补充包见 4.5。

### 4.4 chezmoi dotfiles 源态（manifests\dotfiles\）

- 目录即 chezmoi 源态：普通文件 = 目标文件；`.plain_` 前缀 = 不渲染；`run_*` 前缀 = 脚本（`run_once_`/`run_onchange_` 幂等由 chezmoi 持久状态库保证）。
- **externals 禁用**：源态内不得出现任何 `.chezmoiexternal*` 文件，导出直接报错「离线不支持 externals」（空气隔离机 externals 不可用）。
- 模板变量：`chezmoi.toml` 的 `[data]` 节映射到模板数据根，用 `{{ .name }}`（不是 `{{ .data.name }}`）。
- 维护流程：A 上编辑 `manifests\dotfiles\` 源态 → 下次导出自动打包（`robocopy /MIR`）→ SMB 同步 → B 上 `chezmoi apply`。**B 上被本地改过的目标文件会被保守跳过并记录，绝不覆盖**（见 5.3）。

### 4.5 bun 清单（manifests\bun-packages.txt）

bun 是 **npm 类别的并行前端**，不是独立类别：格式与 npm 清单完全相同（`name`、`name@version`、`@scope/name[@version]`，包名小写，`#` 注释）：

```
# 示例（本清单默认为空）
is-odd@3.0.1
```

- **共享供给**：A 端导出时 bun 条目与 npm 条目**合并去重**（npm 优先）后经同一个一次性 Verdaccio 预热进**同一个 storage 快照**——bun 在 B 上可安装 npm 清单里的**所有**包，本清单只列 bun 专属补充包。**空清单（仅注释）合法**：bun 运行时照样交付，只是没有额外预热包。
- **运行时本体**：A 端按 `pins.bun`（version/url/sha256）钉版下载 `bun-windows-x64.zip`（sha256 哈希门，PIN-ME 流程见 5.6），随 `runtime\bun\` 载荷交付；B 端 bootstrap 落位 `<stateDir>\bun\bun.exe` + 机器 PATH + 机器级 `BUN_CONFIG_REGISTRY=http://127.0.0.1:4873/`（尾部斜杠必须；npm apply 设的 `NPM_CONFIG_REGISTRY` 对 bun 同样有效，天然双保险）。**工具不写任何 bunfig.toml/.npmrc**。
- **B 端只供给、不自动安装**（同 npm 语义）：用户按需 `bun add -g <pkg>`（无需 lockfile）；全局可执行入口落在 `%USERPROFILE%\.bun\bin`，首次使用前自行加入**用户** PATH（一次性，见 L22）。
- npm apply 顺带做 bun 视角验证：`bun info <包> version` 命中本地 registry + 不存在包 30s 内快速失败（无 uplink 挂起证明）；失败则整个 npm apply 失败。
- **关闭 bun**：删除 config 的 `pins.bun` 整节（`paths.bunList` 可一并删）——旧部署/旧 B config 无 bun 键时行为与之前完全一致（bun 全是 presence-gated）。
- Export-Manifests.ps1 支持从本机 `bun pm ls -g` 采集 bun 清单：显式 `-Category bun`（opt-in，不在默认类别中；需 config 含 `paths.bunList`），采集/多选/钉版回写流程与其他类别一致（见 4.0）。

### 4.6 npm 本地私有包目录（paths.npmLocalDirs，可空）

npm 清单（4.3）之外的**私有包预热通道**：把本机/内网自建的私有 npm 包发布进 A 端一次性 Verdaccio 的 storage 快照，使其与公共包一样经 4873 registry 供给到 B——私有包**绝不接触 npmjs**。

```json
"paths": {
  "npmLocalDirs": [ "D:\\local-npm-pkgs", "E:\\more-pkgs" ]
}
```

- **presence-gated**：config `paths.npmLocalDirs` 键不存在或为空数组 = 关闭，旧 config 不受影响；存在时每个元素须为非空字符串，路径解析同其他 `paths.*`（绝对路径原样使用、相对路径基于工具根）。
- **发现规则**：某目录本身含 `package.json` → 该目录即一个包；否则扫描其**直接子目录**（不递归）中含 `package.json` 的目录；此外若该目录声明了 monorepo workspace（见下），还会**按声明的 glob 模式递归展开其 workspace 成员**。按包名**小写去重，先到者胜**（同名后者记 Warning 跳过）。目录缺失、无任何 `package.json`、`package.json` 无法解析或缺 name/version，分别记 Error/Warning 进报告，不中断其余包。
  - **2026-09 新增「依赖清单目录」语义**：若 `package.json` 缺少 name/version 但 JSON 有效且含有非空 `dependencies` **或** `devDependencies` 对象，则该目录被识别为**依赖清单目录**（deps-manifest dir），不视为 Error——其条目以 registry 解析方式（`npm install name@spec`）预热进同一 storage 快照，使 B 端可离线 `npm install` 这些依赖。两类字段**合并收集**（`dependencies` 在前、`devDependencies` 在后）：构建工具链（typescript/vite/vitest/esbuild 等）通常落在 `devDependencies`，故必须一并预热。发现优先级：可发布包（有 name+version）> 依赖清单 > Error。依赖清单条目与清单已有包按包名**小写去重，清单优先**（同名者记 `skipped-duplicate` Warning 跳过）。含 `:` 的 spec（如 `file:../x`、`npm:@scope/legacy`、`git+https://...`）均跳过错因非 registry 可解析（记 `skipped-invalid-spec`）。
  - **2026-10 新增「monorepo workspace 递归」语义**：若配置目录宣告了 workspace——`pnpm-workspace.yaml` 的 `packages:` 块、`package.json` 的 `workspaces`（数组或 `{ "packages": [...] }` 对象）、或 `lerna.json` 的 `packages`——则按其 glob 模式**递归展开**并收集所有含 `package.json` 的成员目录（`*` 匹配单层目录，`**` 匹配任意层，`!pattern` 为排除项，始终跳过 `node_modules`；绝对模式与含 `..` 的模式忽略）。workspace 成员的包**一律作为依赖清单预热、不发布**——成员多为 workspace 内部包且其 `workspace:*` 依赖无法发布，故其 `dependencies`/`devDependencies` 中 registry 可解析的 spec 会预热进快照；配置文件里显式指向的目录仍按前述规则发现。想发布某个私有包时直接把 `npmLocalDirs` 指向该包目录即可（该目录本身含 `package.json` → 按包发布）。
- **导出语义（两阶段，一次性 Verdaccio 4874 运行窗口内）**：阶段一先把每个包 robocopy 到本地暂存目录（npm 在 UNC 路径上不可用，源目录可在 UNC 共享上）再 `npm publish --registry http://127.0.0.1:4874 --access public --ignore-scripts --userconfig <一次性 npmrc（仅含 //127.0.0.1:4874/:_auth 哑凭据）>` 进 storage 快照；阶段二对每个发布成功的包 `npm install name@version`（每包独立全新 cache）做安装验证，同时预热其 registry 依赖树。**全部 publish 先于全部 install**，因此局部包之间可以互相依赖、与发现顺序无关。npm CLI 对 registry 完全无凭据时**客户端侧直接 ENEEDAUTH 拒绝发布**（请求根本不发），因此注入一次性哑凭据：npmrc 仅含一行 `//127.0.0.1:4874/:_auth="dXNlcjpwYXNz"`（base64('user:pass')，**常量哑值、非机密**），键与 registry host:port 精确匹配、只发往 127.0.0.1；publish 路径另加 `--no-update-notifier`，防止 npm 的更新检查把 `npm` 包元数据（34MB 无用 packument）拉进 storage 快照。
- **verdaccio-a.yml 因此新增 `publish: $all` 与 `max_body_size: 100mb`**——仅 A 端一次性实例有效；`publish: $all` 是服务端许可（不校验凭据），客户端凭据靠上面的一次性哑 `_auth` 注入（npm 无凭据时客户端侧直接 ENEEDAUTH）；`verdaccio-b.yml` 绝无 `publish`/`uplinks`/`proxy`（导出期泄漏断言已硬化，三者任一出现即失败）。
- **单包失败契约**：robocopy/publish/install-verify 任一失败只记入导出报告 `local.failed`，不中断其他包与整体导出。注意两类预期失败：package.json 带 `"private": true` 会被 npm 拒绝（EPRIVATE），发布前需移除；发布与快照中已缓存公共包相同的 name@version 会被 Verdaccio 拒绝（依赖混淆防护，属预期行为）。
- **交付物 `<staging>\npm\local-packages.txt`**：生成为双行契约——局部发布包行 `name@version  # local: <源目录>`（解析器与 packages.txt 相同），依赖清单行 `<name>@<spec>  # deps: <目录>`（`# deps:` 标记区别于本地发布）。仅当至少一个局部包发布成功 **或** 至少一条依赖清单 spec 预热成功时才生成文件；两者均无产出时不创建（与基线一致）。`packages.txt` 仍是原清单逐字节复制，不受本功能影响。
- **B 端语义不变**：供给制、不自动全局安装；局部包与公共包经同一 4873 registry 按需 `npm install`。
- **注意**：npm 主清单（`manifests\npm-packages.txt`）仍需非空（现有契约，空清单导出直接报错）——纯局部包部署也至少保留一条清单条目。

### 4.7 pip 本地 wheel 目录（paths.pipLocalDirs，可空）

pip 清单（4.2）之外的**私有 wheel 通道**：把运维人员预先备好的 `*.whl` 复制进 wheel 仓库并把钉版追加进交付的 requirements——私有包**绝不接触 PyPI**。

```json
"paths": {
  "pipLocalDirs": [ "D:\\local-wheels" ]
}
```

- **presence-gated**：同 4.6 的 gating 与路径解析语义——`paths.pipLocalDirs` 键不存在或为空数组 = 关闭，交付物与原清单逐字节一致，旧 config 不受影响。
- **扫描规则**：仅扫描各目录**顶层** `*.whl`（不递归）复制进 `<staging>\pip`；`*.tar.gz` 一律**不复制**并记 Warning（与 `pip.allowSdist` 语义无关，本地目录流程只收 wheel）；无法按 PEP 427 解析文件名的 wheel 跳过并记 Warning；目录缺失记 Warning，不报错。
- **钉版追加**：从 wheel 文件名解析 `name==version`，追加进**交付的** `<staging>\pip\requirements.txt`，行尾带 `# local: <文件名>` 标记注释（UTF-8 BOM 与 CRLF/LF 均保持原样；无新增钉版时该文件完全不重写）。**原始 `manifests\requirements.txt` 绝不被修改**，A 端 `pip download -r` 也只跑原始清单。
- **去重**：与清单已有钉版按 PEP 503 归一化（小写、`-_.` 折叠为 `-`）比较——清单已钉同名包时 wheel 仍复制但**不重复追加**（报告 `copied-pin-exists`），避免 B 端 `pip install` 报 "Double requirement given"。
- **平台责任**：局部 wheel 必须匹配 B 端平台钉版（`pip.downloadArgs` 的 `win_amd64`/`cp312` 等），否则 B 端 apply 时 `pip install` 失败——这属操作员责任，导出不做平台校验。
- **导出报告**：`<staging>\pip\export-report.json` 新增 `local` 数组，`action` 取值 `copied` / `copied-pin-exists` / `skipped-sdist` / `skipped-unparseable` / `missing-dir`。

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
- `-SkipRuntime`：检测到 runtime 载荷漂移（`runtimeWingetHash`/`runtimeFilesHash` 与 state 不符）时不触发自愈重装 bootstrap，本轮照常应用类别包；从未 bootstrap 过的机器不受此开关影响（仍会完整引导）。
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

chezmoi、bun 与 VC_redist（App Installer 链不再导出/安装，见 3.2）都靠 config `pins.*.sha256` 哈希校验：

1. 把对应 `XxxSha256`（VC_redist 单件）或 `sha256`（chezmoi / bun）置为 `"PIN-ME"`。
2. 重跑 A 端导出 → 下载真实文件、打印实际 sha256 并**非零退出**（提示钉入）。
3. 把打印的 64 位 hex 写回 config 对应键。
4. 重跑导出 → 哈希校验通过后正常继续（文件已下载，不重复下载）。

- 升级**运行时钉版**（Python/Node/Verdaccio/chezmoi/bun 版本）后，B 端须**手动重跑一次 bootstrap**（幂等；packages 任务也有内容漂移自愈兜底，见已知限制 L10）。

### 5.7 工具本体到 B 的部署渠道（runtime\tool → C:\PakageSync\）

- A 端导出时把 `src\` + `config\packagesync.b.json` + 本 README 快照进 `runtime\tool\`（随仓库自举）。
- B 端 bootstrap 把该副本复制到**固定本地路径 `C:\PakageSync\`**；`C:\PakageSync\config` 归 B 本地所有，自刷新**永不覆盖**（A 侧 schema 变更需人工合并）。
- 计划任务与手动命令一律从 `C:\PakageSync\src\` 执行（任务指向 `bin\` 中永不换名的微启动器）。
- 每次 apply 在完整性通过后自刷新该副本（先 `.new` 再换名 `.old`，顺序钉死；刷新前重验 `C:\PakageSync` 属主/ACL）——**下一周期生效**。
- **首次引导必须手工复制**（见 3.2 步 2，已知限制 L12）。

### 5.8 winget 增量同步（跳过未变包）

winget 类别在两端各有一层增量跳过，**信任根链（index.json → files.json → 逐文件 SHA256）完全不变**——增量只省「下载/安装执行」，不省任何校验。

**A 端导出（P1，复用已发布载荷）**：钉版条目 `Id@version` 满足以下全部条件时，直接从落盘区现有 `winget\<Id>\` 复制载荷进 staging，**不调用 `winget download`**（导出报告 `reused` 数组记录）：

1. 条目已钉版（未钉版条目追踪「导出时最新版」，永远全量下载）；
2. 落盘区存在该包上一版载荷与 `winget\files.json`；
3. 该包每个文件与上一版 `files.json` 的 bytes/sha256 逐项匹配（**A 机落盘区损坏不会带进下一代**，损坏即回退下载）；
4. 顶层 YAML 的 `PackageVersion` 与钉版版本一致；
5. YAML 内烙死的 InstallerUrl 端口/绑定仍等于当前 config `httpBind:httpPort`（改端口自动回退下载并重写，见 5.5）。

任何条件不满足或复用检查自身报错 → 回退正常下载（fail-safe 方向），不视为导出失败。

**B 端 apply（P2，state 匹配跳过）**：安装循环前，比较工作副本 YAML 的 `PackageVersion` + 首个 `InstallerSha256` 与 `system-state.json` 的 `winget[<Id>]` 记录；两者**完全一致**则跳过该包的 `winget install`（记入 apply 报告 `skipped` 数组；全部命中时连本地 HTTP 服务都不启动）。state 记录只在真实安装成功/已满足后写入，因此匹配即证明「B 正运行 exactly 这份载荷」。

> **取舍须知**：B 上**手动卸载**的包在其 state 记录仍匹配时不会自动重装（winget 根本不会被调用）。恢复方法：删除 `C:\ProgramData\PakageSync\state\system-state.json` 中对应的 `winget.<Id>` 记录（或升级钉版版本）后重跑 apply。

## 六、已知限制

## 六、已知限制

1. **L1. winget 包依赖离线解析仅经合成 fixture 验证**：`Dependencies` 子目录依赖的端到端离线解析只用合成清单 fixture 覆盖，未经真实复杂依赖包实测（真实 7zip 无依赖，未出现 `Dependencies\` 目录）。
2. **L2. SYSTEM 上下文需机器级 VC_redist**：SYSTEM 计划任务运行 winget 的前提是机器级 VC++ 运行库（bootstrap 步骤⓪静默安装 VC_redist；Appx 版 VCLibs 已随 App Installer 安装链移除而不再相关）。
3. **L3. LocalManifestFiles 为 per-user 设置**：bootstrap 按**双上下文分别启用**（管理员 + 一次性 SYSTEM 任务）。winget v1.29.290 上它位于 `C:\ProgramData\Microsoft\WinGet\<SID>\settings\pkg\Microsoft.DesktopAppInstaller\admin_settings`（哈希保护文件，用 `winget settings export` 查看/备份）；SYSTEM 上下文路径不同：`C:\ProgramData\Microsoft\WinGet\S-1-5-18\settings\win\defaultState\admin_settings`——两处均以首次真实安装验证生效。
4. **L4. winget 版 Python 的 PATH 注册由 bootstrap 步骤③显式验证**：装后重读 machine PATH 验证 python.exe 可解析并记录，失败即明确报错（提示 bootstrap 未完成），绝不静默。
5. **L5. 离线 B 上 winget source 更新超时只记日志**：`winget install` 的 source 自动更新失败仅记日志，不阻断安装。
6. **L6. VC_redist 可接受退出码 {0, 3010, 1638}**：3010（需重启）与 1638（更高版本已装）均视为成功。
7. **L7. 端口 8788/4873/4874 为双端一致常量**：改端口须 A 侧改 config 并**重新导出**（见 5.5），B 端 config 永不覆盖 URL 中烙死的端口。
8. **L8. B 端 `C:\PakageSync\config` 归本地所有**：自刷新永不覆盖它；A 侧 config schema 变更需人工合并。
9. **L9. chezmoi 首轮语义**：首轮无基线时，预存且内容与源不同的文件一律视为本地改动，**保守跳过并报告**，绝不覆盖。
10. **L10. 升级运行时钉版后 B 须手动重跑 bootstrap**：Python/Node/Verdaccio/chezmoi 版本升级后手动重跑（幂等）；此外 packages 任务有内容漂移自愈兜底——`runtimeWingetHash`/`runtimeFilesHash` 相对 system-state 记录漂移时自动重跑 bootstrap ③④（SYSTEM 自愈路径见 L13）。
11. **L11. App Installer 安装链已移除（2026-09 决策）**：bootstrap 不再安装 msixbundle/VCLibs/UI.Xaml（现代 Windows 自带 App Installer/winget），步骤①仅校验 winget.exe 存在；原「三件套真实安装链在 A 机不可执行」的限制随移除而关闭。
12. **L12. B 端首次引导必须先手工复制 runtime\tool**：`Copy-Item C:\OfflineRepo\runtime\tool\* C:\PakageSync\` 后再从本地副本运行 bootstrap（见 3.2 / 5.7）。
13. **L13. SYSTEM 自愈 bootstrap 路径未经完整 QA**：该自动路径仅作自愈兜底，QA 不覆盖完整链；失败不阻断完成判定（手动 bootstrap 仍是受支持路径）。
14. **L14.（todo-10 QA）App Installer 依赖版本缺口：已随安装链移除而解决（2026-09 决策）**：原缺口是钉定 VCLibs（14.0.33321.0）旧于 App Installer 1.29.290 的 bundle 需求（14.0.33728.0），且 UI.Xaml 2.8 已不是当前 bundle 依赖（改为 WindowsAppRuntime 1.8）；bootstrap 不再安装这些件，WindowsAppRuntime 依赖缺口不再相关——B 端仅要求系统自带 winget.exe。
15. **L15.（todo-13 QA）`winget install --manifest <dir>` 拒绝非 YAML 文件/子目录**：winget 会把目录里每个文件当清单解析，二进制安装器会触发 `0x8a150004`；工具在 apply/bootstrap 前把每个包 staging 成**纯清单扁平目录**（只含 `*.yaml`）再传 `--manifest`，安装器保留在工作副本供本地 HTTP 服务读取（本限制仅在相关报错排查时涉及）。


16. **L16. Node MSI 同名修复限制（todo-20 QA）**：导出会把安装器改名为 YAML 主干名（如 Node.js_26.7.0_Machine_X64_wix_zh-CN.msi）；实测该改名后的 Node MSI 在"同版本已装"的修复路径上以 1603 失败（Wix4RollbackInternetShortcuts 动作返回 3），原名（node-v26.7.0-x64.msi）则成功——B 端首次引导（全新安装）预期不受影响（失败动作仅在修复/卸载序列运行），但 B 端对已装 Node 的重复引导会命中同一 1603，属部署期验证项。
17. **L17. SYSTEM 自愈 bootstrap 幂等冒烟在 A 机 QA 中失败（todo-20）**：临时 SYSTEM 任务重跑 bootstrap 在步骤 1 失败（旧版 Add-AppxPackage 在 SYSTEM 上下文被拒，0x80073CF9——本地系统账户不允许执行部署 Add 操作；步骤①已改为仅检测 winget.exe，不再执行 Add-AppxPackage）；该自动路径仍仅作自愈兜底，手动 bootstrap 是受支持路径（详见 task-20 evidence）。
18. **L18. SYSTEM 上下文 winget 安装失败（todo-20 QA 结论）**：A 机上 SYSTEM 主体执行 winget install --manifest 在"Starting package install..."处挂起（未生成 msiexec、无安装日志；直接 msiexec 在 SYSTEM 下可正常安装，挂起点在 winget 的安装器执行环节）——SYSTEM 主体 apply 路径在本机不可用，降级路径 Register-SyncTasks -Role B -PackagesTaskPrincipal User（管理员账户 S4U/Highest）实测可用；真实 B 机若 SYSTEM 安装同样挂起，请使用 User 降级注册（README 3.3）。
19. **L19. 离线模拟限制（todo-20 QA）**：A 机上 winget.exe 为打包应用（App Installer），其流量豁免 Windows 防火墙规则（程序/端口/全协议规则均实测无效），且 winget source update 对抓取失败吞错返回 0——离线 source 更新失败场景无法在 A 机复现；manifest 安装路径已实测不依赖 source 连通性（安装日志无 source 活动，仅需 loopback HTTP），真实离线 B 的 source 更新行为仍属部署期验证项。
20. **L20. bun 的 registry 配置仅经机器级环境变量**：bootstrap 设 `BUN_CONFIG_REGISTRY`，npm apply 已设的 `NPM_CONFIG_REGISTRY` 对 bun 同样有效（bun 源码确认三个键都认）；工具不管理任何 bunfig.toml/.npmrc——项目级 bunfig.toml、`.npmrc` 或 CLI `--registry` 可按 bun 优先级（CLI > env > bunfig > npmrc）覆盖它。
21. **L21. 含 `bundleDependencies` 的包 bun 可能装不上**：bun 会向 registry 索取 bundled 依赖的 manifest（bun 已知行为差异，oven-sh/bun#27418），若该内部依赖不在 Verdaccio 快照中则 `bun add` 404；npm 安装同包不受影响。遇此包改用 npm 安装，或把其内部依赖补进清单重新导出。
22. **L22. bun 全局安装的 bin 目录需用户自助加 PATH**：`bun add -g` 的可执行入口落在 `%USERPROFILE%\.bun\bin`（per-user，机器 PATH 无法覆盖），用户首次使用前自行加入用户 PATH（一次性）；bun.exe 本体已由 bootstrap 落位机器 PATH（`<stateDir>\bun`），无需任何手动步骤。
23. **L23. 局部包 publish = 服务端 `publish: $all` 许可 + 客户端一次性哑 `_auth` 注入**：npm 无凭据时**客户端侧直接 ENEEDAUTH 拒绝发布**（请求不发），而 verdaccio 的 `publish: $all` 不校验凭据——因此导出时经 `--userconfig` 注入一次性 npmrc（仅含 `//127.0.0.1:4874/:_auth="dXNlcjpwYXNz"`，base64('user:pass') 常量哑值、非机密，只发往 127.0.0.1）；该组合仅在钉版 verdaccio（6.10.2）上经 QA 实证（含 scoped/unscoped 包）。B 端 `verdaccio-b.yml` 经导出期断言保证无 `publish`/`uplinks`/`proxy`，哑凭据与 publish 规则绝不进入 B 侧。
24. **L24. 局部 npm 包以 `--ignore-scripts` 发布**：publish 不运行任何生命周期脚本，需自行包含预构建产物；package.json 的 `"private": true` 会被 npm 拒绝（EPRIVATE），发布前需移除（见 4.6）。
25. **L25. 纯局部包部署仍需 npm 主清单非空**：`manifests\npm-packages.txt` 为空时导出直接报错（现有契约不变）——只用 `paths.npmLocalDirs` 的部署也须至少保留一条主清单条目（见 4.6）。
26. **L26. 依赖清单目录的 range spec 按导出时解析结果冻结进快照**：依赖清单目录（见 4.6）的 `dependencies`/`devDependencies` 中的版本范围（如 `^1.2.3`）在 A 端导出时经 `npm install name@^1.2.3` 解析为 registry 当前最新匹配版本并缓存进 storage 快照。B 端始终消费该冻结快照，因此 B 上 `npm install` 可重现（同一份快照）。但若 A 端在一段时间后重跑导出，可能解析到 npmjs 上的更新版本（范围不变、实际内容变）——这与主清单中 `name@version` 的精确版本行为不同：主清单条目钉版锁定具体版本，而 range spec 按导出时间点解析。需精确控制时把依赖从清单目录移入主清单钉版。新增的 workspace 递归（见 4.6）同样按导出时解析冻结：`workspace:*` 等本地 spec 被跳过（非 registry 可解析），其余 registry 范围的解析结果随快照冻结。