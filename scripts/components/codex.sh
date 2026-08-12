#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "Codex has no repository-managed configuration"
}

verify_component() {
  ensure_command_available codex
}

case "${1:-}" in
  formulae) ;;
  taps) ;;
  casks) printf '%s\n' codex ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for codex: ${1:-}" ;;
esac
