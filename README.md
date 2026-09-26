# dotfiles bootstrap

**English** | [简体中文](README.zh-CN.md)

macOS bootstrap repository intended to live at `~/.config`. `install.sh` manages Homebrew packages plus repository-owned configuration for shell, terminal, and development CLI tools. A separate Windows RIME feature lives under [`windows/`](windows/) and never runs through `install.sh`. See [docs](docs/) for details.

## Quickstart

```bash
# Install all retained components
./install.sh

# Selected components
./install.sh --only zsh,tmux,fzf

# Exclude components
./install.sh --skip tmux,yazi

# AI coding agents only
./install.sh --only opencode,codex,claude-code,pi

# Automation-safe: never prompt or change login shell
./install.sh --no-shell-switch

# Roll back the latest install
./install.sh --rollback latest
```

Installer runs `install packages → apply configuration → verify`, journaling every file and symlink change in a transaction. See [docs/architecture.md](docs/architecture.md) for the full pipeline and rollback semantics.

## Windows RIME

Windows 11 x64 users run the separate PowerShell 7 x64 RIME entrypoint:

```powershell
pwsh.exe -NoProfile -File .\windows\install.ps1
```

From Windows Git Bash/MSYS2/Cygwin, [`bootstrap.sh`](bootstrap.sh) dispatches to that entrypoint. It keeps macOS behavior by delegating to `install.sh` and rejects Linux/WSL. See the [Windows RIME guide](windows/README.md); its portable tests do not certify Windows-native Registry, ACL, Junction, Weasel, process-isolation, reparse-race, or Raycast behavior.

## Components

| Group | Components |
| --- | --- |
| Shell | `git`, `zsh`, `zim`, `fzf`, `starship`, `tmux` |
| Development CLI | `lazygit`, `vim`, `yazi`, `mole`, `gh` |
| AI coding agents | `opencode`, `codex`, `claude-code`, `pi` |
| Application | `ccswitch` |

Full per-component reference (formulae, taps, casks, apply/verify behavior): [docs/components.md](docs/components.md).

## Documentation

- [docs/](docs/) — index
- [Architecture](docs/architecture.md) — installer pipeline, component model, transactions, Zsh policy
- [Components](docs/components.md) — per-component package and config reference
- [Development](docs/development.md) — setup, validation, bash style, component authoring
- [Troubleshooting](docs/troubleshooting.md) — common failures and fixes
- [Secrets](docs/secrets.md) — `.env` contract, renderer, security rules
- [Windows RIME](windows/README.md) — separate Windows 11/PowerShell 7 x64 profile deployment and native acceptance boundary

## License

MIT

## Contacts

- GitHub: [HuberttFox/.config](https://github.com/HuberttFox/.config)
