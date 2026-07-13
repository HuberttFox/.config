# dotfiles 引导配置

[English](README.md) | **简体中文**

仅支持 macOS 的引导配置仓库，应放置在 `~/.config`。

## 受管理组件

| 分类 | 组件 | 安装器范围 |
| --- | --- | --- |
| Shell | `git`、`zsh`、`zim`、`fzf`、`starship`、`tmux` | 软件包与仓库自有配置 |
| 开发 CLI | `lazygit`、`vim`、`yazi`、`mole`、`gh` | 软件包，以及适用的仓库自有配置 |
| 应用 | `ccswitch` | 仅安装 Homebrew tap/cask 并验证可用性 |

`ccswitch` 会安装 tap `farion1231/ccswitch` 与 cask `cc-switch`。安装器不管理 CCSwitch 偏好、账户、Provider 或应用状态。`mole` 只安装并验证 Homebrew formula；其配置、日志与运行时状态仍仅保留在本机。`gh` 只安装并验证 GitHub CLI formula；认证、账户、hosts、偏好、扩展与配置文件仍由用户管理。

已移除组件不会被安装或配置；已有应用和软件包也不会自动卸载。

## 忽略和仅本地路径

`.gitignore` 排除不属于安装器管理范围的机器本地状态：

- **密钥与本地覆盖：** `.env`、`git/config.local`、`zsh/env.local.zsh`、生成的 `raycast/ai/providers.yaml`。
- **本地应用与编辑器配置：** `claude/`、`codex/`、`cursor/`、`opencode/`、`vscode/`、`fish/`、`alacritty/`、`iterm2/`、`nvim/`、`finicky/`、`mole/`、`rtk/`、`uv/` 及类似应用目录。
- **运行时、缓存与日志：** `.zcompdump*`、`*.log`、`*.tmp`、Raycast extensions 与 `node_modules`、`.serena/`、`.backup/`。

忽略规则只作用于未跟踪文件。安装器不会声明、配置或回滚这些被忽略的本地状态。

## 安装

```bash
# 全部保留组件
./install.sh

# 指定组件
./install.sh --only zsh,tmux,fzf

# 排除组件
./install.sh --skip tmux,yazi

# 仅安装 Mole
./install.sh --only mole

# 仅安装 GitHub CLI；请另行使用 gh auth login 认证
./install.sh --only gh

# 显示选择、软件包与阶段的安全诊断信息
./install.sh --debug --only mole

# 从其他 Shell 配置 Zsh/Zim，但不更改登录 Shell
./install.sh --configure-zsh --only zsh,zim

# 配置 Zsh 后，显式将登录 Shell 改为 macOS /bin/zsh
./install.sh --switch-shell --only zsh

# 自动化安全模式：绝不询问或更改登录 Shell
./install.sh --no-shell-switch
```

### 组件生命周期

1. 拒绝非 macOS 与 root 执行。
2. 根据 `--only` / `--skip` 解析保留组件。
3. 收集并去重 Homebrew tap、formula 与 cask。
4. 安装缺失的 Homebrew 软件包。
5. 应用所选组件配置。
6. 验证每个所选组件。
7. 将安装器自有的文件和符号链接变更记录到事务。
8. 对非空组件运行持久化 Homebrew shell 环境。

Homebrew 安装第三方 formula、tap 与 cask。安装器仅使用 macOS 自带的 `/bin/zsh`，绝不安装或选择 Homebrew Zsh。不使用 apt、dnf、pacman 或其他 Linux 包管理器。需要 Homebrew 但未检测到时，安装器会调用其官方安装脚本。

### Zsh 策略

选择 `zsh` 或 `zim` 时，必须存在 `/bin/zsh`。

| 情况 | 行为 |
| --- | --- |
| 当前 Shell 为 Zsh | 正常应用所选 Zsh/Zim 配置。 |
| 当前 Shell 非 Zsh，且 `/bin/zsh` 不存在 | 在软件包安装或事务开始前停止，并输出：`安装器仅允许 macos 系统的终端 zsh shell 情况下运行。` |
| 当前 Shell 非 Zsh，且终端可交互 | 询问是否通过 `chsh` 将登录 Shell 设为 `/bin/zsh`。接受后应用配置，再尝试更改登录 Shell；拒绝后跳过 Zsh/Zim，继续其他组件。 |
| 非交互式的非 Zsh 运行 | 跳过 Zsh/Zim；使用 `--configure-zsh` 或 `--switch-shell` 获得确定行为。 |
| `--configure-zsh` | 应用 Zsh/Zim 配置，不运行 `chsh`，不询问。 |
| `--switch-shell` | 应用 Zsh 配置，在 apply/verify 后尝试 `chsh -s /bin/zsh`。 |
| `--no-shell-switch` | 禁止询问和任何 `chsh` 路径；非 Zsh 运行会跳过 Zsh/Zim，除非给出 `--configure-zsh`。 |

安装器绝不修改 `/etc/shells`，也绝不替换当前 Shell 进程。成功更改登录 Shell 后，请新开终端或手动运行 `exec /bin/zsh -l`。确认提示会说明检测到的当前 Shell、持久化的 `/bin/zsh` `chsh` 变更以及拒绝后的结果；拒绝会跳过 Zsh/Zim，继续其他组件。

Git 与 tmux 使用原生 XDG 路径：`~/.config/git/config`、`~/.config/tmux/tmux.conf`。旧 `~/.gitconfig` 和 `~/.tmux.conf` loader 仅在内容完全匹配旧安装器模板时移除；未知文件会保留并发出警告。

### 运行输出与诊断

常规输出会报告安装计划、软件包/apply/verify 阶段、警告和事务 run ID。使用 `--debug` 查看额外的非敏感诊断：解析后的组件选择、tap/formula/cask 计划、组件脚本路径、Homebrew 路径、事务 ID，以及通过安装器 wrapper 执行的软件包命令。Debug 模式不会启用 shell tracing、打印环境变量或 `.env` 值，也不会替代沙箱集成测试。

## 密钥

受跟踪的 `.env.example` 只定义变量名：

```bash
cp .env.example .env
chmod 600 .env
```

在本地填写：

```dotenv
CONTEXT7_API_KEY=
RAYCAST_MODELSCOPE_API_KEY=
RAYCAST_PERPLEXITY_API_KEY=
```

Zsh 从 `.env` 加载简单的 `NAME=VALUE` 赋值；不会执行任意 shell。请手动从旧 `zsh/env.local.zsh` 迁移赋值。

Raycast 不会直接插值 `.env`，需显式生成被忽略的 Provider 文件：

```bash
./scripts/render-raycast-providers
```

渲染器会验证变量、原子写入并设为 `0600`，且绝不打印密钥。

## 安全验证

`--dry-run` 被刻意禁用，因为它会跳过最可能失败的操作。请使用沙箱集成测试：

```bash
./tests/integration.sh
```

测试会在临时 `HOME` 和状态目录运行真实 `apply`、`verify` 路径，并 stub Homebrew、网络、tmux、`sudo` 与 `chsh`。临时数据会在结束后删除。

## 文件回滚

每次安装均生成 run ID：

```bash
./install.sh --rollback latest
./install.sh --rollback <run-id>
./install.sh --rollback all
./install.sh --rollback-force <latest|run-id|all>
```

普通回滚按由新到旧顺序恢复替换路径，并删除该 run 创建的路径。若受管理路径之后被修改，回滚会保留它并停止。强制回滚会先将冲突当前版本保存到该 run 的 `rollback-conflicts/`，再恢复。

回滚只覆盖通过事务 helper 修改的文件和符号链接。它**不会**撤销 Homebrew 软件包/tap/cask、`chsh`、`/etc/shells`、Zim 或 TPM 下载、应用偏好或其他外部状态。事务数据位于 `${XDG_STATE_HOME:-~/.local/state}/dotfiles-installer`。
