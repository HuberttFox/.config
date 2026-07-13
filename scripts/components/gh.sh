#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "GitHub CLI has no repository-managed configuration"
}

verify_component() {
  ensure_command_available gh
}

case "${1:-}" in
  formulae) printf '%s\n' gh ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for gh: ${1:-}" ;;
esac
