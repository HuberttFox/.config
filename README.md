# dotfiles bootstrap

**English** | [简体中文](README.zh-CN.md)

This repository is intended to live at `~/.config`. Its installer bootstraps selected packages and repository-managed configuration on macOS and Linux.

## Prerequisites

- Run the installer as a normal, non-root user.
- Network access is required for Homebrew and components that download external resources.
- Keep the repository at `~/.config`. Another location only triggers a warning, but generated loaders reference `~/.config` and therefore rely on this path.

## Usage

```bash
# Install every component supported on this platform
./install.sh

# Equivalent explicit form
./install.sh --all

# Detect current state and preview actions without applying them
./install.sh --dry-run

# Select or exclude components
./install.sh --only zsh,tmux,fzf
./install.sh --skip finicky,kitty
```

| Option | Behavior |
|---|---|
| no option / `--all` | Select every registered component, then skip unsupported platforms |
| `--only a,b` | Select only the comma-separated components |
| `--skip a,b` | Remove components from the current selection |
| `--dry-run` | Inspect current state and print intended actions without installing packages or replacing managed destinations |
| `--force` | Force supported reinstall paths; currently mainly affects Kitty on Linux |

## What the installer does

1. Detects macOS or Linux and refuses to run as root.
2. Resolves component selection; no `--only` means all registered components.
3. Warns and skips components unsupported on the current platform.
4. Collects and deduplicates Homebrew taps, formulae, and casks.
5. Installs Homebrew when missing, activates its environment, then installs missing packages.
6. Runs every selected component's `apply` action.
7. Runs every selected component's `verify` action and stops on verification failure.
8. If `zsh` is selected, registers its executable in `/etc/shells` when needed and attempts to change the login shell.
9. Persists `brew shellenv` in `~/.zprofile` and the profile for the detected login shell.
10. After an interactive run started outside Zsh, replaces the current process with a login Zsh session.

## Components

### Configuration and additional setup

| Component | Platforms | Installer behavior |
|---|---|---|
| `git` | macOS, Linux | Installs Git and writes `~/.gitconfig` to include `git/config.shared` and optional local `git/config.local` |
| `zsh` | macOS, Linux | Installs Zsh and writes `~/.zshenv` and `~/.zshrc` loaders for repository configuration |
| `zim` | macOS, Linux | Links `~/.zimrc`, downloads `zimfw.zsh`, and generates `~/.zim/init.zsh` |
| `fzf` | macOS, Linux | Installs FZF and links `~/.fzf.zsh` to the repository loader |
| `tmux` | macOS, Linux | Installs tmux, clones TPM, writes the `~/.tmux.conf` loader, installs plugins, and verifies config in an isolated tmux server |
| `kitty` | macOS, Linux | Uses a Homebrew cask on macOS; on Linux runs Kitty's official installer and links `kitty` and `kitten` into `~/.local/bin` |
| `finicky` | macOS | Installs the app and links `finicky/finicky.dia.js` to `~/.finicky.js` |
| `serena` | macOS, Linux | Installs `serena-agent` through `uv tool` when absent and runs `serena init` when needed |

### Package-oriented components

| Components | Platforms | Installer behavior |
|---|---|---|
| `starship`, `tldr`, `fastfetch`, `lazygit`, `vim`, `yazi`, `rtk`, `beads`, `uv` | macOS, Linux | Install through Homebrew and verify command availability |
| `mole` | macOS | Installs through Homebrew and verifies the command |
| `ccswitch` | macOS | Adds its Homebrew tap, installs the cask, and verifies the app or `cc-switch` command |

`rtk` uses the `rtk-ai/tap` tap. `ccswitch` uses `farion1231/ccswitch`. Platform-incompatible components are skipped with a warning.

## Important details

### Existing paths and backups

- Before replacing a conflicting managed path, the installer copies it to `~/.config/.backup/<timestamp>/`.
- After backup, the conflicting destination is removed recursively and replaced. This also applies when the destination is a directory.
- Correct symlinks and managed files whose contents already match are left unchanged.
- Backups are local and ignored by Git; they are not an off-machine backup.

### Network and privileges

- Homebrew may be downloaded and installed automatically.
- Zim, TPM, Kitty on Linux, and Serena may contact external services during setup.
- Selecting `zsh` may run `chsh`.
- If the selected Zsh path is absent from `/etc/shells`, an interactive run may invoke `sudo` to register it. Noninteractive runs skip this step with a warning.

### Shell changes

- Homebrew environment initialization is appended to `~/.zprofile` and to the profile associated with the detected login shell.
- After a successful interactive run started outside Zsh, the installer executes `zsh -l`. Because it uses `exec`, control does not return to the original shell process.

### Dry-run and scope

- `--dry-run` still detects the platform, shell, commands, packages, and existing files, so output varies with machine state.
- It does not install packages or replace managed destinations. Verification reports checks that would happen after installation when an expected artifact does not exist yet.
- Ignored application configuration, credentials, extensions, sessions, logs, and other machine-specific runtime state are outside installer scope and remain untouched. See `.gitignore` for the authoritative list.

## Verify before applying

```bash
# Show accepted flags
./install.sh --help

# Preview the complete platform-supported selection
./install.sh --all --dry-run

# Preview a focused configuration run
./install.sh --only zsh,tmux,fzf --dry-run

# Preview all components except selected entries
./install.sh --all --skip finicky,kitty --dry-run
```

Review the dry-run output, especially backup, shell-switch, package-install, and network actions, before running without `--dry-run`.
