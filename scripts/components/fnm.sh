#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'fnm\n' ;;
  apply) : ;;
  verify)
    if [[ "$DRY_RUN" == "1" ]] && ! command -v fnm >/dev/null 2>&1; then
      log "Would verify fnm after install"
    else
      command -v fnm >/dev/null 2>&1 || die "fnm not found"
    fi
    ;;
  *) die "Unknown subcommand for fnm: ${1:-}" ;;
esac
