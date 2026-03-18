#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  log "opencode config already lives under ~/.config/opencode"
}

verify_component() {
  require_repo_file "opencode/opencode.json"
  ensure_command_available "opencode"

  if [[ -z "${CLIPROXY_API_KEY:-}" ]]; then
    warn "CLIPROXY_API_KEY is not set; cliproxy-backed opencode requests will fail until it is exported"
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae)
    printf 'opencode\n'
    ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for opencode: ${1:-}" ;;
esac
