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
  if [[ "$DRY_RUN" == "1" && ! -f "$HOME/.zshenv" ]]; then
    log "Would verify ~/.zshenv after creation"
  else
    [[ -f "$HOME/.zshenv" ]] || die "Missing ~/.zshenv"
  fi

  if [[ "$DRY_RUN" == "1" && ! -f "$HOME/.zshrc" ]]; then
    log "Would verify ~/.zshrc after creation"
    return 0
  fi
  [[ -f "$HOME/.zshrc" ]] || die "Missing ~/.zshrc"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'zsh\n' ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for zsh: ${1:-}" ;;
esac
