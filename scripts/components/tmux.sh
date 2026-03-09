#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "tmux/tmux.conf"
  write_managed_file "$HOME/.tmux.conf" <<'MANAGED'
source-file ~/.config/tmux/tmux.conf
MANAGED
}

verify_component() {
  if [[ "$DRY_RUN" == "1" && ! -f "$HOME/.tmux.conf" ]]; then
    log "Would verify ~/.tmux.conf after creation"
    return 0
  fi
  [[ -f "$HOME/.tmux.conf" ]] || die "Missing ~/.tmux.conf"
  command -v tmux >/dev/null 2>&1 || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would verify tmux by sourcing ~/.tmux.conf"
  else
    tmux start-server >/dev/null 2>&1 || true
    tmux source-file "$HOME/.tmux.conf" >/dev/null 2>&1 || die "tmux failed to source ~/.tmux.conf"
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'tmux\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for tmux: ${1:-}" ;;
esac
