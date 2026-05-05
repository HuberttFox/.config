#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "beads installation is managed via Homebrew"
}

verify_component() {
  ensure_command_available "beads"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'beads\n' ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for beads: ${1:-}" ;;
esac
