# Windows Bootstrap

独立 Windows 11 x64 初始化器。它不修改 macOS `install.sh`。

入口：

```powershell
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1
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
- 仅安装 JetBrains Mono Nerd Font，下载 SHA-256 固定；不安装通用字体包。
- PowerShell 5.1/7 profile 只替换受管区块，先备份，保留用户内容。
- 薄荷输入法通过现有 Weasel/RIME profile 配置；缺少中文语言或输入法 tip 时报告人工处理，不删除已有输入法。
- 不配置系统代理、WinHTTP、Git identity、SSH key 或自定义环境变量。
- 清理只删除本次运行记录的 owned paths；不卸载既有软件、不删除未知 AppData/注册表。

完整软件清单（每项的 WinGet ID、静默参数、验证方式、manual 原因）见 [`../docs/windows-bootstrap-packages.zh-CN.md`](../docs/windows-bootstrap-packages.zh-CN.md)。
