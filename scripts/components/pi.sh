#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "Pi has no repository-managed configuration"
}

verify_component() {
  ensure_command_available pi
}

case "${1:-}" in
  formulae) printf '%s\n' pi-coding-agent ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for pi: ${1:-}" ;;
esac
