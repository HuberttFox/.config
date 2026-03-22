#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "git/config.shared"
  if [[ -f "$CONFIG_REPO/git/config.local" ]]; then
    write_managed_file "$HOME/.gitconfig" <<'MANAGED'
[include]
	path = ~/.config/git/config.shared
[include]
	path = ~/.config/git/config.local
MANAGED
  else
    write_managed_file "$HOME/.gitconfig" <<'MANAGED'
[include]
	path = ~/.config/git/config.shared
MANAGED
  fi
}

verify_component() {
  if [[ "$DRY_RUN" == "1" && ! -f "$HOME/.gitconfig" ]]; then
    log "Would verify ~/.gitconfig after creation"
    return 0
  fi
  [[ -f "$HOME/.gitconfig" ]] || die "Missing ~/.gitconfig"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'git\n' ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for git: ${1:-}" ;;
esac
