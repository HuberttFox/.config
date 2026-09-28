# Development Guide

**English** | [简体中文](development.zh-CN.md)

Setup, validation, coding style, and component authoring for this repository.

## Windows boundary

The Windows features are separate from `install.sh`. `windows-bootstrap/` is the
unattended Windows 11 entry and supports Windows PowerShell 5.1 and PowerShell 7;
`windows/` is the PowerShell 7 x64 RIME deployment. Follow
[Windows bootstrap](../windows-bootstrap/README.md) and
[Windows RIME](../windows/README.md). Portable suites are not native acceptance;
see [Native Windows acceptance](architecture.md#native-windows-acceptance) and
[the acceptance evidence](handoff-windows-rime-native-acceptance-evidence.md).

## Setup

No traditional build or package manager. The repo is the live installation at `~/.config`; clone it there. No dependencies beyond macOS tooling plus optional ShellCheck.

## Validation

```bash
# Sandbox integration suite (temporary HOME, stubbed commands)
./tests/integration.sh

# Syntax-check all shell files
find . -type f -name "*.sh" -exec bash -n {} +

# Lint (when ShellCheck is installed)
find . -type f -name "*.sh" -exec shellcheck {} +
```

```powershell
# Windows bootstrap portable suite (Windows PowerShell 5.1 or PowerShell 7)
pwsh -NoProfile -File .\windows-bootstrap\tests\run.ps1
powershell.exe -NoProfile -File .\windows-bootstrap\tests\run.ps1

# Mutation-free bootstrap plan
pwsh -NoProfile -File .\windows-bootstrap\install.ps1 -DryRun

# RIME portable suite (PowerShell 7 x64)
pwsh -NoProfile -File .\tests\windows\run.ps1
```

Rules:

- Installer changes require `tests/integration.sh` coverage.
- Tests use temporary `HOME`/state directories and stubs. Never call real Homebrew, network, `sudo`, `chsh`, or application installers.
- `--dry-run` is intentionally unsupported; use the integration tests instead.
- `windows-bootstrap` changes require `windows-bootstrap/tests/run.ps1` coverage and must keep `-DryRun` free of state/report/lock/Registry/profile/WSL/input-method mutations.
- New RIME `.ps1` files require `#requires -Version 7.0`; `windows-bootstrap` scripts intentionally declare `#requires -Version 5.1`.

## Bash style

- Start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Quote variable expansions.
- Use `local` inside functions.
- Prefer `printf` over `echo`.
- Source shared libraries from paths derived from `ROOT_DIR` or `CONFIG_REPO`.
- Use `die` for fatal errors.
- Keep tool logic in `scripts/components/<name>.sh`; do not bloat `install.sh`.

## Adding a component

1. Create `scripts/components/<name>.sh` implementing `formulae`, optional `taps`, `casks`, `apply`, `verify`.
2. Add `<name>` to `ALL_COMPONENTS` in `install.sh`.
3. Declare package needs via `formulae`/`taps`/`casks` before `apply`; do not install ad hoc inside `apply`.
4. If the component manages user files, symlinks, or profile lines, use transaction-aware helpers from `scripts/lib/common.sh` and `scripts/lib/transaction.sh`.
5. Add integration test coverage in `tests/integration.sh`.
6. Do not add platform subcommands or Linux branches.

### Package-only components

Simple tools can be pure package components:

```bash
case "${1:-}" in
  formulae) printf 'tool\n' ;;
  taps) ;;
  casks) ;;
  apply) : ;;
  verify) ensure_command_available tool ;;
  *) die "Unknown subcommand for tool: ${1:-}" ;;
esac
```

## Debug diagnostics

`./install.sh --debug` prints non-sensitive diagnostics: component selection, package plan, component script path, Homebrew path, transaction ID, and package commands. It never prints secrets or enables shell tracing.

## Transaction-aware file helpers

Use these from `scripts/lib/common.sh` instead of direct file operations:

| Helper | Purpose |
| --- | --- |
| `ensure_symlink target path` | Create/fix a symlink, journaled |
| `write_managed_file path` | Atomic write of stdin to path, journaled |
| `ensure_line_in_file path line` | Append line if missing, journaled |
| `remove_managed_path_if_exact_file` | Remove legacy loader only on exact match |
| `transaction_prepare` / `transaction_applied` | Low-level journaling (via helpers) |
