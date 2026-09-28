# Windows RIME profile

[English](README.md) | **简体中文**

本目录为 Windows 专用 RIME 部署：安装一份标准 Weasel `0.17.4` runtime，并维护相互隔离的 Ice、Mint、Moqi 用户目录。它**不**把仓库原有 macOS/Homebrew `install.sh` 扩展到 Windows。

更广泛的无人值守 Windows bootstrap（WSL、WinGet 软件包、受管 profile、字体）见 [`../windows-bootstrap/README.md`](../windows-bootstrap/README.md)。

所有 Windows RIME 脚本只支持 **PowerShell 7 x64**（`pwsh.exe`）。既有 PowerShell 5.1 profile 保持不改，但不能运行这些脚本。

## 前置条件

- Windows 11 x64。
- 当前交互用户以签名有效的 PowerShell 7 x64 `pwsh.exe` 运行脚本。五个 Raycast wrapper 与 `bootstrap.sh`
  通过 `PATH` 启动 `pwsh.exe`（Windows 无强制安装位置）；若 `PATH` 前部存在恶意条目，可在当前用户上下文
  执行任意代码。该路径不提权；如不接受此残留风险，请收紧 `PATH`。
- 日常切换必须由受管 profile owner 运行；禁止 `SYSTEM`、其他用户 SID，或不属于该 owner 的管理员上下文。
- 网络只在未命中本地 cache 的锁定 archive 时使用；所有下载都按 [`manifests/rime.lock.json`](manifests/rime.lock.json) 校验 SHA-256。

UAC 仅用于机器级 Weasel 安装和必要时的 root ACL fallback。ACL fallback 只接受当前进程且与 `$PSHOME\pwsh.exe` 精确匹配、非 reparse、Microsoft 签名有效的 host；不从 `PATH` 查找 `pwsh.exe`。日常切换不提权。

## 入口与参数

在 Windows PowerShell 7 中运行：

```powershell
pwsh.exe -NoProfile -File .\windows\install.ps1
```

在 Windows Git Bash、MSYS2 或 Cygwin 中运行：

```bash
./bootstrap.sh
```

`bootstrap.sh` 仅在 MINGW/MSYS/Cygwin 分派到 `windows/install.ps1`；macOS 仍委派既有 `install.sh`；Linux/WSL 返回状态 `2`。必须从 Windows host 运行安装，不要从 WSL 运行。

常用变体：

```powershell
# 只安装 Ice、Mint，初始启用 Mint。
pwsh.exe -NoProfile -File .\windows\install.ps1 `
  -Profiles ice,mint -InitialProfile mint

# 安装全部 profile；Moqi 默认 Lite。
pwsh.exe -NoProfile -File .\windows\install.ps1

# 显式启用 Moqi Full，使用 Weasel quiet /deploy。
pwsh.exe -NoProfile -File .\windows\install.ps1 `
  -Profiles moqi -MoqiFull -DeployMode Quiet

# 更新 profile，不改 HKCU selector 或 RimeConfig Junction。
pwsh.exe -NoProfile -File .\windows\install.ps1 -SkipDeploy

# 先写可恢复 backup，再接管已知 legacy layout。
pwsh.exe -NoProfile -File .\windows\install.ps1 -BackupLegacy
```

其他参数：`-RimeRoot`、`-ConfigPath`、`-CacheDirectory`、`-RaycastScriptDir`、`-WeaselInstallDirectory`、`-SkipWeaselInstall`、`-NoRaycast`、`-PassThru`。自定义 root/cache 必须是本地绝对路径。

`-MoqiFull` 是显式迁移开关。受管 Moqi Full 不会静默降级成 Lite；后续更新继续带 `-MoqiFull`，或先做人工审查的迁移。

## 受管布局与 root 优先级

```text
<RimeRoot>\
├── .config-rime-root.json       # manager 与 owner-SID marker
├── RimeConfig                   # 仅指向一个 profile 的 Junction
├── profiles\
│   ├── Rime_Ice\
│   ├── Rime_Mint\
│   └── Rime_Moqi\
├── state.json                   # switch journal
├── install-report.json
├── review-export\
└── switch.lock / install.lock
```

root 优先级固定：

1. `-RimeRoot`
2. 指定 JSON config 内的 `root`
3. 既有受管 `HKCU\Software\Rime\Weasel\RimeUserDir` selector
4. 已 marker 的 `D:\ProgramData\Rime`
5. `%LOCALAPPDATA%\RimeProfiles`

标准 discovery config 是 `%LOCALAPPDATA%\config-rime\rime.json`。给出 `-ConfigPath` 时，脚本也会写标准 config，但先确认两者同指向一个受管 root。

Registry `RimeUserDir` 只写为 `<RimeRoot>\RimeConfig`。日常切换只改经验证的 Junction target，不每日重写 Registry。拒绝 UNC/device/ADS 路径、symbolic link、Junction ancestor、外部 target 与未知 layout。

## Profile 与依赖闭包

| Profile | 活跃 schema | 来源与闭包 |
| --- | --- | --- |
| Ice | `rime_ice` | 锁定 `iDvel/rime-ice` archive，包含活跃 dictionary、Lua、OpenCC、`melt_eng`、`radical_pinyin`。 |
| Mint | `rime_mint_flypy` | 锁定 `Mintimate/oh-my-rime` archive，包含活跃 dictionary、Lua、OpenCC、`radical_pinyin`、`wubi98_mint`、`stroke`、`melt_eng`。 |
| Moqi Lite | `moqi_wan_flypymo`、`moqi_single_xh` | 锁定 Moqi + Cangjie、Stroke、官方 Luna Pinyin overlay；生成 `moqi_wan.lite`，不含 Full-only 大字表/cell dictionary。 |
| Moqi Full | 相同 schema | 同一闭包，使用 `moqi_wan.extended`，含选定 `cn_dicts`、`cn_dicts_common`、`cn_dicts_cell`。 |

Moqi archive 已包含其活跃 schema 所需 radical/reverse lookup/emoji/Easy English/Japanese/Lua/OpenCC 资源。Cangjie 与 Stroke 需要 `luna_quanpin`、`luna_pinyin`，因此显式 overlay 锁定的官方 `rime/rime-luna-pinyin`；不得依赖 Weasel shared data。

Moqi staged cache identity 包含 format、主/overlay repository、commit、URL、SHA-256、选取 pattern、依赖 pin 与 Lite/Full variant。锁或选取规则变化会创建新 stage；不会复用旧身份的 cache。

## 切换、状态、报告与恢复

安装器把 control script 与 library 复制到：

```text
%LOCALAPPDATA%\config-rime\scripts
```

```powershell
$control = "$env:LOCALAPPDATA\config-rime\scripts\rime-switch.ps1"

pwsh.exe -NoProfile -File $control -Status
pwsh.exe -NoProfile -File $control -Profile ice
pwsh.exe -NoProfile -File $control -Profile mint
pwsh.exe -NoProfile -File $control -Profile moqi
pwsh.exe -NoProfile -File $control -Toggle

# 仅记录请求；不发现 runtime、不改 selector。
pwsh.exe -NoProfile -File $control -Profile ice -NoDeploy
```

`-Status` 只读，不启动或发现 Weasel。真实切换会：取得 root lock、恢复未完成 Junction transaction、验证 owner SID/active target/profile、写 `switching` journal、仅停止重新验证过的当前 SID/current session/exact executable path/start-time 相同的 `WeaselServer.exe`，切换 Junction、部署并验证新鲜 schema/table/prism artifact，最后写 `completed` 后才删除 selector backup。

Weasel 的用户名 named-pipe shutdown 无法绑定 PID/SID/session，因此不调用它。可用时只对已重新验证的 PID 调用 `CloseMainWindow()`；超时后只强制结束再次重新验证过的匹配 PID。跨 SID/session 隔离仍需原生验收。

失败时切回旧 Junction，首次部署仅清除本 transaction 创建的 selector。Registry selector transition 会 snapshot 原 property 的“存在性 + 原始值”，恢复后 read-back 验证：

- switch/deploy 失败但 Registry rollback 成功：report 写 `switch: failed`；
- rollback 抛错或 read-back 不符：report 写 `switch: recovery_required`，进程非零退出；
- `runtime`、每个 profile、`switch`、`control`、`raycast` 分别写入 `install-report.json`；后续 component 失败不会抹掉之前结果。

遇到 `recovery_required` 不要删除 `.RimeConfig.<transaction>.previous`、`state.json` 或 registry 值。保留现场，先检查 `install-report.json`，再在 Windows 原生环境中按恢复路径处理。

Interactive deployment 默认无参数并最多等待 600 秒；`-DeployMode Quiet` 使用 `/deploy`。GUI 出现不代表成功，必须有新鲜编译 artifact。

## Raycast wrapper

[`raycast/`](raycast/) 提供 Ice、Mint、Moqi、Toggle、Status 五个 `.bat` wrapper。给出已存在的 `-RaycastScriptDir` 时，只复制受管 wrapper；目录缺失/冲突时 report 写 `manual_required` 或 `failed`，不会回滚已完成的 profile。

每个 wrapper 只调用已安装 control script 的固定参数；不转发 `%*`，不接受 transaction 参数，不含 Junction logic。

## 仅审查文本导出

```powershell
$export = "$env:LOCALAPPDATA\config-rime\scripts\rime-userdata.ps1"
pwsh.exe -NoProfile -File $export `
  -Files 'custom_phrase/personal.txt','personal.custom.yaml'
```

只允许显式 `custom_phrase/*.txt` 与顶层 `*.custom.yaml` 到新 review directory。拒绝 user database、compiled table、`build/`、binary、opaque profile state。导出绝不自动 merge/import 回 profile。

## Legacy 接管与文件安全

未 marker 的 `Rime_Ice`、`Rime_Mint`、`Rime_Moqi` 必须使用 `-BackupLegacy`。仅已知 layout 可接管；普通 `RimeConfig` directory、foreign Junction、未知 legacy data、用户改过的 managed file 或冲突 copy 均 fail closed。

受管归属记录在 JSON marker 中：root 用 `.config-rime-root.json`，各受管目录用
`.config-rime-profile.json`、`managed-files.json`、`.config-rime-control.json` 或
`.config-rime-raycast.json`。缺少 `config-rime` 标记、entry 非法、指向目录之外，或在读取期间发生变化的
manifest 一律在任何 copy/delete 之前拒绝。它连同 change hash 一起才构成删除 stale managed file 的授权；
否则伪造的 manifest 可以指向任意文件。root 的 owner-SID gate 在任何 ACL grant 或 UAC elevation 之前执行。

staging、legacy backup 与 review export 的 copy 一律创建新目标：已存在、或在校验与写入之间出现的目标
一律 fail closed，不覆盖。control script 与 Raycast wrapper 则走受管 manifest：未改动的 owned 文件按
记录的 change hash 被替换，用户改过的文件保留并报告为 `manual_required`。profile staging 先复制主
archive，再按声明顺序应用 overlay，路径冲突由后声明的 overlay 获胜，且冲突在任何写入前就已解析。失败
的或已被取代的临时产物（唯一 `.tmp`
与 `.download` 文件、未标记的 staging 目录）刻意保留，因为缺少 handle-relative identity 校验时无法证明
它仍属于本次操作。

profile 更新保留 user dictionary、generated state 与用户改过的 managed file，冲突报告为 `manual_required`。
只删除精确确认仍等于受管原内容的 artifact。

所有 source/target ancestor 都会检查 reparse point，受管 copy/delete/write/archive/profile/export/control 操作在最终执行前再次验证。此措施缩小可检测 race 窗口，**不**等价于 handle-relative no-follow 防护；最终 syscall race 尚未消除，仍是 Windows 原生安全 blocker。

运行 `WeaselServer.exe` 进程枚举时，当前 session 内无法检查的候选进程会被报告为错误，而不是被当作「没有 server 在运行」；其他 session 的候选不在范围内。

## 验证边界

接手 Windows 原生验收的 Windows 11 agent 请从
[`../docs/handoff-windows-rime-native-acceptance.md`](../docs/handoff-windows-rime-native-acceptance.md) 开始：其中包含文件完整性清单、gate 命令、scratch-root 协议与仍未验证的声明列表。已执行的结论记录在 [`../docs/handoff-windows-rime-native-acceptance-evidence.md`](../docs/handoff-windows-rime-native-acceptance-evidence.md)。

便携测试可在非 Windows PowerShell 7 环境运行：

```powershell
pwsh -NoProfile -File .\tests\windows\run.ps1
```

便携 `tests/windows/run.ps1` 分别输出 passed、failed、skipped 计数，任何 failure 均返回非零。无法构造
symbolic-link fixture 的 case 报告 `SKIP`，不算 `PASS`；存在 skip 的 run 未验证 reparse 相关 case。
需先确认 `pwsh` 可用且 skip 计数为零，才可把一次运行当作证据。

测试不执行真实 Registry、UAC、安装器、Weasel deploy/process、生产 Junction/ACL、DISM、WSL、计划任务、重启或输入法操作。便携结果只能证明纯逻辑和临时目录行为，不能证明 NTFS Junction、ACL、HKCU/HKLM 视图、Weasel deployment、跨 SID/session 停止、reparse race 或 Raycast 真实调用。

发布前必须完成 [Windows 原生验收](../docs/architecture.zh-CN.md#windows-原生验收)。
