#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'starship\n' ;;
  apply) : ;;
  verify)
    if [[ "$DRY_RUN" == "1" ]] && ! command -v starship >/dev/null 2>&1; then
      log "Would verify starship after install"
    else
      command -v starship >/dev/null 2>&1 || die "starship not found"
    fi
    ;;
  *) die "Unknown subcommand for starship: ${1:-}" ;;
esac
