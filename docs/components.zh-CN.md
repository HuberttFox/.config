# 组件参考

[English](components.md) | **简体中文**

全部 16 个安装器组件的逐组件参考。每个组件脚本实现 `formulae`、`taps`、`casks`、`apply`、`verify` 的子集。组件模型见 [架构](architecture.zh-CN.md)。

## 汇总

| 组件 | Formula | Tap / Cask | Apply 行为 | Verify |
| --- | --- | --- | --- | --- |
| `git` | `git` | — | 若精确匹配则移除旧 `~/.gitconfig` loader | `git` 可用 |
| `zsh` | — | — | 写入 `~/.zshenv`、`~/.zshrc` loader 文件 | `/bin/zsh` + loader 文件 |
| `zim` | — | — | 符号链接 `~/.zimrc`，安装 zimfw + init | zimfw、init、`.zimrc` 符号链接 |
| `fzf` | `fzf` | — | 要求存在 `zsh/fzf.zsh` | `fzf` 可用 |
| `starship` | `starship` | — | 空操作 | `starship` 可用 |
| `tmux` | `tmux` | — | 克隆 TPM、安装插件、移除旧 loader | TPM + 配置可 source |
| `lazygit` | `lazygit` | — | 空操作 | `lazygit` 可用 |
| `vim` | `vim` | — | 空操作 | `vim` 可用 |
| `yazi` | `yazi` | — | 空操作 | `yazi` 可用 |
| `ccswitch` | — | tap `farion1231/ccswitch`，cask `cc-switch` | 空操作 | app 或命令 |
| `mole` | `mole` | — | 空操作 | `mole` 可用 |
| `gh` | `gh` | — | 空操作 | `gh` 可用 |
| `opencode` | `opencode` | tap `anomalyco/tap` | 空操作 | `opencode` 可用 |
| `codex` | — | cask `codex` | 空操作 | `codex` 可用 |
| `claude-code` | — | cask `claude-code` | 空操作 | `claude` 可用 |
| `pi` | `pi-coding-agent` | — | 空操作 | `pi` 可用 |

## 配置归属

仓库自有配置（跟踪文件，运行时消费）：

| 组件 | 配置路径 | 备注 |
| --- | --- | --- |
| `git` | `git/config`（XDG `~/.config/git/config`）、`git/ignore` | `config.local` 仅本地，已 gitignore |
| `zsh` | `zsh/zshrc`、`zsh/zshenv` + 家目录 loader 文件 | loader 文件（`~/.zshenv`、`~/.zshrc`）source 仓库配置 |
| `zim` | `zsh/zimrc`（符号链接到 `~/.zimrc`） | 插件下载仅本地 |
| `fzf` | `zsh/fzf.zsh` | 经 `zsh/zshrc` 消费 |
| `starship` | `starship-tmux.toml` | 由 `zsh/prompt.zsh` 消费，仅在 `TMUX` 内且配置了 `zsh` 时生效 |
| `tmux` | `tmux/tmux.conf`、`tmux/scripts/` | XDG 路径 `~/.config/tmux/tmux.conf`；TPM 插件下载到 `~/.tmux/plugins/` |

仅软件包组件——无仓库管理配置：

- `lazygit`、`vim`、`yazi`、`mole`、`gh`：仅安装 formula 并验证可用性。认证、账户、扩展、偏好与状态仍由用户管理。
- `opencode`、`codex`、`claude-code`、`pi`：AI 编码代理 CLI，仅安装软件包并验证可用性。`opencode` 组件使用 `anomalyco/tap` 获取最新发布。认证、账户、偏好与运行时状态仍由用户管理；其配置目录（`opencode/`、`codex/`、`claude/`、`pi/`）已 gitignore。
- `ccswitch`：仅 tap + cask + 可用性验证。不管理 CCSwitch 偏好、账户、Provider 或应用状态。

## Windows bootstrap 组件

`windows-bootstrap/` 由 manifest 驱动，与上方 16 个 macOS 组件相互独立。软件包分组位于 `windows-bootstrap/packages/`：

| 分组 | 文件 | 内容 |
| --- | --- | --- |
| Base | `base.json` | Git、lazygit、PowerShell 7、Windows Terminal |
| Core | `core.json` | WSL 2 + Ubuntu LTS、JetBrains Mono Nerd Font、Mint RIME、Mint 默认输入法、PowerShell profile |
| Fonts | `fonts.json` | 固定版本 JetBrains Mono Nerd Font（URL、SHA-256、file pattern） |
| Optional | `optional.json` | 14 个 WinGet/Microsoft Store 项（Obsidian、Typora、Thunderbird、Telegram、Steam、CC-Switch、Clash Verge Rev、Zen Browser、Raycast、百度网盘、夸克网盘、Geek Uninstaller、欧路词典、Visual Studio Code）与固定直链的 dwall |

每个 WinGet 项必须声明明确的 package ID 与静默参数。没有可靠静默安装或验证方式的项保持 `manual_required`；绝不模拟 GUI 操作。逐项参考：[Windows bootstrap 软件清单](windows-bootstrap-packages.zh-CN.md)。

## 备注

- `starship` 配置仅在配置了 `zsh` 组件时生效（`zsh/prompt.zsh` 设置 `STARSHIP_CONFIG`）。
- 旧 loader（`~/.gitconfig`、`~/.tmux.conf`）仅在内容完全匹配旧安装器模板时移除；未知文件保留并发出警告。
- 已移除组件不会被安装或配置。已有软件包和应用绝不会自动卸载。
