#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

BREW_BIN="${BREW_BIN:-}"

find_brew_bin() {
  local candidate
  if command -v brew >/dev/null 2>&1; then
    command -v brew
    return 0
  fi
  for candidate in /opt/homebrew/bin/brew /home/linuxbrew/.linuxbrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

ensure_brew() {
  if BREW_BIN="$(find_brew_bin 2>/dev/null)"; then
    export BREW_BIN
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    case "$PLATFORM" in
      darwin) BREW_BIN="/opt/homebrew/bin/brew" ;;
      linux) BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew" ;;
      *) die "Unsupported platform for Homebrew bootstrap: $PLATFORM" ;;
    esac
    export BREW_BIN
    log "Would install Homebrew"
    return 0
  fi

  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  BREW_BIN="$(find_brew_bin)"
  export BREW_BIN
}

activate_brew_shellenv() {
  [[ -n "$BREW_BIN" ]] || BREW_BIN="$(find_brew_bin)"
  export BREW_BIN

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would eval Homebrew shellenv from $BREW_BIN"
    return 0
  fi

  eval "$("$BREW_BIN" shellenv)"
}

ensure_brew_shellenv_in_zprofile() {
  local line
  [[ -n "$BREW_BIN" ]] || BREW_BIN="$(find_brew_bin)"
  export BREW_BIN
  line="$(printf 'eval "$(%s shellenv)"' "$BREW_BIN")"
  ensure_line_in_file "$HOME/.zprofile" "$line"
}

ensure_brew_shellenv_for_login_shell() {
  local line
  local login_shell
  local target_file

  [[ -n "$BREW_BIN" ]] || BREW_BIN="$(find_brew_bin)"
  export BREW_BIN
  line="$(printf 'eval "$(%s shellenv)"' "$BREW_BIN")"
  login_shell="$(login_shell_path)"

  case "$login_shell" in
    */zsh) target_file="$HOME/.zprofile" ;;
    */bash) target_file="$HOME/.bash_profile" ;;
    *)
      target_file="$HOME/.profile"
      warn "Unknown login shell for brew env persistence: $login_shell"
      ;;
  esac

  ensure_line_in_file "$target_file" "$line"
}

ensure_brew_shellenv_for_shells() {
  ensure_brew_shellenv_in_zprofile
  ensure_brew_shellenv_for_login_shell
}

brew_formula_installed() {
  "$BREW_BIN" list --formula "$1" >/dev/null 2>&1
}

brew_cask_installed() {
  "$BREW_BIN" list --cask "$1" >/dev/null 2>&1
}

brew_bin_dir() {
  [[ -n "$BREW_BIN" ]] || BREW_BIN="$(find_brew_bin)"
  dirname "$BREW_BIN"
}

brew_command_already_available() {
  local name="$1"
  local resolved=""
  local bin_dir=""

  resolved="$(command_path "$name" 2>/dev/null)" || return 1
  bin_dir="$(brew_bin_dir)"
  [[ "$resolved" == "$bin_dir/$name" ]]
}

brew_install_formulae() {
  local formula
  for formula in "$@"; do
    [[ -n "$formula" ]] || continue
    if brew_formula_installed "$formula"; then
      log "Formula already installed: $formula"
    elif brew_command_already_available "$formula"; then
      log "Command already available in Homebrew bin: $formula"
    else
      run_cmd "$BREW_BIN" install "$formula"
    fi
  done
  activate_brew_shellenv
}

brew_install_casks() {
  local cask
  if [[ "$PLATFORM" != "darwin" ]]; then
    warn "Skipping cask installation on non-macOS platform: $*"
    return 0
  fi
  for cask in "$@"; do
    [[ -n "$cask" ]] || continue
    if brew_cask_installed "$cask"; then
      log "Cask already installed: $cask"
    else
      run_cmd "$BREW_BIN" install --cask "$cask"
    fi
  done
  activate_brew_shellenv
}
