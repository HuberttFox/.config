#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  :
}

verify_component() {
  [[ -d /Applications/CCSwitch.app ]] || ensure_command_available cc-switch
}

case "${1:-}" in
  formulae) ;;
  taps) printf '%s\n' farion1231/ccswitch ;;
  casks) printf '%s\n' cc-switch ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for ccswitch: ${1:-}" ;;
esac
