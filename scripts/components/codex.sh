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
  if [[ "$DRY_RUN" == "1" && ! -L "$HOME/.codex/config.toml" ]]; then
    log "Would verify ~/.codex/config.toml symlink after creation"
    return 0
  fi
  [[ -L "$HOME/.codex/config.toml" ]] || die "~/.codex/config.toml is not a symlink"
  if [[ "$DRY_RUN" == "1" ]] && ! command -v codex >/dev/null 2>&1; then
    log "Would verify codex after install"
  else
    command -v codex >/dev/null 2>&1 || die "codex not found"
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\n' ;;
  formulae) ;;
  casks) printf 'codex\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for codex: ${1:-}" ;;
esac
