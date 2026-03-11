[ -f ~/.config/zsh/fzf.zsh ] && source ~/.config/zsh/fzf.zsh

if command -v fnm >/dev/null 2>&1; then
  eval "$(fnm env --use-on-cd)"
fi
