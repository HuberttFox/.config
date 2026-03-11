#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'yazi\n' ;;
  casks) ;;
  apply) : ;;
  verify) ensure_command_available "yazi" ;;
  *) die "Unknown subcommand for yazi: ${1:-}" ;;
esac
