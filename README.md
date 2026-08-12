# dotfiles bootstrap

**English** | [简体中文](README.zh-CN.md)

macOS-only bootstrap repository intended to live at `~/.config`. Installer manages Homebrew packages plus repository-owned configuration for shell, terminal, and development CLI tools. See [docs](docs/) for details.

## Quickstart

```bash
# Install all retained components
./install.sh

# Selected components
./install.sh --only zsh,tmux,fzf

# Exclude components
./install.sh --skip tmux,yazi

# Automation-safe: never prompt or change login shell
./install.sh --no-shell-switch

# Roll back the latest install
./install.sh --rollback latest
```

Installer runs `install packages → apply configuration → verify`, journaling every file and symlink change in a transaction. See [docs/architecture.md](docs/architecture.md) for the full pipeline and rollback semantics.

## Components

| Group | Components |
| --- | --- |
| Shell | `git`, `zsh`, `zim`, `fzf`, `starship`, `tmux` |
| Development CLI | `lazygit`, `vim`, `yazi`, `mole`, `gh` |
| Application | `ccswitch` |

Full per-component reference (formulae, taps, casks, apply/verify behavior): [docs/components.md](docs/components.md).

## Documentation

- [docs/](docs/) — index
- [Architecture](docs/architecture.md) — installer pipeline, component model, transactions, Zsh policy
- [Components](docs/components.md) — per-component package and config reference
- [Development](docs/development.md) — setup, validation, bash style, component authoring
- [Troubleshooting](docs/troubleshooting.md) — common failures and fixes
- [Secrets](docs/secrets.md) — `.env` contract, renderer, security rules

## License

MIT
