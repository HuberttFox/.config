#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

apply_component() {
  local tpm_dir="$HOME/.tmux/plugins/tpm"
  local tpm_install="$tpm_dir/bin/install_plugins"

  require_repo_file "tmux/tmux.conf"
  if [[ ! -d "$tpm_dir" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "Would install tmux plugin manager to $tpm_dir"
    else
      command_path git >/dev/null 2>&1 || die "git not found"
      ensure_dir "$(dirname "$tpm_dir")"
      git clone https://github.com/tmux-plugins/tpm "$tpm_dir"
    fi
  else
    log "tmux plugin manager already installed"
  fi

  write_managed_file "$HOME/.tmux.conf" <<'MANAGED'
source-file ~/.config/tmux/tmux.conf
MANAGED

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would install tmux plugins via TPM"
  else
    [[ -x "$tpm_install" ]] || die "Missing $tpm_install"
    "$tpm_install" >/dev/null
  fi
}

verify_component() {
  local tmux_output=""
  local tmux_bin=""
  local socket_name="dotfiles-verify-$$"

  if [[ "$DRY_RUN" == "1" && ! -x "$HOME/.tmux/plugins/tpm/tpm" ]]; then
    log "Would verify ~/.tmux/plugins/tpm/tpm after install"
  else
    [[ -x "$HOME/.tmux/plugins/tpm/tpm" ]] || die "Missing ~/.tmux/plugins/tpm/tpm"
  fi

  if [[ "$DRY_RUN" == "1" && ! -f "$HOME/.tmux.conf" ]]; then
    log "Would verify ~/.tmux.conf after creation"
    return 0
  fi
  [[ -f "$HOME/.tmux.conf" ]] || die "Missing ~/.tmux.conf"
  tmux_bin="$(command_path tmux 2>/dev/null)" || return 0
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would verify tmux by sourcing ~/.tmux.conf"
  else
    "$tmux_bin" -L "$socket_name" -f /dev/null new-session -d -s dotfiles-verify >/dev/null 2>&1 || \
      die "tmux failed to start an isolated verification server"
    if ! tmux_output="$("$tmux_bin" -L "$socket_name" source-file "$HOME/.tmux.conf" 2>&1)"; then
      "$tmux_bin" -L "$socket_name" kill-server >/dev/null 2>&1 || true
      die "tmux failed to source ~/.tmux.conf: $tmux_output"
    fi
    "$tmux_bin" -L "$socket_name" kill-server >/dev/null 2>&1 || true
  fi
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) printf 'tmux\n' ;;
  taps) ;;
  casks) ;;
  apply) apply_component ;;
  verify) verify_component ;;
  *) die "Unknown subcommand for tmux: ${1:-}" ;;
esac
