# Windows Bootstrap 软件清单参考

[English](windows-bootstrap-packages.md) | **简体中文**

本文档逐项解释 [`windows-bootstrap/install.ps1`](../windows-bootstrap/install.ps1) 消费的软件清单。[`windows-bootstrap/packages/`](../windows-bootstrap/packages/) 下的 JSON 是唯一真源，本页说明每一项装什么、怎么验证。

运行顺序与分组：`Base` → `Core` → `Optional`。`-Profile Base|Core|Optional|All` 选择子集；`-NoOptional` 从 `All` 中去掉可选组。

## 执行模型

清单项必须满足完整契约，否则安装器在运行任何组件前直接报错：

| 字段 | 用途 |
| --- | --- |
| `name` | 状态与报告中使用的组件名 |
| `mode` | `winget`、`wsl`、`font`、`rime`、`input-method`、`powershell-profile` 或 `manual` |
| `version` | 版本策略（`winget-latest-stable`、固定版本或 `manual-review`） |
| `architecture` | `x64` 或 `all` |
| `silentInstallArgs` | 非交互参数数组 |
| `uninstallCommand` | `{ type, args }`；卸载时替换 `{wingetId}` |
| `source` | 软件来源 |
| `checksum` | 完整性/验证策略 |
| `verification` | `{ type, ... }` 验证元数据 |
| `wingetId` | `mode: winget` 时必填 |
| `wingetSource` | 可选 WinGet 源覆盖：`winget`（默认）或 `msstore` |
| `url` | `mode: download` 时必填；精确的 HTTPS 安装包直链 |
| `installerType` | 仅元数据（`nsis`、`inno` 等）；静默参数在 `silentInstallArgs` |
| `installLocation` | 期望的绝对安装目录（如 `D:\Program Files\Git`）；D 盘策略命中时通过 WinGet `--location` 传递 |
| `locationSupport` | `inno`、`msi`、`nsis` 或 `none`；`none` 表示该项不传 `--location` |
| `locationProbe` | 期望目录与回退目录下核对的实际文件，用于报告真实安装位置 |
| `cleanupMode` | `winget-uninstall-if-new`、`owned-files-only`、`backup-restore` 或 `manual` |
| `reason` | `manual` 项必填，写入报告 |

模式行为：

- `winget` — 先 `winget list --id <id> --exact`。已安装 → `completed`，绝不改动。否则 `winget install --id <id> --exact --source <winget|msstore> <silentInstallArgs>`，再复查。源默认 `winget`；`wingetSource: msstore`（或 `source: msstore:<productId>` 前缀）选择 Microsoft Store 源，用于 Raycast。已有软件绝不卸载或升级。
- 失败清理 — 安装失败但包已注册时，`cleanupMode: winget-uninstall-if-new` 立即卸载：卸载成功记 `failed_cleaned`，否则 `failed_uncleaned`。
- 超时 — WinGet 安装与卸载都有上限（安装 900 秒、卸载 300 秒）。卡死的进程树会被终止并记为失败，而不是阻塞整个运行。
- `download` — 固定直链下载。安装器按 `silentInstallArgs` 运行并设 900 秒上限，随后最多轮询 60 秒等待卸载注册表项。失败时 `cleanupMode: download-uninstall-if-new` 调用已注册卸载器；未完成项保留在失败列表里，`-CleanupFailed` 可重试。
- `manual` — 不安装、不下载。记录为 `manual_required` 并附 `reason`，运行继续。
- 其他模式（WSL、字体、RIME 桥接、输入法、托管 profile）由专门的 bootstrap 函数执行。

运行结束的 `final-verification` 检查 `git.exe`、`pwsh.exe`、`wt.exe`、WSL 2 Ubuntu 实况、托管 PowerShell profile 区块，以及 Font、Mint RIME、输入法、profile 组件的存活状态。

## Base 组 — `base.json`

| 项目 | WinGet ID | 静默参数 | 验证方式 | 清理 |
| --- | --- | --- | --- | --- |
| Git | `Git.Git` | `--silent --accept-source-agreements --accept-package-agreements --disable-interactivity` | `winget list`；最终检查运行 `git.exe --version` | uninstall-if-new |
| PowerShell 7 | `Microsoft.PowerShell` | 同上 | `winget list`；最终检查要求 `pwsh.exe` 主版本 ≥ 7 | uninstall-if-new |
| Windows Terminal | `Microsoft.WindowsTerminal` | 同上 | `winget list`；最终检查运行 `wt.exe --version` | uninstall-if-new |
| lazygit | `JesseDuffield.lazygit` | 同上 | `winget list` | uninstall-if-new |

## Core 组 — `core.json`

| 项目 | 模式 | 来源 / 动作 | 验证 | 清理 |
| --- | --- | --- | --- | --- |
| WSL 2 + Ubuntu LTS | `wsl` | `wsl --install --distribution Ubuntu-24.04 --no-launch`，再设默认版本 2 | `wsl --list --verbose`：Ubuntu 发行版存在且为 version 2 | manual — 依赖 Windows servicing；需要重启时 bootstrap 注册一次性登录恢复任务并 `-Resume` 续跑 |
| JetBrains Mono Nerd Font | `font` | 固定 `v3.5.1` 发布包，`sha256:fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e` | 选中的 TTF 文件存在，且每个文件都有对应的 `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` 注册 | owned-files-only |
| Mint RIME | `rime` | 调 `windows/install.ps1 -Profiles mint -InitialProfile mint -DeployMode Quiet -NoRaycast` | 本次调用新写出的 `install-report.json`（时间窗 + SHA-256）、mint `completed`、根目录/Junction 匹配 | manual |
| Mint 默认输入法 | `input-method` | 当前用户语言列表 | 预期 TIP（`0804:E02\d+0804`）存在、英文项保留、API 可用时设置默认输入法 | manual |
| PowerShell profiles | `powershell-profile` | [`windows-bootstrap/config/powershell/profile.ps1`](../windows-bootstrap/config/powershell/profile.ps1) 受管区块 | Windows PowerShell 5.1 与 PowerShell 7 profile 文件中都存在精确的受管区块 | backup-restore |

## Optional 组 — `optional.json`

WinGet 项 — 相同静默参数，用 `winget list` 验证，清理 `winget-uninstall-if-new`：

| 项目 | WinGet ID |
| --- | --- |
| Obsidian | `Obsidian.Obsidian` |
| Typora | `appmakes.Typora` |
| Thunderbird | `Mozilla.Thunderbird` |
| Telegram | `Telegram.TelegramDesktop` |
| Steam | `Valve.Steam` |
| CC-Switch | `farion1231.CC-Switch` |
| Clash Verge Rev | `ClashVergeRev.ClashVergeRev` |
| Zen Browser | `Zen-Team.Zen-Browser` |
| Raycast | `9PFXXSHC64H3`（Microsoft Store 源） |
| 百度网盘 | `Baidu.BaiduNetdisk` |
| 夸克网盘 | `Alibaba.QuarkCloudDrive` |
| 欧路词典 | `EuSoft.Eudic` |
| Visual Studio Code | `Microsoft.VisualStudioCode` |
| Geek Uninstaller | `GeekUninstaller.GeekUninstaller` |

## 固定直链下载项 — `dwall`

| 项目 | 版本 | URL | SHA-256 | 静默参数 | 验证 | 清理 |
| --- | --- | --- | --- | --- | --- | --- |
| dwall | 0.2.5 | `https://github.com/dwall-rs/dwall/releases/download/v0.2.5/Dwall.Settings_0.2.5_x64-setup.exe` | `sha256:c448c0d28843523f6121d9edff7d03dd74f422b83f97d0de42b3087f3a182fee` | `/S` | 卸载注册表项 `Dwall Settings` | download-uninstall-if-new |

已无 `manual` 项；该模式仍保留给将来无法固定的条目。

## 安装位置策略

当 `D:` 是本地固定磁盘（`DriveType 3`）且剩余空间不少于 10 GB 时，声明了 `installLocation` 的项会通过 WinGet `--location` 尝试装到该目录；否则使用系统盘上的同一相对路径。忽略该请求的安装器仍会正常安装，运行时记录 `attemptedLocation`，并在 `locationProbe` 命中时记录 `actualLocation`——报告不会声称未发生的迁移。Git 与 Visual Studio Code 是该行为的试点。

机器级作用域很关键：Git、Visual Studio Code 这类 Inno 安装器只有在 WinGet 以 `--scope machine` 安装时才会采纳 `--location`，因此两项都传递该开关（已在 disposable guest 验证：位置分别为 `D:\Program Files\Git` 与 `D:\Program Files\Microsoft VS Code`）。其他项在逐项验证前保持各自的默认 scope。

## 修改清单

- 必须补齐全部契约字段；`windows-bootstrap/tests/run.ps1` 内含清单契约回归（缺字段、不支持的架构、缺 WinGet ID）。
- 只有当 package ID、静默安装、验证、静默卸载全部固定并通过测试后，才把 `manual` 项升级为 `winget`；仅 Microsoft Store 有货的产品使用 `wingetSource: msstore`。
- 固定直链项必须提供 HTTPS `url`、`sha256:` 校验值、`registry-uninstall` 卸载契约与 `uninstall-registry` 验证显示名；测试覆盖契约与命令行解析。
- 固定发布来源（如字体包）必须带精确 URL 与 SHA-256；WinGet 项依赖 WinGet 源与签名校验。
