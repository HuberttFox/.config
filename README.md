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
- `zim` is installed via the official installer script, then `~/.zimrc` is linked back to the repo-managed config.
- `tmux` installs TPM (`~/.tmux/plugins/tpm`) before loading the repo-managed tmux config.
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

Runtime state, auth files, logs, extensions, sessions, VM state, and other machine-specific data for these tools should stay out of Git.
