if [[ -n "${TMUX:-}" ]]; then
  export STARSHIP_CONFIG="$HOME/.config/starship-tmux.toml"
elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
  export STARSHIP_CONFIG="$HOME/.config/starship-wsl.toml"
else
  unset STARSHIP_CONFIG
fi

eval "$(starship init zsh)"
