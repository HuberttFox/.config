#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "zsh/zimrc"
  ensure_symlink "$CONFIG_REPO/zsh/zimrc" "$HOME/.zimrc"
}

verify_component() {
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
