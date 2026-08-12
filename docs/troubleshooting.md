# Troubleshooting

**English** | [简体中文](troubleshooting.zh-CN.md)

Common failures, error messages, and fixes.

## Installer rejects non-macOS / root

```
This installer supports macOS only.
This installer must be run as a non-root user.
```

Run on macOS as a regular user. The installer never supports Linux or package managers other than Homebrew.

## Zsh gate stops the run

```
安装器仅允许 macos 系统的终端 zsh shell 情况下运行。
```

`/bin/zsh` is required whenever `zsh` or `zim` is selected and the current shell is not Zsh. Fixes:

- Run from Zsh, or
- Pass `--configure-zsh` to configure without switching, or
- Pass `--switch-shell` to configure and then `chsh -s /bin/zsh` (requires the `zsh` component).

`--no-shell-switch` skips Zsh/Zim entirely on non-Zsh runs.

## Shell switch did not change login shell

```bash
$ zsh    # new terminal or: exec /bin/zsh -l
```

The installer never edits `/etc/shells` and never replaces the current shell process. If `chsh` failed, run it manually:

```bash
chsh -s /bin/zsh
```

The installer only switches when `/bin/zsh` is already registered in `/etc/shells` and a terminal is interactive.

## Rollback reports a conflict

```
Rollback conflict: /path/to/file
```

A managed path changed after install. Rollback preserves your edits and stops. To restore anyway (backing up the current version under that run's `rollback-conflicts/`):

```bash
./install.sh --rollback-force latest
```

## `--dry-run` fails

`--dry-run` is intentionally unsupported. Use the sandbox integration suite:

```bash
./tests/integration.sh
```

## Renderer fails / missing Raycast keys

```
Missing required Raycast key in .env
Missing .env
```

Copy `.env.example` to `.env`, fill values, `chmod 600 .env`, then rerun `./scripts/render-raycast-providers`. The renderer validates values, writes atomically with mode `0600`, and never prints secrets.

## Component skipped unexpectedly

Log shows `Zsh configuration skipped` — the run is non-interactive or `--no-shell-switch` suppressed the prompt. Use `--configure-zsh` or `--switch-shell` for deterministic Zsh configuration.

## Legacy loader preserved with a warning

```
Preserving user-managed file: ~/.gitconfig
```

Files not matching old installer-generated content are left untouched. Inspect and merge manually; the installer does not overwrite unknown user files.
