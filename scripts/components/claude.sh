#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "claude-code has no repo-managed shared config yet"
}

verify_component() {
  if [[ "$DRY_RUN" == "1" ]] && ! command -v claude >/dev/null 2>&1; then
    log "Would verify claude after install"
  else
    command -v claude >/dev/null 2>&1 || die "claude not found"
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) ;;
  casks) printf 'claude-code\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for claude: ${1:-}" ;;
esac
