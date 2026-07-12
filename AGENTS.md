# Agent Guidelines for dotfiles repository

This repository is a macOS-only bootstrap system intended to live at `~/.config`.

## Validation

There is no traditional build. Installer changes must pass:

```bash
./tests/integration.sh
find . -type f -name "*.sh" -exec bash -n {} +
find . -type f -name "*.sh" -exec shellcheck {} +  # when available
```

The integration suite uses temporary `HOME` and installer state with command stubs. Tests must never invoke real Homebrew, network downloads, `sudo`, `chsh`, or application installers.

## Bash style

- Start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Quote variable expansions.
- Use `local` inside functions.
- Prefer `printf` over `echo`.
- Source shared libraries from paths derived from `ROOT_DIR` or `CONFIG_REPO`.
- Use `die` for fatal errors.

## Component architecture

New retained tools belong in `scripts/components/<name>.sh`. Components implement:

1. `formulae`
2. optional `taps`
3. `casks`
4. `apply`
5. `verify`

Do not add platform subcommands or Linux branches. Package needs must be declared before `apply`, not installed ad hoc inside components unless the tool cannot be managed through Homebrew and the behavior is explicitly tested.

## File safety and rollback

Every installer-owned mutation of user files, symlinks, or profile lines must use transaction-aware helpers from `scripts/lib/common.sh` and `scripts/lib/transaction.sh`.

- Journal before mutation.
- Preserve the original pre-run state once per destination.
- Replace files atomically.
- Do not recursively remove unknown user paths.
- Preserve and warn on unknown legacy loader content.
- Rollback is conflict-safe and file-level only; it does not cover packages, `/etc/shells`, `chsh`, third-party downloads, or application state.

## Secrets

- Never put secret values in tracked files.
- `.env.example` contains empty placeholders only.
- `.env` and generated `raycast/ai/providers.yaml` remain ignored.
- Environment loaders must parse assignments, not evaluate arbitrary shell code.
- Secret renderer tests use dummy values and assert no output leakage plus `0600` permissions.

## Scope

Ignored application configuration and runtime state are local-only. Keep repository configuration limited to files consumed by retained components or native macOS application paths.
