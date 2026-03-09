#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "git/config"
  write_managed_file "$HOME/.gitconfig" <<'MANAGED'
[include]
	path = ~/.config/git/config
MANAGED
}

verify_component() {
  [[ -f "$HOME/.gitconfig" ]] || die "Missing ~/.gitconfig"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'git\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for git: ${1:-}" ;;
esac
