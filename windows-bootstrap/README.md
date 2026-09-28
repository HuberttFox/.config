# Windows Bootstrap

独立 Windows 11 x64 初始化器。它不修改 macOS `install.sh`。

入口：

```powershell
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1
```

如果系统提示 `running scripts is disabled on this system`（Windows 默认执行策略 Restricted），用仓库自带的启动器，或在当前会话临时放行：

Git Bash/MSYS2/Cygwin 下的统一入口 `./bootstrap.sh` 会转发到这里（优先 `pwsh.exe`，缺失时回退 `powershell.exe`，并自动加 `-ExecutionPolicy Bypass`）。

管理员权限：`Run`/`Resume`/`Verify`/`CleanupFailed` 需要管理员。普通用户窗口的 `Run`/`Resume` 会先运行清单中 `executionContext: user` 的项目（当前是 Spotify 与 PotPlayer PortableApps handoff），再通过 UAC 启动管理员 child，保留参数与 run ID 并透传退出码。normal-user phase 必须是同一 SID 的非管理员、session ≥1、Medium token；handoff 的 run ID、profile、时间戳、全部选中 manifest 项的 canonical SHA-256 和逐项结果都要匹配。`%LOCALAPPDATA%\WindowsBootstrap\UserPhase\<runId>` 与 `handoff.json` 必须为受保护 DACL，且仅 owner SID 与 `SYSTEM` 有 FullControl。child 再以 elevated token 实况复核 Spotify `winget list`。已在管理员窗口启动时不会尝试 reverse UAC，user 项明确记为 `manual_required`。`Verify`/`CleanupFailed` 仍直接提权；`-DryRun` 与 `-Report` 是只读操作，不提权；`-NoElevate` 可关闭自动提权（沿用原来的 `Administrator privileges are required` 报错）。

运行反馈：每个组件打印 `[i/N] 名称 ...` 与 `[i/N] 名称 - 状态 (耗时)`；交互终端会同步显示 `Write-Progress` 进度条。长任务（winget 下载、dwall 安装器、RIME/Weasel 部署）的子进程输出会实时写入 `<StateRoot>\logs\bootstrap.log`，报告里带 `logPath`。`-Quiet` 只保留日志（不打印进度行），`-NoProgress` 关闭进度条但保留文本行；`-PassThru` 时 stdout 保持纯 JSON。

```batch
:: 免执行策略启动（非管理员窗口会自动申请提权）
.\windows-bootstrap\install.cmd -DryRun
```

```powershell
# 只在当前进程生效，不修改系统策略
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\windows-bootstrap\install.ps1 -DryRun

# 或用参数直接绕过
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-bootstrap\install.ps1 -DryRun
```

诊断：

```powershell
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -DryRun
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Profile Base -DryRun
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Verify
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Report
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -CleanupFailed
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Resume

# PotPlayer: default only downloads and SHA-256 checks PortableApps package.
# GUI launch and completion are separate explicit user actions.
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Profile Optional -PortableAppsRoot 'D:\PortableApps'
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Profile Optional -PortableAppsRoot 'D:\PortableApps' -LaunchPortableHandoff
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1 -Profile Optional -PortableAppsRoot 'D:\PortableApps' -ConfirmPortableHandoff
```

设计约束：

- 仅 Windows 11 x64；machine phase 需要管理员 PowerShell，normal-user phase 必须从同一用户的 Medium-integrity 桌面终端启动。
- 组件失败后继续，状态与报告持久化到 `%ProgramData%\WindowsBootstrap`。
- WSL 重启通过一次性登录恢复任务续跑；完成后删除任务。
- WinGet/msstore 只执行 manifest 中有明确 ID 的静默安装；Raycast 走 Microsoft Store 源。Spotify 固定为 normal-user `--scope user` 阶段，绝不在管理员 token 下启动；只有 protected handoff 导入和 elevated `winget list` 都通过才记为 completed。PotPlayer 采用 PortableApps.com 固定 HTTPS URL + SHA-256 的交互 handoff：默认只下载/校验，绝不伪造静默成功或模拟 GUI。
- 直链项（dwall）使用固定 HTTPS URL + SHA-256 + 静默参数；安装/卸载都设超时，安装后轮询注册表确认，失败时尝试调用已注册卸载器。
- D 盘优先：本地固定 D 盘且剩余空间 ≥10 GB 时，带 `installLocation` 的组件通过 `--location` 尝试装到 `D:\Program Files\...`，否则回退系统盘；报告记录 `attemptedLocation`/`actualLocation`，安装器忽略请求时如实反映。
- 仅安装 JetBrains Mono Nerd Font，下载 SHA-256 固定；不安装通用字体包。
- PowerShell 5.1/7 profile 只替换受管区块，先备份，保留用户内容。
- 薄荷输入法通过现有 Weasel/RIME profile 配置；缺少中文语言或输入法 tip 时报告人工处理，不删除已有输入法。
- 不配置系统代理、WinHTTP、Git identity、SSH key 或自定义环境变量。
- 清理只删除本次运行记录的 owned paths；不卸载既有软件、不删除未知 AppData/注册表。PotPlayer PortableApps 目标目录始终归用户所有，不属于 bootstrap cleanup。

完整软件清单（每项的 WinGet ID、静默参数、验证方式、manual 原因）见 [`../docs/windows-bootstrap-packages.zh-CN.md`](../docs/windows-bootstrap-packages.zh-CN.md)。
