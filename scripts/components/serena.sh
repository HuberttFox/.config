#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

SERENA_CONFIG_FILE="$HOME/.serena/serena_config.yml"

install_serena_if_missing() {
  local uv_bin=""

  if command_path serena >/dev/null 2>&1; then
    log "serena is already available"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    if uv_bin="$(command_path uv 2>/dev/null)"; then
      run_cmd "$uv_bin" tool install -p 3.13 serena-agent@latest --prerelease=allow
    else
      log "Would run: uv tool install -p 3.13 serena-agent@latest --prerelease=allow"
    fi
    return 0
  fi

  uv_bin="$(command_path uv 2>/dev/null)" || die "uv not found"
  run_cmd "$uv_bin" tool install -p 3.13 serena-agent@latest --prerelease=allow
}

initialize_serena_if_needed() {
  if [[ -f "$SERENA_CONFIG_FILE" ]]; then
    log "serena is already initialized"
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would run: serena init"
    return 0
  fi

  run_cmd serena init
}

apply_component() {
  install_serena_if_missing
  initialize_serena_if_needed
}

verify_component() {
  ensure_command_available "serena"

  if [[ "$DRY_RUN" == "1" && ! -f "$SERENA_CONFIG_FILE" ]]; then
    log "Would verify Serena initialization file after setup: $SERENA_CONFIG_FILE"
    return 0
  fi

  [[ -f "$SERENA_CONFIG_FILE" ]] || die "Serena appears uninitialized: missing $SERENA_CONFIG_FILE"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for serena: ${1:-}" ;;
esac
