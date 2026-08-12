# Components Reference

**English** | [简体中文](components.zh-CN.md)

Per-component reference for all 12 installer components. Each component script implements a subset of `formulae`, `taps`, `casks`, `apply`, `verify`. See [Architecture](architecture.md) for the component model.

## Summary

| Component | Formula | Tap / Cask | Apply behavior | Verify |
| --- | --- | --- | --- | --- |
| `git` | `git` | — | Removes legacy `~/.gitconfig` loader if exact match | `git` available |
| `zsh` | — | — | Writes `~/.zshenv`, `~/.zshrc` loader files | `/bin/zsh` + loader files |
| `zim` | — | — | Symlinks `~/.zimrc`, installs zimfw + init | zimfw, init, `.zimrc` symlink |
| `fzf` | `fzf` | — | Requires `zsh/fzf.zsh` | `fzf` available |
| `starship` | `starship` | — | No-op | `starship` available |
| `tmux` | `tmux` | — | Clones TPM, installs plugins, removes legacy loader | TPM + config sources |
| `lazygit` | `lazygit` | — | No-op | `lazygit` available |
| `vim` | `vim` | — | No-op | `vim` available |
| `yazi` | `yazi` | — | No-op | `yazi` available |
| `ccswitch` | — | tap `farion1231/ccswitch`, cask `cc-switch` | No-op | app or command |
| `mole` | `mole` | — | No-op | `mole` available |
| `gh` | `gh` | — | No-op | `gh` available |

## Configuration ownership

Repository-owned config (tracked files consumed at runtime):

| Component | Config path | Notes |
| --- | --- | --- |
| `git` | `git/config` (XDG `~/.config/git/config`), `git/ignore` | `config.local` is local-only, gitignored |
| `zsh` | `zsh/zshrc`, `zsh/zshenv` + home loader files | Loader files (`~/.zshenv`, `~/.zshrc`) source repo config |
| `zim` | `zsh/zimrc` (symlinked to `~/.zimrc`) | Plugin downloads are local-only |
| `fzf` | `zsh/fzf.zsh` | Consumed via `zsh/zshrc` |
| `starship` | `starship-tmux.toml` | Consumed by `zsh/prompt.zsh`, only active when in `TMUX` and `zsh` configured |
| `tmux` | `tmux/tmux.conf`, `tmux/scripts/` | XDG path `~/.config/tmux/tmux.conf`; TPM plugins downloaded to `~/.tmux/plugins/` |

Package-only components — no repository-managed configuration:

- `lazygit`, `vim`, `yazi`, `mole`, `gh`: formula + availability verification only. Auth, accounts, extensions, preferences, and state remain user-managed.
- `ccswitch`: tap + cask + availability only. Does not manage CCSwitch preferences, accounts, providers, or application state.

## Notes

- `starship` config activates only when the `zsh` component is configured (`zsh/prompt.zsh` sets `STARSHIP_CONFIG`).
- Legacy loaders (`~/.gitconfig`, `~/.tmux.conf`) are removed only when they exactly match old installer-generated content; unknown files are preserved with a warning.
- Removed components are neither installed nor configured. Existing packages and applications are never uninstalled automatically.
