# 开发指南

[English](development.md) | **简体中文**

本仓库的环境、验证、编码风格与组件编写。

## Windows 边界

Windows 功能与 `install.sh` 分离。`windows-bootstrap/` 是无人值守 Windows 11 入口，兼容 Windows PowerShell 5.1 与 PowerShell 7；`windows/` 是 PowerShell 7 x64 的 RIME 部署。参见 [Windows bootstrap](../windows-bootstrap/README.md) 与 [Windows RIME](../windows/README.zh-CN.md)。便携 suite 不等于原生验收；见 [Windows 原生验收](architecture.zh-CN.md#windows-原生验收) 与 [验收证据](handoff-windows-rime-native-acceptance-evidence.md)。

## 环境

无传统构建，无包管理器。仓库即 `~/.config` 的线上安装本体；直接克隆到该路径即可。除 macOS 自带工具外无依赖，可选装 ShellCheck。

## 验证

```bash
# 沙箱集成测试（临时 HOME、命令 stub）
./tests/integration.sh

# 语法检查全部 shell 文件
find . -type f -name "*.sh" -exec bash -n {} +

# 静态检查（安装了 ShellCheck 时）
find . -type f -name "*.sh" -exec shellcheck {} +
```

```powershell
# Windows bootstrap 便携 suite（Windows PowerShell 5.1 或 PowerShell 7）
pwsh -NoProfile -File .\windows-bootstrap\tests\run.ps1
powershell.exe -NoProfile -File .\windows-bootstrap\tests\run.ps1

# 无变更的 bootstrap 计划
pwsh -NoProfile -File .\windows-bootstrap\install.ps1 -DryRun

# RIME 便携 suite（PowerShell 7 x64）
pwsh -NoProfile -File .\tests\windows\run.ps1
```

规则：

- 安装器改动必须配套 `tests/integration.sh` 覆盖。
- 测试使用临时 `HOME`/状态目录与 stub。绝不可调用真实 Homebrew、网络、`sudo`、`chsh` 或应用安装器。
- `--dry-run` 故意不支持；请用集成测试代替。
- `windows-bootstrap` 改动必须配套 `windows-bootstrap/tests/run.ps1` 覆盖，并保持 `-DryRun` 不产生 state/report/lock/Registry/profile/WSL/输入法变更。
- 新增 RIME `.ps1` 文件必须声明 `#requires -Version 7.0`；`windows-bootstrap` 脚本有意声明 `#requires -Version 5.1`。

## Bash 风格

- 脚本以 `#!/usr/bin/env bash` 和 `set -euo pipefail` 开头。
- 变量展开必须加引号。
- 函数内使用 `local`。
- 优先用 `printf` 而非 `echo`。
- 从 `ROOT_DIR` 或 `CONFIG_REPO` 派生的路径 source 共享库。
- 致命错误用 `die`。
- 工具逻辑放在 `scripts/components/<name>.sh`，勿膨胀 `install.sh`。

## 新增组件

1. 创建 `scripts/components/<name>.sh`，实现 `formulae`、可选 `taps`、`casks`、`apply`、`verify`。
2. 在 `install.sh` 的 `ALL_COMPONENTS` 中加入 `<name>`。
3. 软件包需求通过 `formulae`/`taps`/`casks` 在 `apply` 前声明；勿在 `apply` 内临时安装。
4. 若组件管理用户文件、符号链接或配置文件行，必须使用 `scripts/lib/common.sh` 与 `scripts/lib/transaction.sh` 的事务感知辅助函数。
5. 在 `tests/integration.sh` 增加集成测试覆盖。
6. 勿添加平台子命令或 Linux 分支。

### 仅软件包组件

简单工具可做成纯包组件：

```bash
case "${1:-}" in
  formulae) printf 'tool\n' ;;
  taps) ;;
  casks) ;;
  apply) : ;;
  verify) ensure_command_available tool ;;
  *) die "Unknown subcommand for tool: ${1:-}" ;;
esac
```

## 调试诊断

`./install.sh --debug` 输出非敏感诊断：组件选择、软件包计划、组件脚本路径、Homebrew 路径、事务 ID 与软件包命令。绝不打印密钥或启用 shell tracing。

## 事务感知文件辅助函数

请使用 `scripts/lib/common.sh` 中的这些函数，而非直接文件操作：

| 函数 | 用途 |
| --- | --- |
| `ensure_symlink target path` | 创建/修正符号链接，记日志 |
| `write_managed_file path` | 将 stdin 原子写入路径，记日志 |
| `ensure_line_in_file path line` | 缺失时追加一行，记日志 |
| `remove_managed_path_if_exact_file` | 仅精确匹配时移除旧 loader |
| `transaction_prepare` / `transaction_applied` | 底层日志记录（经辅助函数调用） |
