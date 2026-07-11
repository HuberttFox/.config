# dotfiles 引导配置

[English](README.md) | **简体中文**

本仓库应放置在 `~/.config`。安装器用于在 macOS 和 Linux 上引导安装所选软件包及仓库管理的配置。

## 前置条件

- 使用普通非 root 用户运行安装器。
- Homebrew 及需要下载外部资源的组件需要网络连接。
- 请将仓库放在 `~/.config`。其他位置只会触发警告，但生成的 loader 会引用 `~/.config`，因此实际依赖此路径。

## 使用方法

```bash
# 安装当前平台支持的全部组件
./install.sh

# 等价的显式写法
./install.sh --all

# 检测当前状态并预览操作，但不实际应用
./install.sh --dry-run

# 选择或排除组件
./install.sh --only zsh,tmux,fzf
./install.sh --skip finicky,kitty
```

| 选项 | 行为 |
|---|---|
| 不传选项 / `--all` | 选择所有已注册组件，然后跳过当前平台不支持的组件 |
| `--only a,b` | 只选择逗号分隔的组件 |
| `--skip a,b` | 从当前选择中排除组件 |
| `--dry-run` | 检查当前状态并打印计划操作，不安装软件包，也不替换受管理的目标路径 |
| `--force` | 强制执行支持的重装流程；目前主要影响 Linux 上的 Kitty |

## 安装器执行流程

1. 检测 macOS 或 Linux，并拒绝以 root 身份运行。
2. 解析组件选择；未使用 `--only` 时选择所有已注册组件。
3. 对当前平台不支持的组件发出警告并跳过。
4. 收集 Homebrew tap、formula 和 cask，并进行去重。
5. Homebrew 不存在时先安装并激活环境，然后安装缺失的软件包。
6. 执行所有已选组件的 `apply` 操作。
7. 执行所有已选组件的 `verify` 操作；验证失败时停止。
8. 如果选择了 `zsh`，在需要时将其可执行文件注册到 `/etc/shells`，并尝试切换登录 Shell。
9. 将 `brew shellenv` 持久化到 `~/.zprofile` 以及与检测到的登录 Shell 对应的 profile。
10. 如果在 Zsh 之外的交互式 Shell 中启动，完成后会用登录 Zsh 会话替换当前进程。

## 组件

### 配置及额外设置

| 组件 | 平台 | 安装器行为 |
|---|---|---|
| `git` | macOS、Linux | 安装 Git，并写入 `~/.gitconfig`，使其包含 `git/config.shared` 和可选的本地 `git/config.local` |
| `zsh` | macOS、Linux | 安装 Zsh，并写入 `~/.zshenv` 和 `~/.zshrc` loader 以加载仓库配置 |
| `zim` | macOS、Linux | 链接 `~/.zimrc`，下载 `zimfw.zsh`，并生成 `~/.zim/init.zsh` |
| `fzf` | macOS、Linux | 安装 FZF，并将 `~/.fzf.zsh` 链接到仓库 loader |
| `tmux` | macOS、Linux | 安装 tmux、克隆 TPM、写入 `~/.tmux.conf` loader、安装插件，并在隔离的 tmux server 中验证配置 |
| `kitty` | macOS、Linux | macOS 使用 Homebrew cask；Linux 运行 Kitty 官方安装器，并将 `kitty` 和 `kitten` 链接到 `~/.local/bin` |
| `finicky` | macOS | 安装应用，并将 `finicky/finicky.dia.js` 链接到 `~/.finicky.js` |
| `serena` | macOS、Linux | 缺失时通过 `uv tool` 安装 `serena-agent`，并在需要时运行 `serena init` |

### 以软件包安装为主的组件

| 组件 | 平台 | 安装器行为 |
|---|---|---|
| `starship`、`tldr`、`fastfetch`、`lazygit`、`vim`、`yazi`、`rtk`、`beads`、`uv` | macOS、Linux | 通过 Homebrew 安装并验证命令是否可用 |
| `mole` | macOS | 通过 Homebrew 安装并验证命令 |
| `ccswitch` | macOS | 添加对应 Homebrew tap、安装 cask，并验证应用或 `cc-switch` 命令 |

`rtk` 使用 `rtk-ai/tap`。`ccswitch` 使用 `farion1231/ccswitch`。不兼容当前平台的组件会在警告后跳过。

## 重要细节

### 已有路径与备份

- 替换冲突的受管理路径前，安装器会将其复制到 `~/.config/.backup/<timestamp>/`。
- 备份完成后，冲突目标会被递归删除并替换；目标是目录时同样如此。
- 已正确指向目标的符号链接，以及内容已一致的受管理文件，不会被修改。
- 备份只保存在本机并由 Git 忽略，不能替代异机备份。

### 网络与权限

- Homebrew 可能被自动下载并安装。
- Zim、TPM、Linux 上的 Kitty 以及 Serena 在设置过程中可能访问外部服务。
- 选择 `zsh` 时可能执行 `chsh`。
- 如果所选 Zsh 路径不在 `/etc/shells` 中，交互式运行可能通过 `sudo` 注册该路径；非交互式运行会跳过并发出警告。

### Shell 变更

- Homebrew 环境初始化会追加到 `~/.zprofile` 以及与检测到的登录 Shell 对应的 profile。
- 如果在 Zsh 之外的交互式 Shell 中启动，成功完成后安装器会执行 `zsh -l`。由于使用 `exec`，控制不会返回原 Shell 进程。

### Dry-run 与作用范围

- `--dry-run` 仍会检测平台、Shell、命令、软件包和已有文件，因此输出会随机器状态变化。
- 它不会安装软件包或替换受管理的目标路径。预期产物尚不存在时，验证阶段会说明安装后将执行的检查。
- 被忽略的应用配置、凭据、扩展、会话、日志及其他机器相关运行状态均不属于安装器作用范围，并会保持不变。完整列表以 `.gitignore` 为准。

## 应用前验证

```bash
# 查看支持的参数
./install.sh --help

# 预览当前平台支持的完整组件选择
./install.sh --all --dry-run

# 预览聚焦的配置流程
./install.sh --only zsh,tmux,fzf --dry-run

# 预览除指定组件外的全部组件
./install.sh --all --skip finicky,kitty --dry-run
```

正式运行前，请检查 dry-run 输出，尤其关注备份、Shell 切换、软件包安装和网络操作。
