#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "Claude Code has no repository-managed configuration"
}

verify_component() {
  ensure_command_available claude
}

case "${1:-}" in
  formulae) ;;
  taps) ;;
  casks) printf '%s\n' claude-code ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for claude-code: ${1:-}" ;;
esac
