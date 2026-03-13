# Agent Guidelines for dotfiles repository

This repository manages personal dotfiles, configurations, and machine bootstrapping scripts, designed to reside at `~/.config`. As an agent modifying this codebase, you must adhere strictly to these guidelines to ensure the safety, idempotency, and reliability of the user's local environment.

## 1. Build, Lint, and Test Commands

Because this is a dotfiles repository, there is no traditional compilation step or test suite. Validation is performed through static analysis (linting) and idempotency checks via dry-run executions.

### Linting
All shell scripts must pass `shellcheck` without warnings or errors.
Run this command to lint a specific script before proposing changes:
```bash
shellcheck path/to/script.sh
```
To check all scripts in the repository:
```bash
find . -type f -name "*.sh" -exec shellcheck {} +
```

### Testing & Validation
Testing relies on the idempotency of the installer and its built-in preview mechanism. You MUST test installer modifications using the dry-run flag before assuming success.

**To safely test changes to the installer or components:**
Run the installer in dry-run mode. This verifies script logic, variable resolution, and component parsing without modifying the file system or executing package managers.
```bash
./install.sh --all --dry-run
```

**To test a single component (e.g., if you modified `zsh` setup):**
```bash
./install.sh --only zsh --dry-run
```

When modifying a specific component in `scripts/components/<name>.sh`, ensure the `verify` block correctly detects both healthy and broken states.

---

## 2. Code Style & Architecture Guidelines

### Bash Scripting (Primary Language)
The installer and all modules are written in Bash. Conform to these strict standards:

- **Shebang & Strict Mode**: Every script must start with:
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  ```
- **Variables**:
  - Always quote variables to prevent word splitting and globbing: `"$VAR"` not `$VAR`.
  - Use `local` for all variables declared inside functions.
  - Prefix global/environment variables with uppercase letters (e.g., `CONFIG_REPO`, `DRY_RUN`).
- **Output**: Use `printf` instead of `echo` for consistency and predictable escaping.
  - Correct: `printf '%s\n' "Message"`
  - Incorrect: `echo "Message"`
- **Includes**: When sourcing library files, include a shellcheck directive to suppress warnings:
  ```bash
  # shellcheck source=scripts/lib/common.sh
  source "$ROOT_DIR/scripts/lib/common.sh"
  ```
- **Error Handling**: Use the provided `die` function (from `common.sh`) for fatal errors.
  ```bash
  [[ -f "$file" ]] || die "Critical file missing: $file"
  ```

### Component Architecture
The bootstrapping process is modular. If asked to add a new tool, create a new script under `scripts/components/`. Do not bloat the main `install.sh`.

A valid component script MUST implement a specific `case` structure handling these subcommands:
1.  `platforms`: Print supported OS types (`darwin`, `linux`, `all`).
2.  `formulae`: Print Homebrew formula names to install (one per line).
3.  `casks`: Print Homebrew cask names to install (one per line).
4.  `apply`: Execute logic to link files or generate configurations. 
5.  `verify`: Check if the installation was successful. MUST respect `$DRY_RUN == 1` to skip physical file checks during previews.

*Reference Implementation (e.g., `scripts/components/alacritty.sh`):*
```bash
case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'package-name\n' ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand: ${1:-}" ;;
esac
```

### Safe File Modifications
Never use raw `cp` or `echo >` to generate configuration files in the user's `$HOME` directory. 
Always use the provided `write_managed_file` helper from `common.sh`. This ensures files are safely backed up before being overwritten, maintaining the `.backup/` history.

```bash
write_managed_file "$HOME/.toolrc" <<'MANAGED'
# Config goes here
MANAGED
```

### Python Scripts
Python scripts (e.g., `tmux/scripts/session_manager.py`) must follow modern Python 3 conventions:
- Use type hints (`from typing import List, Dict`, etc.).
- Prefer `subprocess.run` over older methods (`os.system`, `subprocess.Popen`) for shell executions.
- Use strict typing and handle edge cases for external command outputs.

### Operational Safety & Mandates
1. **Idempotency**: All `apply` scripts must be safe to run multiple times. They should check if a configuration already exists and gracefully update or skip it.
2. **Path Resolution**: Always use absolute paths derived from `$ROOT_DIR` or `$CONFIG_REPO`.
3. **Privacy**: Do not commit secrets, API keys, or machine-specific paths to shared config files.
4. **Gitignore**: If a tool requires private state, runtime auth files, or extensions, ensure the relevant directories are added to `.gitignore`.
5. **Remote Operations**: Never store fixed credentials in this repository. Use environment-managed secrets or local-only secure notes outside Git.
