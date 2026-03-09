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

  eval "$(\"$BREW_BIN\" shellenv)"
}

ensure_brew_shellenv_in_zprofile() {
  local line
  [[ -n "$BREW_BIN" ]] || BREW_BIN="$(find_brew_bin)"
  export BREW_BIN
  line="$(printf 'eval "$(%s shellenv)"' "$BREW_BIN")"
  ensure_line_in_file "$HOME/.zprofile" "$line"
}

brew_formula_installed() {
  "$BREW_BIN" list --formula "$1" >/dev/null 2>&1
}

brew_cask_installed() {
  "$BREW_BIN" list --cask "$1" >/dev/null 2>&1
}

brew_install_formulae() {
  local formula
  for formula in "$@"; do
    [[ -n "$formula" ]] || continue
    if brew_formula_installed "$formula"; then
      log "Formula already installed: $formula"
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
