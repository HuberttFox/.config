if [[ -n "${TMUX:-}" ]]; then
  export STARSHIP_CONFIG="$HOME/.config/starship-tmux.toml"
else
  unset STARSHIP_CONFIG
fi

eval "$(starship init zsh)"
