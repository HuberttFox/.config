#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CONFIG_REPO="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/brew.sh
source "$ROOT_DIR/scripts/lib/brew.sh"
# shellcheck source=scripts/lib/transaction.sh
source "$ROOT_DIR/scripts/lib/transaction.sh"

ALL_COMPONENTS=(git zsh zim fzf starship tmux lazygit vim yazi)
SELECTED_COMPONENTS=()
SKIP_COMPONENTS=()
NO_SHELL_SWITCH=0
ROLLBACK_SELECTOR=""
ROLLBACK_FORCE=0

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--all] [--only a,b,c] [--skip a,b,c] [--no-shell-switch]
       ./install.sh --rollback <latest|run-id|all>
       ./install.sh --rollback-force <latest|run-id|all>
USAGE
}

require_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This installer supports macOS only."
}

require_non_root_user() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    die "This installer must be run as a non-root user. Re-run it from your regular user account."
  fi
}

parse_csv_into_array() {
  local csv="$1"
  local item
  local values=()
  IFS=',' read -r -a values <<< "$csv"
  for item in "${values[@]}"; do
    item="$(trim "$item")"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
}

component_script() {
  local name="$1"
  printf '%s/scripts/components/%s.sh\n' "$ROOT_DIR" "$name"
}

collect_selected_components() {
  local name
  local script
  local filtered=()

  if [[ ${#SELECTED_COMPONENTS[@]} -eq 0 ]]; then
    SELECTED_COMPONENTS=("${ALL_COMPONENTS[@]}")
  fi

  for name in "${SELECTED_COMPONENTS[@]}"; do
    contains_word "$name" "${ALL_COMPONENTS[@]}" || die "Unknown component: $name"
    if [[ ${#SKIP_COMPONENTS[@]} -gt 0 ]] && contains_word "$name" "${SKIP_COMPONENTS[@]}"; then
      continue
    fi
    script="$(component_script "$name")"
    [[ -x "$script" ]] || die "Missing component script: $script"
    filtered+=("$name")
  done

  SELECTED_COMPONENTS=("${filtered[@]}")
}

install_packages() {
  local name
  local script
  local formula
  local cask
  local formulae=()
  local casks=()
  local taps=()
  local tap
  local taps_output

  for name in "${SELECTED_COMPONENTS[@]}"; do
    script="$(component_script "$name")"
    if taps_output="$($script taps 2>/dev/null)"; then
      while IFS= read -r tap; do
        [[ -z "$tap" ]] && continue
        append_unique taps "$tap"
      done <<< "$taps_output"
    fi
    while IFS= read -r formula; do
      [[ -z "$formula" ]] && continue
      append_unique formulae "$formula"
    done < <("$script" formulae)
    while IFS= read -r cask; do
      [[ -z "$cask" ]] && continue
      append_unique casks "$cask"
    done < <("$script" casks)
  done

  if [[ ${#taps[@]} -eq 0 && ${#formulae[@]} -eq 0 && ${#casks[@]} -eq 0 ]]; then
    log "No packages to install"
    return 0
  fi

  ensure_brew
  activate_brew_shellenv
  if [[ ${#taps[@]} -gt 0 ]]; then
    brew_install_taps "${taps[@]}"
  fi
  if [[ ${#formulae[@]} -gt 0 ]]; then
    brew_install_formulae "${formulae[@]}"
  fi
  if [[ ${#casks[@]} -gt 0 ]]; then
    brew_install_casks "${casks[@]}"
  fi
}

apply_components() {
  local name
  local script
  for name in "${SELECTED_COMPONENTS[@]}"; do
    script="$(component_script "$name")"
    log "Applying component: $name"
    CURRENT_COMPONENT="$name" "$script" apply
  done
}

verify_components() {
  local name
  local script
  for name in "${SELECTED_COMPONENTS[@]}"; do
    script="$(component_script "$name")"
    log "Verifying component: $name"
    "$script" verify
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)
      ;;
    --only)
      shift
      [[ $# -gt 0 && -n "$(trim "$1")" ]] || die "--only requires a non-empty value"
      while IFS= read -r item; do
        SELECTED_COMPONENTS+=("$item")
      done < <(parse_csv_into_array "$1")
      ;;
    --skip)
      shift
      [[ $# -gt 0 && -n "$(trim "$1")" ]] || die "--skip requires a non-empty value"
      while IFS= read -r item; do
        SKIP_COMPONENTS+=("$item")
      done < <(parse_csv_into_array "$1")
      ;;
    --no-shell-switch)
      NO_SHELL_SWITCH=1
      ;;
    --rollback|--rollback-force)
      [[ -z "$ROLLBACK_SELECTOR" ]] || die "Rollback option specified more than once"
      [[ "$1" == "--rollback-force" ]] && ROLLBACK_FORCE=1
      shift
      [[ $# -gt 0 ]] || die "Rollback requires latest, all, or a run ID"
      ROLLBACK_SELECTOR="$1"
      ;;
    --dry-run)
      die "--dry-run is no longer supported. Use tests/integration.sh for safe installer validation."
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
  shift
done

require_macos
initialize_common_state

if [[ -n "$ROLLBACK_SELECTOR" ]]; then
  [[ ${#SELECTED_COMPONENTS[@]} -eq 0 && ${#SKIP_COMPONENTS[@]} -eq 0 ]] || die "Rollback cannot be combined with component selection"
  transaction_rollback "$ROLLBACK_SELECTOR" "$ROLLBACK_FORCE"
  exit $?
fi

[[ "$(basename "$ROOT_DIR")" == ".config" ]] || warn "Expected repo root to be named .config, got: $ROOT_DIR"
require_non_root_user
collect_selected_components

if contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  print_shell_detection_context
fi
log "Selected components: ${SELECTED_COMPONENTS[*]}"
transaction_start "$(IFS=,; printf '%s' "${SELECTED_COMPONENTS[*]}")"
trap 'transaction_fail $?' ERR INT TERM
install_packages
apply_components
verify_components
if [[ "$NO_SHELL_SWITCH" != "1" ]] && contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  auto_switch_login_shell_to_zsh
fi
if find_brew_bin >/dev/null 2>&1; then
  activate_brew_shellenv
  CURRENT_COMPONENT=brew-shellenv ensure_brew_shellenv_for_shells
fi
transaction_set_status completed
trap - ERR INT TERM
log "Install completed (run: $TRANSACTION_RUN_ID)"
if [[ "$NO_SHELL_SWITCH" != "1" ]] && contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  start_interactive_zsh_session
fi
