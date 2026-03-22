#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "claude-code has no repo-managed shared config yet"
}

verify_component() {
  ensure_command_available "claude"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae)
    if [[ "$PLATFORM" == "linux" ]]; then
      printf 'claude-code\n'
    fi
    ;;
  taps) ;;
  casks)
    if [[ "$PLATFORM" == "darwin" ]]; then
      printf 'claude-code\n'
    fi
    ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for claude: ${1:-}" ;;
esac
