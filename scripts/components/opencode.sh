#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  if [[ "$PLATFORM" == "linux" ]]; then
    ensure_npm_global_package "opencode"
  fi
  log "opencode config already lives under ~/.config/opencode"
}

verify_component() {
  ensure_command_available "opencode"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae)
    if [[ "$PLATFORM" == "linux" ]]; then
      printf 'node\n'
    else
      printf 'opencode\n'
    fi
    ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for opencode: ${1:-}" ;;
esac
