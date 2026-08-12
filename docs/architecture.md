# Architecture

**English** | [简体中文](architecture.zh-CN.md)

This document describes the installer pipeline, component model, transaction system, Zsh policy, and repository scope.

## Installer pipeline

`install.sh` (with shared libraries under `scripts/lib/`) drives the whole run.

```mermaid
flowchart TD
    A[Start: ./install.sh] --> B{macOS + non-root?}
    B -- no --> BAD[Die]
    B -- yes --> C[Parse args: --only / --skip / shell flags]
    C --> D[Resolve retained components]
    D --> E{Zsh or Zim selected?}
    E -- yes --> F[Gate: current shell / /bin/zsh / flags]
    E -- no --> G
    F --> G[transaction_start]
    G --> H[install_packages: taps, formulae, casks]
    H --> I[apply_components]
    I --> J[verify_components]
    J --> K{Switch shell?}
    K -- yes --> L[chsh to /bin/zsh]
    K -- no --> M
    L --> M[Persist brew shellenv]
    M --> N[transaction completed]
```

Steps (mirrors [README lifecycle](../README.md)):

1. Reject non-macOS and root execution.
2. Resolve `--only` / `--skip` into retained components and gate Zsh components.
3. Start a file transaction that journals every installer-owned mutation.
4. Collect and deduplicate Homebrew taps, formulae, and casks.
5. Install missing Homebrew packages.
6. Apply selected component configuration; each file and symlink change is recorded in the running transaction.
7. Verify each selected component.
8. Persist Homebrew shell environment for non-empty component runs, then mark the transaction complete.

`--dry-run` is intentionally unsupported. Use `tests/integration.sh`.

## Component model

Components live in `scripts/components/<name>.sh` and expose subcommands consumed by `install.sh`.

```mermaid
flowchart LR
    INSTALL[install.sh] -->|taps| C[taps]
    INSTALL -->|formulae| C2[formulae]
    INSTALL -->|casks| C3[casks]
    INSTALL -->|apply| A[apply]
    INSTALL -->|verify| V[verify]
    A --> L1[scripts/lib/common.sh]
    A --> L2[scripts/lib/transaction.sh]
    V --> L1
```

Shared libraries:

- `scripts/lib/common.sh` — logging (`log`/`debug`/`warn`/`die`), command resolution, transaction-aware file/symlink/profile helpers (`ensure_symlink`, `write_managed_file`, `ensure_line_in_file`), shell detection and switching.
- `scripts/lib/brew.sh` — Homebrew discovery, bootstrap, taps, formulae, casks, shellenv activation and persistence.
- `scripts/lib/transaction.sh` — run journal, backups, fingerprints, rollback and conflict handling.

### Component contract

Each component implements a subset of `formulae`, `taps`, `casks`, `apply`, `verify`:

```bash
case "${1:-}" in
  formulae) printf 'tool\n' ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand" ;;
esac
```

Package needs must be declared before `apply`, not installed ad hoc inside components.

## Transaction and rollback

Every run gets a run ID; all mutations are journaled under `${XDG_STATE_HOME:-~/.local/state}/dotfiles-installer`.

```mermaid
flowchart LR
    P[transaction_prepare: backup pre-state] --> J[journal PREPARED]
    J --> W[write file / symlink]
    W --> A[transaction_applied: fingerprint]
    A --> RB{rollback?}
    RB -- no --> DONE[completed]
    RB -- yes --> CHK{current == expected?}
    CHK -- no --> CONFLICT{force?}
    CONFLICT -- no --> STOP[stop, preserve user state]
    CONFLICT -- yes --> BK[backup to rollback-conflicts/]
    BK --> RESTORE
    CHK -- yes --> RESTORE[restore backup or remove created path]
    RESTORE --> ROLLED[rolled_back]
```

- Normal rollback restores replaced paths and removes created paths, newest first.
- If a managed path changed since install, rollback preserves it and stops.
- Forced rollback (`--rollback-force`) saves the conflicting version under that run's `rollback-conflicts/` before restoring.
- Rollback covers only files and symlinks changed through transaction helpers. It does not reverse packages, taps, casks, `chsh`, `/etc/shells`, Zim/TPM downloads, or application state.

## Zsh policy

`/bin/zsh` is required whenever `zsh` or `zim` is selected. The installer uses only macOS-provided `/bin/zsh`; it never installs or selects Homebrew Zsh.

| Situation | Behavior |
| --- | --- |
| Current shell is Zsh | Apply Zsh/Zim configuration normally. |
| Current shell not Zsh, `/bin/zsh` absent | Stop before package install with: `安装器仅允许 macos 系统的终端 zsh shell 情况下运行。` |
| Current shell not Zsh, interactive | Ask to set login shell to `/bin/zsh` via `chsh`. Accept: apply then attempt change. Decline: skip Zsh/Zim, continue others. |
| Noninteractive non-Zsh run | Skip Zsh/Zim; use `--configure-zsh` or `--switch-shell` for deterministic behavior. |
| `--configure-zsh` | Apply Zsh/Zim configuration without `chsh` or prompt. |
| `--switch-shell` | Apply Zsh configuration, then attempt `chsh -s /bin/zsh` after apply/verify. Requires the `zsh` component. |
| `--no-shell-switch` | Suppress prompt and any `chsh` path; non-Zsh runs skip Zsh/Zim unless `--configure-zsh` given. |

The installer never edits `/etc/shells` and never replaces the current shell process. After a successful login-shell change, open a new terminal or run `exec /bin/zsh -l`.

## Scope and ignored paths

Repository configuration is limited to files consumed by retained components or native macOS paths.

- Git and tmux use native XDG paths: `~/.config/git/config`, `~/.config/tmux/tmux.conf`. Legacy `~/.gitconfig` and `~/.tmux.conf` loaders are removed only if they exactly match old installer-generated content; unknown files are preserved with a warning.
- Ignored local state (`.gitignore`): secrets and local overrides (`.env`, `git/config.local`, `zsh/env.local.zsh`), application/editor configs (`opencode/`, `codex/`, `cursor/`, `vscode/`, `fish/`, etc.), runtime/cache/logs (`.zcompdump*`, `*.log`, `*.tmp`, Raycast extensions, `.serena/`, `.backup/`).
- The installer does not claim, configure, or roll back ignored local state.

## Runtime output and diagnostics

Normal output reports the install plan, package/apply/verify stages, warnings, and the transaction run ID.

`--debug` adds non-sensitive diagnostics: resolved component selection, tap/formula/cask plan, component script path, Homebrew path, transaction ID, and package commands issued through the installer wrapper. It does not enable shell tracing, print environment variables or `.env` values, or replace the sandbox integration tests.
