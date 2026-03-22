#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "finicky/finicky.dia.js"
  require_repo_file "finicky/finicky.atlas.js"
  ensure_symlink "$CONFIG_REPO/finicky/finicky.dia.js" "$HOME/.finicky.js"
}

verify_component() {
  if [[ "$DRY_RUN" == "1" && ! -L "$HOME/.finicky.js" ]]; then
    log "Would verify ~/.finicky.js symlink after creation"
    return 0
  fi
  [[ -L "$HOME/.finicky.js" ]] || die "~/.finicky.js is not a symlink"
  [[ -f "$CONFIG_REPO/finicky/finicky.dia.js" ]] || die "Missing finicky config: finicky.dia.js"
  [[ -f "$CONFIG_REPO/finicky/finicky.atlas.js" ]] || die "Missing finicky config: finicky.atlas.js"
  [[ -d "/Applications/Finicky.app" ]] || die "Finicky.app not found in /Applications"
}

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) ;;
  taps) ;;
  casks) printf 'finicky\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for finicky: ${1:-}" ;;
esac
