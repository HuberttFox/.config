#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "zsh/fzf.zsh"
  ensure_symlink "$CONFIG_REPO/zsh/fzf.zsh" "$HOME/.fzf.zsh"
}

verify_component() {
  [[ -L "$HOME/.fzf.zsh" ]] || die "~/.fzf.zsh is not a symlink"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'fzf\n' ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for fzf: ${1:-}" ;;
esac
