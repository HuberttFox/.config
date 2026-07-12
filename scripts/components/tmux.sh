#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  local tpm_dir="$HOME/.tmux/plugins/tpm"
  local tpm_install="$tpm_dir/bin/install_plugins"
  local legacy='source-file ~/.config/tmux/tmux.conf'
  require_repo_file "tmux/tmux.conf"

  if [[ ! -d "$tpm_dir" ]]; then
    local seq
    command_path git >/dev/null 2>&1 || die "git not found"
    seq="$(transaction_prepare "$tpm_dir" "$CURRENT_COMPONENT")"
    mkdir -p "$(dirname "$tpm_dir")"
    if git clone https://github.com/tmux-plugins/tpm "$tpm_dir"; then
      transaction_applied "$seq" "$tpm_dir"
    else
      rm -rf "$tpm_dir"
      return 1
    fi
  else
    log "tmux plugin manager already installed"
  fi

  if [[ -f "$HOME/.tmux.conf" && ! -L "$HOME/.tmux.conf" ]]; then
    if [[ "$(cat "$HOME/.tmux.conf")" == "$legacy" ]]; then
      local seq
      seq="$(transaction_prepare "$HOME/.tmux.conf" "$CURRENT_COMPONENT")"
      rm -f "$HOME/.tmux.conf"
      transaction_applied "$seq" "$HOME/.tmux.conf"
      log "Removed legacy tmux loader: $HOME/.tmux.conf"
    else
      warn "Preserving user-managed file: $HOME/.tmux.conf; it may override XDG config"
    fi
  fi

  [[ -x "$tpm_install" ]] || die "Missing $tpm_install"
  "$tpm_install" >/dev/null
}

verify_component() {
  local tmux_output=""
  local tmux_bin=""
  local socket_name="dotfiles-verify-$$"
  [[ -x "$HOME/.tmux/plugins/tpm/tpm" ]] || die "Missing ~/.tmux/plugins/tpm/tpm"
  tmux_bin="$(command_path tmux 2>/dev/null)" || die "tmux not found"
  "$tmux_bin" -L "$socket_name" -f /dev/null new-session -d -s dotfiles-verify >/dev/null 2>&1 || die "tmux failed to start verification server"
  if ! tmux_output="$("$tmux_bin" -L "$socket_name" source-file "$CONFIG_REPO/tmux/tmux.conf" 2>&1)"; then
    "$tmux_bin" -L "$socket_name" kill-server >/dev/null 2>&1 || true
    die "tmux failed to source config: $tmux_output"
  fi
  "$tmux_bin" -L "$socket_name" kill-server >/dev/null 2>&1 || true
}

case "${1:-}" in
  formulae) printf 'tmux\n' ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for tmux: ${1:-}" ;;
esac
