# dotfiles 引导配置

[English](README.md) | **简体中文**

仅支持 macOS 的引导配置仓库，应放置在 `~/.config`。

## 组件

安装器管理：

- Shell：`git`、`zsh`、`zim`、`fzf`、`starship`、`tmux`
- 开发 CLI：`lazygit`、`vim`、`yazi`

已移除的组件不再安装或配置，但不会卸载已有应用。

## 密钥

仓库跟踪的 `.env.example` 只定义变量名，不包含值：

```bash
cp .env.example .env
chmod 600 .env
```

在本地 `.env` 中填写：

```dotenv
CONTEXT7_API_KEY=
RAYCAST_MODELSCOPE_API_KEY=
RAYCAST_PERPLEXITY_API_KEY=
```

Zsh 会从 `.env` 加载简单的 `NAME=VALUE` 赋值。该文件由 Git 忽略，密钥不会提交。请手动把旧 `zsh/env.local.zsh` 中的赋值迁移到 `.env`；旧文件不再加载。

Raycast 本身不会插值 `.env`。请显式生成被忽略的 Provider 文件：

```bash
./scripts/render-raycast-providers
```

渲染器会验证必需值、原子写入、设置 `0600` 权限，并且不会打印密钥。

## 安装

```bash
# 全部保留组件
./install.sh

# 指定组件
./install.sh --only zsh,tmux,fzf

# 排除组件
./install.sh --skip tmux,yazi

# 当前 Shell 不是 Zsh 时，不配置 Zsh
./install.sh

# 从其他 Shell 显式初始化 Zsh 配置
./install.sh --configure-zsh --only zsh,zim

# 显式将 macOS 系统 Zsh 设为登录 Shell
./install.sh --switch-shell --only zsh

# 保持与禁用 Shell 切换的自动化脚本兼容
./install.sh --no-shell-switch
```

### 包管理器

Homebrew 负责安装第三方组件声明的 formula、tap 和 cask。安装器仅使用 macOS 自带的 `/bin/zsh`，不会安装或选择 Homebrew Zsh。安装器仅支持 macOS，不使用 apt、dnf、pacman 等 Linux 包管理器。缺少所需 Homebrew 时，安装器会通过其官方安装脚本安装 Homebrew。Zim/TPM 下载仍属独立外部设置。

### Zsh 策略

默认仅当当前 Shell 为 Zsh 时，才执行 Zsh 和 Zim 工作。从其他 Shell 运行时，使用 `--configure-zsh` 可显式初始化配置，但不会更改账户设置。`--switch-shell` 也会启用 Zsh 配置，并仅在确认 `/bin/zsh` 已注册至 `/etc/shells` 后，以交互方式运行 `chsh -s /bin/zsh`。普通安装不会修改 `/etc/shells`、更改登录 Shell 或替换当前 Shell 进程。

安装器会：

1. 拒绝非 macOS 和 root 执行。
2. 收集 Homebrew tap、formula 和 cask。
3. 安装缺失软件包。
4. 应用所选配置。
5. 验证每个所选组件。
6. 将安装器管理的文件变更记录到事务。
7. 使用 `--switch-shell` 时，可选将登录 Shell 改为 `/bin/zsh`；其他情况绝不更改或启动 Shell。

Git 和 tmux 使用原生 XDG 路径（`~/.config/git/config` 和 `~/.config/tmux/tmux.conf`）。只有内容完全匹配旧安装器模板时，才会移除旧 `~/.gitconfig` 和 `~/.tmux.conf` loader；未知文件会保留并发出警告。

## 安全验证

`--dry-run` 已删除，因为它会跳过最容易失败的真实操作。请使用沙箱集成测试：

```bash
tests/integration.sh
```

测试会在临时 `HOME` 和状态目录中运行真实 `apply` 与 `verify` 路径，并 stub Homebrew、网络、tmux、Serena、`sudo` 和 `chsh`。完成后删除临时数据。

## 文件回滚

每次安装都会生成 run ID。文件回滚命令：

```bash
./install.sh --rollback latest
./install.sh --rollback <run-id>
./install.sh --rollback all
./install.sh --rollback-force <latest|run-id|all>
```

普通回滚会按新到旧恢复被替换的路径，并删除对应 run 创建的路径。如果受管理路径在安装后被修改，回滚会停止并保留它。强制回滚会先把冲突版本保存到该 run 的 `rollback-conflicts/` 目录。

回滚只覆盖通过安装器事务 helper 修改的文件和符号链接。它**不会**撤销 Homebrew 软件包/tap/cask、`/etc/shells`、`chsh`、TPM 或 Zim 下载以及应用偏好。

事务数据保存在 `${XDG_STATE_HOME:-~/.local/state}/dotfiles-installer`。安装失败时，错误会打印 run ID 和准确的回滚命令。

## 重要细节

- 安装器管理的路径会在修改前写入 journal 并备份。
- 软件包安装和外部设置仍需要网络连接。
- `--switch-shell` 可能运行 `chsh`；它绝不修改 `/etc/shells` 或替换当前 Shell 进程。成功切换后请手动运行 `exec /bin/zsh -l`。
- Homebrew 环境配置会以事务方式写入登录 profile。
- 被忽略的本地应用配置、凭据、会话、日志和运行状态不属于安装器作用范围。
- 旧 Finicky 文件/应用以及从组件列表移除的软件包不会自动删除。
