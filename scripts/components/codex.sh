#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "codex/config.toml"
  ensure_symlink "$CONFIG_REPO/codex/config.toml" "$HOME/.codex/config.toml"
  if [[ "$PLATFORM" == "linux" ]]; then
    ensure_npm_global_package "codex"
  fi
}

verify_component() {
  if [[ "$DRY_RUN" == "1" && ! -L "$HOME/.codex/config.toml" ]]; then
    log "Would verify ~/.codex/config.toml symlink after creation"
    return 0
  fi
  [[ -L "$HOME/.codex/config.toml" ]] || die "~/.codex/config.toml is not a symlink"
  ensure_command_available "codex"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae)
    if [[ "$PLATFORM" == "linux" ]]; then
      printf 'node\n'
    fi
    ;;
  casks)
    if [[ "$PLATFORM" == "darwin" ]]; then
      printf 'codex\n'
    fi
    ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for codex: ${1:-}" ;;
esac
