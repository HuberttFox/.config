# 文档

[English](README.md) | **简体中文**

dotfiles 引导仓库的技术文档。

## 索引

| 文档 | 内容 |
| --- | --- |
| [架构](architecture.zh-CN.md) | 安装流程、组件模型、事务系统、Zsh 策略、范围与忽略路径 |
| [组件](components.zh-CN.md) | 逐组件参考：formula、tap、cask、apply/verify 行为 |
| [开发](development.zh-CN.md) | 环境、验证、Bash 风格、组件编写清单 |
| [故障排查](troubleshooting.zh-CN.md) | 常见失败、报错信息与修复 |
| [密钥](secrets.zh-CN.md) | `.env` 约定、渲染器行为、安全规则 |
| [Windows bootstrap](../windows-bootstrap/README.md) | 无人值守 Windows 11 入口、生命周期状态机、恢复、manifest |
| [Windows bootstrap 软件清单](windows-bootstrap-packages.zh-CN.md) | `windows-bootstrap/packages/*.json` 逐项参考：WinGet ID、静默参数、验证方式、manual 原因 |
| [Windows RIME](../windows/README.zh-CN.md) | 独立 Windows 11/PowerShell 7 x64 RIME profile、恢复/report 语义、原生验收边界 |
| [Windows 验收证据](handoff-windows-rime-native-acceptance-evidence.md) | bootstrap 与 RIME 在 disposable guest 的 PASS/BLOCKED/UNVERIFIED 记录 |

## 速查

- macOS 安装器：`./install.sh`（见 [README](../README.zh-CN.md)）
- Windows bootstrap：Windows 11 x64 运行 `pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1`（Windows PowerShell 5.1 或 PowerShell 7）；`-DryRun` 不产生任何变更。
- Windows bootstrap 软件清单：[windows-bootstrap-packages.zh-CN.md](windows-bootstrap-packages.zh-CN.md) — 每一项的 WinGet ID、静默参数、验证方式与清理策略。
- Windows RIME：Windows 11 x64 运行 `pwsh.exe -NoProfile -File .\windows\install.ps1`；`bootstrap.sh` 仅在 Windows MINGW/MSYS/Cygwin 分派。
- 代理指南：[AGENTS.md](../AGENTS.md)
- macOS 沙箱测试：`./tests/integration.sh`
- Windows 便携测试：`pwsh -NoProfile -File .\tests\windows\run.ps1`；不等于 Windows 原生验收。
