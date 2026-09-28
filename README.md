# dotfiles bootstrap

**English** | [简体中文](README.zh-CN.md)

macOS bootstrap repository intended to live at `~/.config`. `install.sh` manages Homebrew packages plus repository-owned configuration for shell, terminal, and development CLI tools. Separate Windows features live under [`windows-bootstrap/`](windows-bootstrap/) (unattended Windows 11 bootstrap) and [`windows/`](windows/) (RIME profile deployment); neither runs through `install.sh`. See [docs](docs/) for details.

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

## Windows

Windows 11 x64 has two separate entrypoints, neither routed through `install.sh`:

- [`windows-bootstrap/install.ps1`](windows-bootstrap/) — unattended full bootstrap: preflight, WinGet packages, WSL 2 + Ubuntu LTS, pinned JetBrains Mono Nerd Font, managed PowerShell profiles, and the RIME step, with `Run`/`Resume`/`Verify`/`Report`/`CleanupFailed`/`DryRun`. Supports Windows PowerShell 5.1 and PowerShell 7. A `-ExecutionPolicy Bypass` launcher is provided as [`install.cmd`](windows-bootstrap/install.cmd).

```powershell
pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1
```

Or use [`windows-bootstrap/install.cmd`](windows-bootstrap/install.cmd), which starts the same script with `-ExecutionPolicy Bypass` and needs no policy change. Run it from an elevated terminal for install/resume/cleanup.

- [`windows/install.ps1`](windows/) — PowerShell 7 x64 RIME profile deployment: three isolated profiles, fixed `RimeConfig` Junction selector, and Raycast wrappers.

```powershell
pwsh.exe -NoProfile -File .\windows\install.ps1
```

From Windows Git Bash/MSYS2/Cygwin, [`bootstrap.sh`](bootstrap.sh) forwards to the full Windows bootstrap (`windows-bootstrap/install.ps1`, PowerShell 7 or Windows PowerShell 5.1), delegates to `install.sh` on macOS, and rejects Linux/WSL. The RIME-only entry stays available as `windows/install.ps1`.

See the [Windows bootstrap guide](windows-bootstrap/README.md), the [bootstrap package reference](docs/windows-bootstrap-packages.md), the [Windows RIME guide](windows/README.md), and the [native acceptance evidence](docs/handoff-windows-rime-native-acceptance-evidence.md). Portable tests do not certify Windows-native Registry, ACL, Junction, Weasel, process-isolation, reparse-race, or Raycast behavior.

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
- [Windows bootstrap](windows-bootstrap/README.md) — unattended Windows 11 entry, lifecycle state machine, and recovery semantics
- [Windows RIME](windows/README.md) — separate Windows 11/PowerShell 7 x64 profile deployment and native acceptance boundary
- [Native acceptance evidence](docs/handoff-windows-rime-native-acceptance-evidence.md) — what passed, is blocked, or is unverified on the disposable Windows 11 guest

## License

MIT

## Contacts

- GitHub: [HuberttFox/.config](https://github.com/HuberttFox/.config)
