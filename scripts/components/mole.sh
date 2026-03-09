#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "mole has no shared repo-managed config yet"
}

verify_component() {
  ensure_command_available "mole"
}

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) printf 'mole\n' ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for mole: ${1:-}" ;;
esac
