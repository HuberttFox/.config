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

# 不切换登录 Shell，也不启动新 Zsh
./install.sh --no-shell-switch
```

安装器会：

1. 拒绝非 macOS 和 root 执行。
2. 收集 Homebrew tap、formula 和 cask。
3. 安装缺失软件包。
4. 应用所选配置。
5. 验证每个所选组件。
6. 将安装器管理的文件变更记录到事务。
7. 可选注册 Zsh、运行 `chsh`、持久化 `brew shellenv` 并启动登录 Zsh。

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
- 未使用 `--no-shell-switch` 时，选择 Zsh 可能调用 `sudo`、修改 `/etc/shells`、运行 `chsh`，并以 `zsh -l` 替换当前 Shell 进程。
- Homebrew 环境配置会以事务方式写入登录 profile。
- 被忽略的本地应用配置、凭据、会话、日志和运行状态不属于安装器作用范围。
- 旧 Finicky 文件/应用以及从组件列表移除的软件包不会自动删除。
