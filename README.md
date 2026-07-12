# dotfiles bootstrap

**English** | [简体中文](README.zh-CN.md)

macOS-only bootstrap repository intended to live at `~/.config`.

## Components

The installer manages:

- Shell: `git`, `zsh`, `zim`, `fzf`, `starship`, `tmux`
- Development CLI: `lazygit`, `vim`, `yazi`

Removed components are no longer installed or configured, but existing applications are not uninstalled.

## Secrets

Tracked `.env.example` defines required variable names without values:

```bash
cp .env.example .env
chmod 600 .env
```

Fill local values in `.env`:

```dotenv
CONTEXT7_API_KEY=
RAYCAST_MODELSCOPE_API_KEY=
RAYCAST_PERPLEXITY_API_KEY=
```

Zsh loads simple `NAME=VALUE` assignments from `.env`. The file is ignored and values are never committed. Move assignments from legacy `zsh/env.local.zsh` manually; that file is no longer sourced.

Raycast does not interpolate `.env` itself. Generate its ignored provider file explicitly:

```bash
./scripts/render-raycast-providers
```

The renderer validates required values, writes atomically, applies mode `0600`, and never prints secrets.

## Install

```bash
# All retained components
./install.sh

# Selected components
./install.sh --only zsh,tmux,fzf

# Exclude components
./install.sh --skip tmux,yazi

# Install without changing login shell or starting a new Zsh
./install.sh --no-shell-switch
```

The installer:

1. Rejects non-macOS and root execution.
2. Collects Homebrew taps, formulae, and casks.
3. Installs missing packages.
4. Applies selected configuration.
5. Verifies every selected component.
6. Records installer-owned file changes in a transaction.
7. Optionally registers Zsh, runs `chsh`, persists `brew shellenv`, and starts login Zsh.

Git and tmux use native XDG paths (`~/.config/git/config` and `~/.config/tmux/tmux.conf`). Legacy `~/.gitconfig` and `~/.tmux.conf` loaders are removed only when they exactly match old installer-generated content; unknown files are preserved with a warning.

## Safe validation

`--dry-run` was removed because it skipped the operations most likely to fail. Use the sandbox integration suite instead:

```bash
tests/integration.sh
```

It runs real installer `apply` and `verify` paths under temporary `HOME` and state directories with stubbed Homebrew, network, tmux, Serena, `sudo`, and `chsh`. Temporary data is deleted afterward.

## File rollback

Every install receives a run ID. File rollback commands:

```bash
./install.sh --rollback latest
./install.sh --rollback <run-id>
./install.sh --rollback all
./install.sh --rollback-force <latest|run-id|all>
```

Normal rollback restores replaced paths and removes paths created by the selected run, newest changes first. If a managed path changed after installation, rollback stops and preserves it. Forced rollback first stores the conflicting current version under the run's `rollback-conflicts/` directory.

Rollback covers only files and symlinks changed through installer transaction helpers. It does **not** reverse Homebrew packages/taps/casks, `/etc/shells`, `chsh`, TPM or Zim downloads, or application preferences.

Transaction data lives under `${XDG_STATE_HOME:-~/.local/state}/dotfiles-installer`. If installation fails, the error prints the run ID and exact rollback command.

## Important details

- Installer-managed replacements are journaled and backed up before mutation.
- Package installation and external setup still require network access.
- Without `--no-shell-switch`, selecting Zsh may invoke `sudo`, modify `/etc/shells`, run `chsh`, and replace the current shell process with `zsh -l`.
- Homebrew environment lines are written transactionally to login profiles.
- Ignored local application configuration, credentials, sessions, logs, and runtime state remain outside installer scope.
- Old Finicky files/applications and packages removed from the component list are not deleted automatically.
