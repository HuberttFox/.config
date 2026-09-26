# Agent Guidelines for dotfiles repository

This repository is a macOS-only bootstrap system intended to live at `~/.config`.

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

`--dry-run` is intentionally unsupported; use the sandbox integration tests instead.

## Windows RIME

Windows RIME is separate from the macOS-only `install.sh` flow. It targets
Windows 11 x64 and signed PowerShell 7 x64 (`pwsh.exe`); existing Windows
PowerShell 5.1 profiles remain untouched and unsupported by new RIME scripts.

- New Windows RIME `.ps1` files start with `#requires -Version 7.0` as line 1.
- Daily operations must run as the marker owner SID, never `SYSTEM`, another
  user, or a 32-bit PowerShell process.
- Tests must never perform real Registry, UAC, ACL, Junction, Weasel installer/
  deploy/process, DISM, WSL, scheduled-task, reboot, or input-method actions.
- Portable tests only prove pure logic and controlled temporary-directory
  behavior. Do not claim Windows-native Registry, ACL, Junction, Weasel,
  cross-SID/session, reparse-race, or Raycast success without Windows 11 x64
  acceptance evidence.
- Reparse checks before an operation reduce but do not eliminate syscall
  check-to-use races. Do not describe them as handle-level no-follow safety.

## Validation

There is no traditional build. macOS installer changes must pass:

```bash
./tests/integration.sh
find . -type f -name "*.sh" -exec bash -n {} +
find . -type f -name "*.sh" -exec shellcheck {} +  # when available
```

Windows RIME changes additionally require PowerShell 7 when available:

```bash
pwsh -NoProfile -File tests/windows/run.ps1
pwsh -NoProfile -Command '
  $files = Get-ChildItem windows,tests/windows -Recurse -Filter *.ps1
  $bad = foreach ($file in $files) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { "$($file.FullName): $($errors | ForEach-Object Message -join \"; \")" }
  }
  if ($bad) { $bad; exit 1 }
'
./tests/bootstrap.sh
./tests/integration.sh
find . -type f -name "*.sh" -exec bash -n {} +
python3 -m json.tool windows/manifests/rime.lock.json >/dev/null
git diff --check --no-index /dev/null bootstrap.sh docs/windows-rime-plan.md \
  tests/bootstrap.sh tests/windows/run.ps1 windows/README.md windows/README.zh-CN.md \
  windows/install.ps1 windows/lib/Rime.Core.ps1 windows/lib/Rime.Install.ps1 \
  windows/lib/Rime.Switch.ps1 windows/lib/Rime.Windows.ps1 \
  windows/manifests/rime.lock.json windows/scripts/rime-switch.ps1 \
  windows/scripts/rime-userdata.ps1 windows/raycast/Rime-Ice.bat \
  windows/raycast/Rime-Mint.bat windows/raycast/Rime-Moqi.bat \
  windows/raycast/Rime-Status.bat windows/raycast/Rime-Toggle.bat
```

When `pwsh` is unavailable, record its exact missing-command output. Do not
claim the PowerShell suite or parser passed. Untracked Windows files are not
covered by ordinary `git diff`; pass them explicitly to whitespace checking.

The integration suite uses temporary `HOME` and installer state with command stubs. Tests must never invoke real Homebrew, network downloads, `sudo`, `chsh`, or application installers. Installer changes require `tests/integration.sh` coverage.

## Bash style

- Start scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Quote variable expansions.
- Use `local` inside functions.
- Prefer `printf` over `echo`.
- Source shared libraries from paths derived from `ROOT_DIR` or `CONFIG_REPO`.
- Use `die` for fatal errors.
- Keep tool logic in `scripts/components/<name>.sh`; do not bloat `install.sh`.

## Component architecture

`install.sh` rejects non-macOS, resolves retained components, installs Homebrew packages, starts a file transaction, applies components, verifies them, persists the Homebrew environment, and optionally switches to Zsh.

Shared libraries:

- `scripts/lib/common.sh`: logging, command resolution, transaction-aware file/symlink/profile helpers, shell switching.
- `scripts/lib/brew.sh`: macOS Homebrew discovery, bootstrap, taps, formulae, casks, shellenv.
- `scripts/lib/transaction.sh`: run journal, backups, fingerprints, rollback and conflict handling.

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
- Rollback is conflict-safe and file-level only; it does not cover packages, `/etc/shells`, `chsh`, third-party downloads, or application state. Never imply package, cask, `/etc/shells`, `chsh`, TPM/Zim, Serena, or application-state rollback.

## Secrets

- Never put secret values in tracked files.
- `.env.example` contains empty placeholders only.
- `.env` and generated `raycast/ai/providers.yaml` remain ignored.
- Environment loaders must parse assignments, not evaluate arbitrary shell code.
- Secret renderer tests use dummy values and assert no output leakage plus `0600` permissions.
- Zsh loads simple assignments from `.env`; do not add arbitrary shell evaluation.
- Raycast template/renderer changes require integration tests with dummy keys, missing-value failure, no output leakage, and mode `0600`.

## Scope

Ignored application configuration and runtime state are local-only. Keep repository configuration limited to files consumed by retained components or native macOS application paths. Git and tmux use native XDG paths under this repository; Zsh still needs small home-level loader files. Ignored local application configuration, credentials, sessions, extensions, logs, and runtime state are outside installer scope.
