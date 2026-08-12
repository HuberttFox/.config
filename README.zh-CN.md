# dotfiles 引导配置

[English](README.md) | **简体中文**

仅支持 macOS 的引导配置仓库，应放置在 `~/.config`。安装器管理 Homebrew 软件包及 Shell、终端、开发 CLI 工具的仓库自有配置。详见 [docs/](docs/)。

## 快速开始

```bash
# 安装全部保留组件
./install.sh

# 指定组件
./install.sh --only zsh,tmux,fzf

# 排除组件
./install.sh --skip tmux,yazi

# 自动化安全模式：绝不询问或更改登录 Shell
./install.sh --no-shell-switch

# 回滚最近一次安装
./install.sh --rollback latest
```

安装器按 `安装软件包 → 应用配置 → 验证` 执行，并将每次文件与符号链接变更记入事务。完整流程与回滚语义见 [docs/architecture.zh-CN.md](docs/architecture.zh-CN.md)。

## 组件

| 分组 | 组件 |
| --- | --- |
| Shell | `git`、`zsh`、`zim`、`fzf`、`starship`、`tmux` |
| 开发 CLI | `lazygit`、`vim`、`yazi`、`mole`、`gh` |
| 应用 | `ccswitch` |

逐组件参考（formula、tap、cask、apply/verify 行为）：[docs/components.zh-CN.md](docs/components.zh-CN.md)。

## 文档

- [docs/](docs/) — 索引
- [架构](docs/architecture.zh-CN.md) — 安装流程、组件模型、事务、Zsh 策略
- [组件](docs/components.zh-CN.md) — 逐组件软件包与配置参考
- [开发](docs/development.zh-CN.md) — 环境、验证、Bash 风格、组件编写
- [故障排查](docs/troubleshooting.zh-CN.md) — 常见失败与修复
- [密钥](docs/secrets.zh-CN.md) — `.env` 约定、渲染器、安全规则

## 许可证

MIT
