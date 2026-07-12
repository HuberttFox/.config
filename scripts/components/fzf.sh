#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

case "${1:-}" in
  formulae) printf 'fzf\n' ;;
  taps) ;;
  casks) ;;
  apply) require_repo_file "zsh/fzf.zsh" ;;
  verify) ensure_command_available fzf ;;
  *) die "Unknown subcommand for fzf: ${1:-}" ;;
esac
