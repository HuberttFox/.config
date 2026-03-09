# dotfiles bootstrap

This repository is intended to live at `~/.config`.

## Install

Run everything:

```bash
./install.sh --all
```

Preview without modifying files:

```bash
./install.sh --all --dry-run
```

Install a subset:

```bash
./install.sh --only zsh,tmux,fzf
```

## Notes

- Homebrew formulae are preferred.
- Existing files are backed up to `~/.config/.backup/<timestamp>/`.
- Private state is not overwritten.
- Homebrew cask apps are intentionally excluded from this installer.
