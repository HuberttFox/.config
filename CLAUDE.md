# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Scope

macOS-only dotfiles bootstrap repository intended to live at `~/.config`.

## Commands

```bash
# Validate installer behavior safely
./tests/integration.sh

# Syntax-check shell files
find . -type f -name "*.sh" -exec bash -n {} +

# Lint when ShellCheck is installed
find . -type f -name "*.sh" -exec shellcheck {} +

# Install all or selected components
./install.sh --no-shell-switch
./install.sh --only zsh,tmux,fzf --no-shell-switch

# File rollback
./install.sh --rollback latest
```

## Architecture

`install.sh` rejects non-macOS, resolves retained components, installs Homebrew packages, starts a file transaction, applies components, verifies them, persists Homebrew environment, and optionally switches to Zsh.

Shared libraries:

- `scripts/lib/common.sh`: logging, command resolution, transaction-aware file/symlink/profile helpers, shell switching.
- `scripts/lib/brew.sh`: macOS Homebrew discovery, bootstrap, taps, formulae, casks, shellenv.
- `scripts/lib/transaction.sh`: run journal, backups, fingerprints, rollback and conflict handling.

Components implement `formulae`, optional `taps`, `casks`, `apply`, and `verify`. They do not implement platform dispatch; the repository is macOS-only.

## Installer rules

- Every installer-owned home-file mutation must use transaction-aware helpers. Do not write, append, copy, move, symlink, or recursively remove user paths directly.
- Rollback claims are file-level only. Never imply package, cask, `/etc/shells`, `chsh`, TPM/Zim, Serena, or application-state rollback.
- Installer changes require `tests/integration.sh`; `--dry-run` is intentionally unsupported.
- Tests must use temporary `HOME`/state directories and stubs. Never call real Homebrew, network, `sudo`, `chsh`, or application installers.
- Scripts use `#!/usr/bin/env bash`, `set -euo pipefail`, quoted variables, function-local variables, and `printf` rather than `echo`.
- Keep tool logic in `scripts/components/<name>.sh`; do not bloat `install.sh`.

## Secrets

- `.env.example` is tracked and must contain variable names with empty values only.
- `.env` and generated `raycast/ai/providers.yaml` remain ignored.
- Zsh loads simple assignments from `.env`; do not add arbitrary shell evaluation.
- Raycast template/renderer changes require integration tests with dummy keys, missing-value failure, no output leakage, and mode `0600`.

## Configuration boundaries

Git and tmux use native XDG paths under this repository. Zsh still needs small home-level loader files. Ignored local application configuration, credentials, sessions, extensions, logs, and runtime state are outside installer scope.
