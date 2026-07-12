#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  require_repo_file "zsh/zshrc"
  require_repo_file "zsh/zshenv"

  write_managed_file "$HOME/.zshenv" <<'MANAGED'
if [[ -f ~/.config/zsh/zshenv ]]; then
  source ~/.config/zsh/zshenv
fi
MANAGED

  write_managed_file "$HOME/.zshrc" <<'MANAGED'
if [[ -f ~/.config/zsh/zshrc ]]; then
  source ~/.config/zsh/zshrc
fi
MANAGED
}

verify_component() {
  [[ -f "$HOME/.zshenv" ]] || die "Missing ~/.zshenv"
  [[ -f "$HOME/.zshrc" ]] || die "Missing ~/.zshrc"
}

case "${1:-}" in
  formulae) printf 'zsh\n' ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for zsh: ${1:-}" ;;
esac
