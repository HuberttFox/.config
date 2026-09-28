# Windows Bootstrap

独立 Windows 11 x64 初始化器。它不修改 macOS `install.sh`。

入口：

```powershell
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1
```

如果系统提示 `running scripts is disabled on this system`（Windows 默认执行策略 Restricted），用仓库自带的启动器，或在当前会话临时放行：

Git Bash/MSYS2/Cygwin 下的统一入口 `./bootstrap.sh` 会转发到这里（优先 `pwsh.exe`，缺失时回退 `powershell.exe`，并自动加 `-ExecutionPolicy Bypass`）。

管理员权限：`Run`/`Resume`/`Verify`/`CleanupFailed` 需要管理员。若在非管理员窗口启动，脚本会立即通过 UAC 重新启动自身（保留原参数）并透传退出码；已在管理员窗口时静默执行，不重复弹窗。`-DryRun` 与 `-Report` 是只读操作，不提权；`-NoElevate` 可关闭自动提权（沿用原来的 `Administrator privileges are required` 报错）。

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
```

设计约束：

- 仅 Windows 11 x64、管理员 PowerShell。
- 组件失败后继续，状态与报告持久化到 `%ProgramData%\WindowsBootstrap`。
- WSL 重启通过一次性登录恢复任务续跑；完成后删除任务。
- WinGet/msstore 只执行 manifest 中有明确 ID 的静默安装；Raycast 走 Microsoft Store 源；没有可靠静默协议的项目标记 `manual_required`，不模拟 GUI。
- 直链项（dwall）使用固定 HTTPS URL + SHA-256 + 静默参数；安装/卸载都设超时，安装后轮询注册表确认，失败时尝试调用已注册卸载器。
- 仅安装 JetBrains Mono Nerd Font，下载 SHA-256 固定；不安装通用字体包。
- PowerShell 5.1/7 profile 只替换受管区块，先备份，保留用户内容。
- 薄荷输入法通过现有 Weasel/RIME profile 配置；缺少中文语言或输入法 tip 时报告人工处理，不删除已有输入法。
- 不配置系统代理、WinHTTP、Git identity、SSH key 或自定义环境变量。
- 清理只删除本次运行记录的 owned paths；不卸载既有软件、不删除未知 AppData/注册表。

完整软件清单（每项的 WinGet ID、静默参数、验证方式、manual 原因）见 [`../docs/windows-bootstrap-packages.zh-CN.md`](../docs/windows-bootstrap-packages.zh-CN.md)。
