#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) ;;
  taps) ;;
  casks) printf 'iterm2\n' ;;
  apply) : ;;
  verify) : ;;
  *) die "Unknown subcommand for iterm2: ${1:-}" ;;
esac
