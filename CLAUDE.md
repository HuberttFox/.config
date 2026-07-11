# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository purpose

This is a personal dotfiles and machine bootstrap repository intended to live at `~/.config`. It manages shell, terminal, editor, tmux, browser routing, and installer configuration for macOS and Linux.

## Common commands

```bash
# Preview full bootstrap without modifying files
./install.sh --all --dry-run

# Apply full bootstrap
./install.sh --all

# Preview one or more components
./install.sh --only zsh --dry-run
./install.sh --only zsh,tmux,fzf --dry-run

# Skip components from otherwise full selection
./install.sh --all --skip finicky,iterm2 --dry-run

# Lint one shell script
shellcheck scripts/components/zsh.sh

# Lint all shell scripts
find . -type f -name "*.sh" -exec shellcheck {} +

# Syntax-check all shell scripts when shellcheck is unavailable
find . -type f -name "*.sh" -exec bash -n {} +
```

There is no traditional build or test suite. Installer changes should be validated with `--dry-run`, preferably scoped to affected components first.

## Architecture

`install.sh` is the bootstrap orchestrator. It detects platform, parses component selection, filters unsupported components, installs Homebrew packages, runs component `apply`, then runs component `verify`. The supported component list is in `ALL_COMPONENTS` inside `install.sh`.

Shared installer behavior lives in `scripts/lib/`:

- `common.sh` provides platform detection, logging, failure handling, command resolution, dry-run command execution, backups, safe symlink creation, managed file writes, shell switching helpers, and verification helpers.
- `brew.sh` locates or installs Homebrew, activates shellenv, manages taps/formulae/casks, and avoids reinstalling already-present Homebrew commands.

Each managed tool is represented by a component script in `scripts/components/<name>.sh`. Components may install packages, synchronize config only, or both. Their subcommand interface is:

- `platforms`: print supported platforms (`darwin`, `linux`, or `all`)
- `formulae`: print Homebrew formulae to install
- `taps`: optionally print Homebrew taps
- `casks`: print macOS Homebrew casks
- `apply`: link or write repo-managed config
- `verify`: confirm command/config availability

Package collection happens before any component `apply`, so component scripts should expose package needs through `formulae`, `taps`, and `casks` rather than installing packages directly.

## File management conventions

Use helpers from `scripts/lib/common.sh` for home-directory changes:

- `write_managed_file "$HOME/.toolrc"` backs up existing files under `.backup/<timestamp>/` before replacing them.
- `ensure_symlink <target> <link>` backs up conflicting paths before creating symlinks.
- `require_repo_file <relative-path>` validates repo-managed inputs before applying a component.
- `ensure_command_available <name>` is the common command verification path.

Respect `DRY_RUN=1` in component logic. In dry-run mode, avoid physical file checks that would fail before creation; log what would be verified instead.

## Component patterns

- Shell config (`zsh`, `zim`, `fzf`, `starship`) writes small loader files in `$HOME` that source repo-managed config under `~/.config`.
- App config components (`finicky`, terminal/editor tools) generally symlink repo files into tool-specific locations.
- `tmux` installs TPM under `~/.tmux/plugins/tpm`, writes `~/.tmux.conf` to source `~/.config/tmux/tmux.conf`, installs TPM plugins, then verifies config by sourcing it in an isolated tmux server.
- `rtk` is installed from Homebrew tap `rtk-ai/tap`.

## Important configs and state boundaries

Tracked config includes terminal configs, tmux config/scripts, zsh config, Finicky configs, and Raycast helper scripts.

The `codex/`, `opencode/`, `cursor/`, `orbstack/`, and `vscode/` directories are entirely local and ignored. Private or machine-specific state is also ignored, including local Git config, zsh local env, Claude local state, Fish/uv/Serena state, Raycast credentials/extensions, logs, and `.backup/`.

## Existing agent guidance

`AGENTS.md` contains stricter repository guidance. Preserve its important constraints when editing installer code:

- Bash scripts use `#!/usr/bin/env bash` and `set -euo pipefail`.
- Quote variables, use `local` inside functions, and prefer `printf` over `echo`.
- Keep new tool bootstrap logic in `scripts/components/<name>.sh`; do not bloat `install.sh`.
- Installer behavior must remain idempotent and safe to run repeatedly.
- Use paths derived from `ROOT_DIR` or `CONFIG_REPO` rather than hard-coded repo paths.
