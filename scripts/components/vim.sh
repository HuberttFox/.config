#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'vim\n' ;;
  casks) ;;
  apply) : ;;
  verify) ensure_command_available "vim" ;;
  *) die "Unknown subcommand for vim: ${1:-}" ;;
esac
