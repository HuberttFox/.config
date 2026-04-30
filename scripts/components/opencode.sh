#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  local rtk_bin=""

  log "opencode config already lives under ~/.config/opencode"

  if ! rtk_bin="$(command_path rtk 2>/dev/null)"; then
    warn "rtk not found; skipping OpenCode integration via rtk init"
    return 0
  fi

  if ! command_path opencode >/dev/null 2>&1; then
    warn "opencode not found; skipping rtk OpenCode integration"
    return 0
  fi

  run_cmd "$rtk_bin" init -g --opencode
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
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for opencode: ${1:-}" ;;
esac
