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
- On macOS, `codex` and `claude-code` are installed via Homebrew casks, and `opencode` via Homebrew formula.
- On Linux, `@openai/codex`, `@anthropic-ai/claude-code`, and `opencode-ai` are installed via `npm -g`, and the installer adds the `node` formula as their dependency.
- Existing files are backed up to `~/.config/.backup/<timestamp>/`.
- Private state is not overwritten.
- The installer does not automatically change your default shell to `zsh`.
- If your login shell is not `zsh`, the installer prints the manual `chsh` command after install.

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
