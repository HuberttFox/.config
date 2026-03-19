#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  :
}

verify_component() {
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would verify cc-switch installation"
    return 0
  fi

  if [[ -d "/Applications/CCSwitch.app" ]]; then
    return 0
  fi

  ensure_command_available "cc-switch"
}

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) ;;
  taps) printf 'farion1231/ccswitch\n' ;;
  casks) printf 'cc-switch\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for ccswitch: ${1:-}" ;;
esac
