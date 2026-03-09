#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  local curl_cmd=""
  local zsh_cmd=""

  require_repo_file "zsh/zimrc"

  if [[ ! -e "$HOME/.zim/zimfw.zsh" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "Would install zim via official installer"
    else
      curl_cmd="$(command_path curl 2>/dev/null)" || die "curl not found"
      zsh_cmd="$(command_path zsh 2>/dev/null)" || die "zsh not found"
      "$curl_cmd" -fsSL https://raw.githubusercontent.com/zimfw/install/master/install.zsh | "$zsh_cmd"
    fi
  else
    log "zim is already installed"
  fi

  ensure_symlink "$CONFIG_REPO/zsh/zimrc" "$HOME/.zimrc"
}

verify_component() {
  if [[ "$DRY_RUN" == "1" && ! -e "$HOME/.zim/zimfw.zsh" ]]; then
    log "Would verify ~/.zim/zimfw.zsh after install"
  else
    [[ -e "$HOME/.zim/zimfw.zsh" ]] || die "Missing ~/.zim/zimfw.zsh"
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
