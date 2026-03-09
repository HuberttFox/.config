#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'fastfetch\n' ;;
  apply) : ;;
  verify)
    if [[ "$DRY_RUN" == "1" ]] && ! command -v fastfetch >/dev/null 2>&1; then
      log "Would verify fastfetch after install"
    else
      command -v fastfetch >/dev/null 2>&1 || die "fastfetch not found"
    fi
    ;;
  *) die "Unknown subcommand for fastfetch: ${1:-}" ;;
esac
