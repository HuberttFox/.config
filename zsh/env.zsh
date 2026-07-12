export LANG=en_US.UTF-8

if [[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

_dotfiles_env="$HOME/.config/.env"
if [[ -f "$_dotfiles_env" ]]; then
  while IFS= read -r _dotfiles_line || [[ -n "$_dotfiles_line" ]]; do
    _dotfiles_line="${_dotfiles_line#export }"
    [[ -z "$_dotfiles_line" || "$_dotfiles_line" == \#* ]] && continue
    if [[ "$_dotfiles_line" != [A-Za-z_][A-Za-z0-9_]#=* ]]; then
      print -u2 "Ignoring invalid .env assignment"
      continue
    fi
    _dotfiles_name="${_dotfiles_line%%=*}"
    _dotfiles_value="${_dotfiles_line#*=}"
    if [[ "$_dotfiles_value" == *$'\n'* || "$_dotfiles_value" == *$'\r'* ]]; then
      print -u2 "Ignoring multiline .env value: $_dotfiles_name"
      continue
    fi
    export "$_dotfiles_name=$_dotfiles_value"
  done < "$_dotfiles_env"
fi
unset _dotfiles_env _dotfiles_line _dotfiles_name _dotfiles_value

setopt HIST_IGNORE_ALL_DUPS
bindkey -e
WORDCHARS=${WORDCHARS//[\/]}
ZSH_AUTOSUGGEST_MANUAL_REBIND=1
