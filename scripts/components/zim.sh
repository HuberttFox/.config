#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  local curl_cmd=""
  local wget_cmd=""
  local zsh_cmd=""
  local zim_home="$HOME/.zim"
  local zimfw_path="$zim_home/zimfw.zsh"
  local zim_init_path="$zim_home/init.zsh"

  require_repo_file "zsh/zimrc"
  ensure_symlink "$CONFIG_REPO/zsh/zimrc" "$HOME/.zimrc"

  if [[ ! -e "$zimfw_path" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "Would download zimfw.zsh to $zimfw_path"
    else
      ensure_dir "$zim_home"
      if curl_cmd="$(command_path curl 2>/dev/null)"; then
        "$curl_cmd" -fsSL --create-dirs -o "$zimfw_path" \
          https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
      elif wget_cmd="$(command_path wget 2>/dev/null)"; then
        "$wget_cmd" -nv -O "$zimfw_path" \
          https://github.com/zimfw/zimfw/releases/latest/download/zimfw.zsh
      else
        die "Neither curl nor wget is available to download zimfw.zsh"
      fi
    fi
  else
    log "zimfw is already present"
  fi

  if [[ ! -e "$zim_init_path" || "$zim_init_path" -ot "$CONFIG_REPO/zsh/zimrc" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "Would generate zim init file from $CONFIG_REPO/zsh/zimrc"
    else
      zsh_cmd="$(command_path zsh 2>/dev/null)" || die "zsh not found"
      ZIM_HOME="$zim_home" ZIM_CONFIG_FILE="$CONFIG_REPO/zsh/zimrc" \
        "$zsh_cmd" -c 'source "$1" init' _ "$zimfw_path"
    fi
  else
    log "zim init is already up to date"
  fi
}

verify_component() {
  if [[ "$DRY_RUN" == "1" && ! -e "$HOME/.zim/zimfw.zsh" ]]; then
    log "Would verify ~/.zim/zimfw.zsh after install"
  else
    [[ -e "$HOME/.zim/zimfw.zsh" ]] || die "Missing ~/.zim/zimfw.zsh"
  fi

  if [[ "$DRY_RUN" == "1" && ! -e "$HOME/.zim/init.zsh" ]]; then
    log "Would verify ~/.zim/init.zsh after generation"
  else
    [[ -e "$HOME/.zim/init.zsh" ]] || die "Missing ~/.zim/init.zsh"
  fi

  if [[ "$DRY_RUN" == "1" && ! -L "$HOME/.zimrc" ]]; then
    log "Would verify ~/.zimrc symlink after creation"
    return 0
  fi
  [[ -L "$HOME/.zimrc" ]] || die "~/.zimrc is not a symlink"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for zim: ${1:-}" ;;
esac
