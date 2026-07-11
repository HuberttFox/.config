# dotfiles 引导配置

[English](README.md) | **简体中文**

本仓库应放置在 `~/.config`。

## 安装

安装全部组件：

```bash
./install.sh --all
```

预览操作但不修改文件：

```bash
./install.sh --all --dry-run
```

安装部分组件：

```bash
./install.sh --only zsh,tmux,fzf
```

## 注意事项

- 优先使用 Homebrew formula 安装软件。
- `zim` 会下载 `zimfw.zsh`，将 `~/.zimrc` 链接到仓库管理的配置，并生成 `~/.zim/init.zsh`，但不会重写 `~/.zshrc`。
- `tmux` 会先安装 TPM（`~/.tmux/plugins/tpm`），再加载仓库管理的 tmux 配置。
- `vim`、`neovim`、`yazi` 和 `neofetch` 通过 Homebrew formula 安装，只验证命令是否可用。
- `iterm2` 和 `alacritty` 在 macOS 上通过 Homebrew cask 安装。
- `kitty` 在 macOS 上通过 Homebrew cask 安装；在 Linux 上使用 Kitty 官方安装脚本，并链接到 `~/.local/bin`。
- `finicky` 在 macOS 上通过 Homebrew cask 安装，为浏览器模式工作流提供 URL 路由。
- `install.sh` 不安装 Claude Code、Codex 和 OpenCode 可执行文件；请单独安装。
- 已有文件会备份到 `~/.config/.backup/<timestamp>/`。
- 私有状态不会被覆盖。
- 如果选择了 `zsh`，但当前登录 Shell 不是 `zsh`，安装器会尝试自动执行 `chsh -s <resolved-zsh-path>`。
- 如果对应的 `zsh` 路径不在 `/etc/shells` 中，安装器会先尝试注册该路径，并可能要求输入 `sudo` 密码。
- 软件包安装和 Shell 切换完成后，安装器会把 `brew shellenv` 写入与当前登录 Shell 对应的配置文件。

## 仅限本地的应用配置

`codex/`、`opencode/`、`cursor/`、`orbstack/` 和 `vscode/` 下的配置及运行时数据仅保留在本地，并由 Git 忽略。本仓库不安装、同步或管理这些应用。

`raycast/ai/providers.yaml` 包含 Provider 凭据，因此也只保留在本地。

## Finicky + Raycast（仅 macOS）

本配置使用 Finicky 作为 URL 路由器，并通过 Raycast Script Commands 切换当前浏览器模式。

配置说明：

- Finicky 配置位于 `finicky/finicky.dia.js` 和 `finicky/finicky.atlas.js`。
- 安装器或模式切换脚本会把当前配置链接到 `~/.finicky.js`。
- 浏览器模式通过替换 `~/.finicky.js` 符号链接进行切换，可选值为 `dia` 和 `atlas`。
- 辅助脚本为 `scripts/browser-mode`，仅支持 macOS，并会重启 Finicky。
- 如果系统中存在 `terminal-notifier`，通知由它发送；否则使用 `osascript`。

建议的 Raycast Script Command：

- 使用 `raycast/script-commands/browser-mode.sh`，然后从浏览器列表中选择目标模式。

这些工具的运行时状态、认证文件、日志、扩展、会话、虚拟机状态及其他机器相关数据都应排除在 Git 之外。
