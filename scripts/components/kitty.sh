#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
export CONFIG_REPO="$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/common.sh"
initialize_common_state

kitty_linux_install_dir() {
  printf '%s\n' "${KITTY_LINUX_DEST:-$HOME/.local/kitty.app}"
}

kitty_command_path() {
  local candidate

  if candidate="$(command_path kitty 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in \
    "$HOME/.local/bin/kitty" \
    "$(kitty_linux_install_dir)/bin/kitty" \
    "/Applications/kitty.app/Contents/MacOS/kitty"
  do
    [[ -x "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

install_kitty_on_linux() {
  local install_dir
  install_dir="$(kitty_linux_install_dir)"

  if [[ "$FORCE" != "1" && -x "$install_dir/bin/kitty" ]]; then
    log "kitty already installed at $install_dir"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      log "Would run kitty official installer for Linux"
    else
      command -v curl >/dev/null 2>&1 || die "curl is required to install kitty on Linux"
      /bin/sh -c "curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin launch=n"
    fi
  fi

  ensure_symlink "$install_dir/bin/kitty" "$HOME/.local/bin/kitty"
  ensure_symlink "$install_dir/bin/kitten" "$HOME/.local/bin/kitten"
}

verify_kitty_install() {
  local resolved=""

  if [[ "$DRY_RUN" == "1" ]]; then
    if resolved="$(kitty_command_path 2>/dev/null)"; then
      log "Verified command: kitty -> $resolved"
    else
      log "Would verify kitty after install"
    fi
    return 0
  fi

  resolved="$(kitty_command_path 2>/dev/null)" || die "kitty not found"
  log "Verified command: kitty -> $resolved"
}

case "${1:-}" in
  platforms) printf 'darwin\nlinux\n' ;;
  formulae) ;;
  casks)
    [[ "$PLATFORM" == "darwin" ]] && printf 'kitty\n'
    ;;
  apply)
    if [[ "$PLATFORM" == "linux" ]]; then
      install_kitty_on_linux
    fi
    ;;
  verify) verify_kitty_install ;;
  *) die "Unknown subcommand for kitty: ${1:-}" ;;
esac
