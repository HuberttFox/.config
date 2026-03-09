#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "opencode config already lives under ~/.config/opencode"
}

verify_component() {
  if [[ "$DRY_RUN" == "1" ]] && ! command -v opencode >/dev/null 2>&1; then
    log "Would verify opencode after install"
  else
    command -v opencode >/dev/null 2>&1 || die "opencode not found"
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'opencode\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for opencode: ${1:-}" ;;
esac
