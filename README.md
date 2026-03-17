# dotfiles bootstrap

This repository is intended to live at `~/.config`.

## Install

Run everything:

```bash
./install.sh --all
```

Preview without modifying files:

```bash
./install.sh --all --dry-run
```

Install a subset:

```bash
./install.sh --only zsh,tmux,fzf
```

## Notes

- Homebrew formulae are preferred.
- `zim` downloads `zimfw.zsh`, links `~/.zimrc` to the repo-managed config, and generates `~/.zim/init.zsh` without rewriting `~/.zshrc`.
- `tmux` installs TPM (`~/.tmux/plugins/tpm`) before loading the repo-managed tmux config.
- `vim`, `neovim`, `yazi`, and `neofetch` are installed via Homebrew formulae and only verified for command availability.
- `iterm2` and `alacritty` are installed on macOS via Homebrew casks.
- `kitty` is installed on macOS via Homebrew cask, and on Linux via kitty's official binary installer, then linked into `~/.local/bin`.
- `finicky` is installed on macOS via Homebrew cask and provides URL routing for the browser-mode workflow.
- On macOS, `codex` and `claude-code` are installed via Homebrew casks, and `opencode` via Homebrew formula.
- On Linux, `codex`, `claude-code`, and `opencode` are installed via Homebrew.
- Existing files are backed up to `~/.config/.backup/<timestamp>/`.
- Private state is not overwritten.
- If `zsh` is selected and your login shell is not `zsh`, the installer attempts `chsh -s <resolved-zsh-path>` automatically.
- If that `zsh` path is missing from `/etc/shells`, the installer tries to register it first and may prompt for your `sudo` password.
- After package installation and shell switching, the installer writes `brew shellenv` to the profile file that matches your current login shell.

## Sync-only configs

The following tools can keep shared config in this repo, but are not installed by `install.sh`:

- `raycast`
- `cursor`
- `orbstack`
- `vscode`

Current sync-only files in this repo:

- `codex/config.toml`
- `cursor/argv.json`
- `vscode/argv.json`
- `raycast/ai/providers.yaml`

## Finicky + Raycast (macOS only)

This setup uses Finicky as the URL router and Raycast Script Commands to toggle the active browser mode.

Configuration:

- Finicky configs live at `finicky/finicky.dia.js` and `finicky/finicky.atlas.js`.
- The active config is linked at `~/.finicky.js` by the installer or the mode script.
- Modes are controlled by swapping the `~/.finicky.js` symlink (values: `dia`, `atlas`).
- The helper script is `scripts/browser-mode` (macOS only) and restarts Finicky.
- Notifications are sent via `terminal-notifier` when available, otherwise via `osascript`.

Suggested Raycast Script Commands:

- Use `raycast/script-commands/browser-mode.sh` and pick from the browser list.

Runtime state, auth files, logs, extensions, sessions, VM state, and other machine-specific data for these tools should stay out of Git.
