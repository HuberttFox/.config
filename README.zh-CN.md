# dotfiles 引导配置

[English](README.md) | **简体中文**

macOS 引导配置仓库，应放置在 `~/.config`。`install.sh` 管理 Homebrew 软件包及 Shell、终端、开发 CLI 工具的仓库自有配置。独立的 Windows 功能位于 [`windows-bootstrap/`](windows-bootstrap/)（无人值守 Windows 11 引导）与 [`windows/`](windows/)（RIME profile 部署），二者都绝不通过 `install.sh` 运行。详见 [docs/](docs/)。

## 快速开始

```bash
# 安装全部保留组件
./install.sh

# 指定组件
./install.sh --only zsh,tmux,fzf

# 排除组件
./install.sh --skip tmux,yazi

# 仅安装 AI 编码代理
./install.sh --only opencode,codex,claude-code,pi

# 自动化安全模式：绝不询问或更改登录 Shell
./install.sh --no-shell-switch

# 回滚最近一次安装
./install.sh --rollback latest
```

安装器按 `安装软件包 → 应用配置 → 验证` 执行，并将每次文件与符号链接变更记入事务。完整流程与回滚语义见 [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md)。

## Windows

Windows 11 x64 有两个独立入口，都不经过 `install.sh`：

- [`windows-bootstrap/install.ps1`](windows-bootstrap/) — 无人值守全量引导：preflight、WinGet 软件包、WSL 2 + Ubuntu LTS、固定 JetBrains Mono Nerd Font、受管 PowerShell profile 以及 RIME 步骤；支持 `Run`/`Resume`/`Verify`/`Report`/`CleanupFailed`/`DryRun`，兼容 Windows PowerShell 5.1 与 PowerShell 7。免执行策略的启动器为 [`install.cmd`](windows-bootstrap/install.cmd)。

```powershell
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1
```

或者用 [`windows-bootstrap/install.cmd`](windows-bootstrap/install.cmd)（带 `-ExecutionPolicy Bypass`，不需要改策略）。安装/恢复等操作请在管理员终端运行。

- [`windows/install.ps1`](windows/) — PowerShell 7 x64 的 RIME profile 部署：三个隔离 profile、固定 `RimeConfig` Junction selector 与 Raycast wrapper。

```powershell
pwsh.exe -NoProfile -File .\windows\install.ps1
```

Windows Git Bash/MSYS2/Cygwin 可由 [`bootstrap.sh`](bootstrap.sh) 分派到 RIME 入口；macOS 仍委派给 `install.sh`，Linux/WSL 被拒绝。

参见 [Windows bootstrap 指南](windows-bootstrap/README.md)、[软件清单参考](docs/windows-bootstrap-packages.zh-CN.md)、[Windows RIME 指南](windows/README.zh-CN.md) 与 [原生验收证据](docs/handoff-windows-rime-native-acceptance-evidence.md)。便携测试不认证 Windows 原生 Registry、ACL、Junction、Weasel、进程隔离、reparse race 或 Raycast。

## 组件

| 分组 | 组件 |
| --- | --- |
| Shell | `git`、`zsh`、`zim`、`fzf`、`starship`、`tmux` |
| 开发 CLI | `lazygit`、`vim`、`yazi`、`mole`、`gh` |
| AI 编码代理 | `opencode`、`codex`、`claude-code`、`pi` |
| 应用 | `ccswitch` |

逐组件参考（formula、tap、cask、apply/verify 行为）：[docs/components.zh-CN.md](docs/components.zh-CN.md)。

## 文档

- [docs/](docs/) — 索引
- [架构](docs/architecture.zh-CN.md) — 安装流程、组件模型、事务、Zsh 策略
- [组件](docs/components.zh-CN.md) — 逐组件软件包与配置参考
- [开发](docs/development.zh-CN.md) — 环境、验证、Bash 风格、组件编写
- [故障排查](docs/troubleshooting.zh-CN.md) — 常见失败与修复
- [密钥](docs/secrets.zh-CN.md) — `.env` 约定、渲染器、安全规则
- [Windows bootstrap](windows-bootstrap/README.md) — 无人值守 Windows 11 入口、生命周期状态机与恢复语义
- [Windows RIME](windows/README.zh-CN.md) — 独立 Windows 11/PowerShell 7 x64 profile 部署与原生验收边界
- [原生验收证据](docs/handoff-windows-rime-native-acceptance-evidence.md) — disposable Windows 11 guest 上的通过、阻塞与未验证项

## 许可证

MIT

## 联系

- GitHub: [HuberttFox/.config](https://github.com/HuberttFox/.config)
