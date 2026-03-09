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
  command -v mole >/dev/null 2>&1 || die "mole not found"
}

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) printf 'mole\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for mole: ${1:-}" ;;
esac
