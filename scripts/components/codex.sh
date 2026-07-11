#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "codex/config.toml"
  ensure_symlink "$CONFIG_REPO/codex/config.toml" "$HOME/.codex/config.toml"
}

verify_component() {
  local resolved=""

  if [[ "$DRY_RUN" == "1" && ! -L "$HOME/.codex/config.toml" ]]; then
    log "Would verify ~/.codex/config.toml symlink after creation"
  else
    [[ -L "$HOME/.codex/config.toml" ]] || die "~/.codex/config.toml is not a symlink"
  fi

  if resolved="$(command_path codex 2>/dev/null)"; then
    log "Codex command available: $resolved"
  else
    warn "Codex is not installed; synchronized config will apply when it becomes available"
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for codex: ${1:-}" ;;
esac
