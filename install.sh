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

ALL_COMPONENTS=(git zsh zim fzf starship tmux lazygit vim yazi ccswitch mole)
SELECTED_COMPONENTS=()
SKIP_COMPONENTS=()
NO_SHELL_SWITCH=0
CONFIGURE_ZSH=0
SWITCH_SHELL=0
SHELL_SWITCHED=0
PROMPTED_SHELL_SWITCH=0
ROLLBACK_SELECTOR=""
ROLLBACK_FORCE=0
INSTALLER_DEBUG=0
export INSTALLER_DEBUG

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--all] [--only a,b,c] [--skip a,b,c] [--configure-zsh] [--switch-shell] [--no-shell-switch] [--debug]
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

  for name in "${SELECTED_COMPONENTS[@]-}"; do
    contains_word "$name" "${ALL_COMPONENTS[@]}" || die "Unknown component: $name"
    if [[ ${#SKIP_COMPONENTS[@]} -gt 0 ]] && contains_word "$name" "${SKIP_COMPONENTS[@]}"; then
      continue
    fi
    script="$(component_script "$name")"
    [[ -x "$script" ]] || die "Missing component script: $script"
    filtered+=("$name")
  done

  if [[ ${#filtered[@]} -eq 0 ]]; then
    SELECTED_COMPONENTS=()
  else
    SELECTED_COMPONENTS=("${filtered[@]}")
  fi
}

gate_zsh_components() {
  local current_shell
  local name
  local filtered=()
  local zsh_selected=0

  for name in "${SELECTED_COMPONENTS[@]-}"; do
    [[ "$name" == zsh || "$name" == zim ]] && zsh_selected=1
  done
  [[ "$zsh_selected" == "1" ]] || return 0
  current_shell="$(current_shell_path)"
  shell_is_zsh "$current_shell" && return 0
  system_zsh_path >/dev/null || die "安装器仅允许 macos 系统的终端 zsh shell 情况下运行。"
  [[ "$CONFIGURE_ZSH" == "1" ]] && return 0

  if [[ "$NO_SHELL_SWITCH" != "1" && "$SWITCH_SHELL" != "1" ]] && has_interactive_terminal; then
    if confirm "Current shell is $current_shell. Set login shell to /bin/zsh with chsh? This does not replace this session; decline skips Zsh/Zim. Use --configure-zsh to configure without switching."; then
      PROMPTED_SHELL_SWITCH=1
      return 0
    fi
    log "Skipping Zsh components because login-shell switch was declined"
  elif [[ "$NO_SHELL_SWITCH" == "1" ]]; then
    warn "Zsh configuration skipped: --no-shell-switch disables prompts; use --configure-zsh to configure without switching"
  else
    warn "Zsh configuration skipped outside Zsh; use --configure-zsh or --switch-shell"
  fi

  for name in "${SELECTED_COMPONENTS[@]-}"; do
    [[ -n "$name" ]] || continue
    if [[ "$name" == zsh || "$name" == zim ]]; then
      continue
    fi
    filtered+=("$name")
  done
  if [[ ${#filtered[@]} -eq 0 ]]; then
    SELECTED_COMPONENTS=()
  else
    SELECTED_COMPONENTS=("${filtered[@]}")
  fi
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

  for name in "${SELECTED_COMPONENTS[@]-}"; do
    [[ -n "$name" ]] || continue
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

  debug "Package plan: taps=${taps[*]-}; formulae=${formulae[*]-}; casks=${casks[*]-}"
  if [[ ${#taps[@]} -eq 0 && ${#formulae[@]} -eq 0 && ${#casks[@]} -eq 0 ]]; then
    log "No packages to install"
    return 0
  fi

  log "Stage: install packages"
  ensure_brew
  activate_brew_shellenv
  debug "Homebrew: $BREW_BIN"
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
  [[ -n "${SELECTED_COMPONENTS[*]-}" ]] || { log "Stage: apply configuration (none)"; return 0; }
  log "Stage: apply configuration"
  for name in "${SELECTED_COMPONENTS[@]-}"; do
    [[ -n "$name" ]] || continue
    script="$(component_script "$name")"
    debug "Apply component: $name ($script)"
    log "Applying component: $name"
    CURRENT_COMPONENT="$name" "$script" apply
  done
}

verify_components() {
  local name
  local script
  [[ -n "${SELECTED_COMPONENTS[*]-}" ]] || { log "Stage: verify configuration (none)"; return 0; }
  log "Stage: verify configuration"
  for name in "${SELECTED_COMPONENTS[@]-}"; do
    [[ -n "$name" ]] || continue
    script="$(component_script "$name")"
    debug "Verify component: $name ($script)"
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
    --configure-zsh)
      CONFIGURE_ZSH=1
      ;;
    --switch-shell)
      SWITCH_SHELL=1
      CONFIGURE_ZSH=1
      ;;
    --no-shell-switch)
      NO_SHELL_SWITCH=1
      ;;
    --debug)
      INSTALLER_DEBUG=1
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
[[ "$SWITCH_SHELL" != "1" || "$NO_SHELL_SWITCH" != "1" ]] || die "--switch-shell cannot be combined with --no-shell-switch"
collect_selected_components
if [[ "$SWITCH_SHELL" == "1" ]] && ! contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  die "--switch-shell requires the zsh component"
fi
gate_zsh_components

if [[ ${#SELECTED_COMPONENTS[@]} -gt 0 ]] && contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  print_shell_detection_context
fi
log "Install plan: ${SELECTED_COMPONENTS[*]-none}"
debug "Skipped components: ${SKIP_COMPONENTS[*]-none}"
transaction_start "$(IFS=,; printf '%s' "${SELECTED_COMPONENTS[*]-}")"
debug "Transaction run: $TRANSACTION_RUN_ID"
trap 'transaction_fail $?' ERR INT TERM
install_packages
apply_components
verify_components
if [[ "$SWITCH_SHELL" == "1" || "$PROMPTED_SHELL_SWITCH" == "1" ]] && [[ ${#SELECTED_COMPONENTS[@]} -gt 0 ]] && contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  if switch_login_shell_to_system_zsh; then
    SHELL_SWITCHED=1
  else
    warn "Zsh configured but login shell was not changed"
  fi
fi
if [[ ${#SELECTED_COMPONENTS[@]} -gt 0 ]] && find_brew_bin >/dev/null 2>&1; then
  activate_brew_shellenv
  CURRENT_COMPONENT=brew-shellenv ensure_brew_shellenv_for_shells
fi
transaction_set_status completed
trap - ERR INT TERM
log "Install completed (run: $TRANSACTION_RUN_ID)"
if [[ "$SHELL_SWITCHED" == "1" ]]; then
  log "Open a new terminal or run: exec /bin/zsh -l"
fi
