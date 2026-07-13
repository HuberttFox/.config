# dotfiles bootstrap

**English** | [简体中文](README.zh-CN.md)

macOS-only bootstrap repository intended to live at `~/.config`.

## Managed components

| Group | Components | Installer scope |
| --- | --- | --- |
| Shell | `git`, `zsh`, `zim`, `fzf`, `starship`, `tmux` | Packages plus repository-owned configuration |
| Development CLI | `lazygit`, `vim`, `yazi` | Packages plus repository-owned configuration where applicable |
| Application | `ccswitch` | Homebrew tap/cask installation and availability verification only |

`ccswitch` installs tap `farion1231/ccswitch` and cask `cc-switch`. It does not manage CCSwitch preferences, accounts, providers, or application state.

Removed components are neither installed nor configured. Existing applications and packages are never uninstalled automatically.

## Ignored and local-only paths

`.gitignore` excludes machine-specific state outside installer ownership:

- **Secrets and local overrides:** `.env`, `git/config.local`, `zsh/env.local.zsh`, generated `raycast/ai/providers.yaml`.
- **Local application and editor configuration:** `claude/`, `codex/`, `cursor/`, `opencode/`, `vscode/`, `fish/`, `alacritty/`, `iterm2/`, `nvim/`, `finicky/`, `mole/`, `rtk/`, `uv/`, and similar application directories.
- **Runtime, caches, and logs:** `.zcompdump*`, `*.log`, `*.tmp`, Raycast extensions and `node_modules`, `.serena/`, `.backup/`.

Ignore rules apply to untracked files. The installer does not claim, configure, or roll back ignored local state.

## Install

```bash
# All retained components
./install.sh

# Selected components
./install.sh --only zsh,tmux,fzf

# Exclude components
./install.sh --skip tmux,yazi

# Configure Zsh and Zim from another shell without changing login shell
./install.sh --configure-zsh --only zsh,zim

# Configure Zsh, then explicitly change login shell to macOS /bin/zsh
./install.sh --switch-shell --only zsh

# Automation-safe: never prompt or change login shell
./install.sh --no-shell-switch
```

### Component lifecycle

1. Reject non-macOS and root execution.
2. Resolve `--only` / `--skip` into retained components.
3. Collect and deduplicate Homebrew taps, formulae, and casks.
4. Install missing Homebrew packages.
5. Apply selected component configuration.
6. Verify each selected component.
7. Record installer-owned file and symlink changes in a transaction.
8. Persist Homebrew shell environment for non-empty component runs.

Homebrew installs third-party formulae, taps, and casks. The installer uses only macOS-provided `/bin/zsh`; it never installs or selects Homebrew Zsh. It does not use apt, dnf, pacman, or other Linux package managers. If Homebrew is required but absent, its official installer is used.

### Zsh policy

`/bin/zsh` is required whenever `zsh` or `zim` is selected.

| Situation | Behavior |
| --- | --- |
| Current shell is Zsh | Apply selected Zsh/Zim configuration normally. |
| Current shell is not Zsh and `/bin/zsh` is absent | Stop before package installation or transaction with: `安装器仅允许 macos 系统的终端 zsh shell 情况下运行。` |
| Current shell is not Zsh with an interactive terminal | Ask whether to set login shell to `/bin/zsh` through `chsh`. Accepting applies configuration, then attempts the login-shell change. Declining skips Zsh/Zim and continues other components. |
| Noninteractive non-Zsh run | Skip Zsh/Zim; use `--configure-zsh` or `--switch-shell` for deterministic behavior. |
| `--configure-zsh` | Apply Zsh/Zim configuration without `chsh` or prompt. |
| `--switch-shell` | Apply Zsh configuration, then attempt `chsh -s /bin/zsh` after apply/verify. |
| `--no-shell-switch` | Suppress the prompt and any `chsh` path; non-Zsh runs skip Zsh/Zim unless `--configure-zsh` is given. |

The installer never edits `/etc/shells` and never replaces the current shell process. After a successful login-shell change, open a new terminal or run `exec /bin/zsh -l` manually.

Git and tmux use native XDG paths: `~/.config/git/config` and `~/.config/tmux/tmux.conf`. Legacy `~/.gitconfig` and `~/.tmux.conf` loaders are removed only if they exactly match old installer-generated content; unknown files remain untouched with a warning.

## Secrets

Tracked `.env.example` declares variable names without values:

```bash
cp .env.example .env
chmod 600 .env
```

Fill local values:

```dotenv
CONTEXT7_API_KEY=
RAYCAST_MODELSCOPE_API_KEY=
RAYCAST_PERPLEXITY_API_KEY=
```

Zsh loads simple `NAME=VALUE` assignments from `.env`; it does not evaluate arbitrary shell. Move assignments from legacy `zsh/env.local.zsh` manually.

Raycast does not interpolate `.env`. Generate its ignored provider file explicitly:

```bash
./scripts/render-raycast-providers
```

The renderer validates values, writes atomically with mode `0600`, and never prints secrets.

## Safe validation

`--dry-run` is intentionally unsupported because it skips operations most likely to fail. Use sandbox integration tests:

```bash
./tests/integration.sh
```

Tests run real `apply` and `verify` paths under temporary `HOME` and state directories with stubbed Homebrew, network, tmux, `sudo`, and `chsh`. Temporary data is removed afterward.

## File rollback

Every install receives a run ID:

```bash
./install.sh --rollback latest
./install.sh --rollback <run-id>
./install.sh --rollback all
./install.sh --rollback-force <latest|run-id|all>
```

Normal rollback restores replaced paths and removes paths created by the selected run, newest changes first. If a managed path changed later, rollback preserves it and stops. Forced rollback saves the conflicting current version under that run’s `rollback-conflicts/` directory before restoration.

Rollback covers only files and symlinks changed through transaction helpers. It does **not** reverse Homebrew packages/taps/casks, `chsh`, `/etc/shells`, Zim or TPM downloads, application preferences, or other external state. Transaction data lives under `${XDG_STATE_HOME:-~/.local/state}/dotfiles-installer`.
