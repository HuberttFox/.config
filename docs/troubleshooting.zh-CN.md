# 故障排查

[English](troubleshooting.md) | **简体中文**

常见失败、报错信息与修复。

## 安装器拒绝非 macOS / root

```
This installer supports macOS only.
This installer must be run as a non-root user.
```

请在 macOS 上以普通用户运行。安装器不支持 Linux，也不使用除 Homebrew 外的包管理器。

## Zsh 闸门中止运行

```
安装器仅允许 macos 系统的终端 zsh shell 情况下运行。
```

当前 Shell 非 Zsh 且选择了 `zsh` 或 `zim` 时，必须存在 `/bin/zsh`。修复：

- 从 Zsh 运行，或
- 传 `--configure-zsh` 只配置不切换，或
- 传 `--switch-shell` 配置后 `chsh -s /bin/zsh`（要求选中 `zsh` 组件）。

非 Zsh 运行时，`--no-shell-switch` 会完全跳过 Zsh/Zim。

## 切换 Shell 后登录 Shell 未变

```bash
$ zsh    # 新开终端，或：exec /bin/zsh -l
```

安装器绝不修改 `/etc/shells`，也绝不替换当前 Shell 进程。若 `chsh` 失败，手动执行：

```bash
chsh -s /bin/zsh
```

安装器仅在 `/bin/zsh` 已注册到 `/etc/shells` 且终端可交互时才切换。

## 回滚报告冲突

```
Rollback conflict: /path/to/file
```

某受管路径在安装后被修改。回滚会保留你的修改并停止。要强行恢复（当前版本备份到该次运行的 `rollback-conflicts/`）：

```bash
./install.sh --rollback-force latest
```

## `--dry-run` 失败

`--dry-run` 故意不支持。请用沙箱集成测试：

```bash
./tests/integration.sh
```

## 渲染器失败 / 缺少 Raycast 密钥

```
Missing required Raycast key in .env
Missing .env
```

复制 `.env.example` 为 `.env`，填入值并 `chmod 600 .env`，然后重跑 `./scripts/render-raycast-providers`。渲染器会校验值、以 `0600` 权限原子写入，且绝不打印密钥。

## 组件意外被跳过

日志显示 `Zsh configuration skipped` — 运行是非交互式的，或 `--no-shell-switch` 禁用了询问。需要确定性的 Zsh 配置时，使用 `--configure-zsh` 或 `--switch-shell`。

## 旧 loader 保留并警告

```
Preserving user-managed file: ~/.gitconfig
```

内容不匹配旧安装器模板的文件不会被改动。请自行检查并手动合并；安装器不覆盖未知的用户文件。
