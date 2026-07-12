#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  local content=""
  require_repo_file "git/config"
  if [[ -f "$HOME/.gitconfig" && ! -L "$HOME/.gitconfig" ]]; then
    content="$(cat "$HOME/.gitconfig")"
    case "$content" in
      $'[include]\n\tpath = ~/.config/git/config.shared'|$'[include]\n\tpath = ~/.config/git/config.shared\n[include]\n\tpath = ~/.config/git/config.local')
        local seq
        seq="$(transaction_prepare "$HOME/.gitconfig" "$CURRENT_COMPONENT")"
        rm -f "$HOME/.gitconfig"
        transaction_applied "$seq" "$HOME/.gitconfig"
        log "Removed legacy Git loader: $HOME/.gitconfig"
        ;;
      *) warn "Preserving user-managed file: $HOME/.gitconfig" ;;
    esac
  fi
}

verify_component() {
  require_repo_file "git/config"
  ensure_command_available git
}

case "${1:-}" in
  formulae) printf 'git\n' ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for git: ${1:-}" ;;
esac
