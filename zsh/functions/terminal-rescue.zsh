[[ -o interactive ]] || return 0

_terminal_rescue_precmd() {
  printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l'
}

autoload -Uz add-zsh-hook
if (( ${precmd_functions[(Ie)_terminal_rescue_precmd]} == 0 )); then
  add-zsh-hook precmd _terminal_rescue_precmd
fi
