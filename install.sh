#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
export CONFIG_REPO="$ROOT_DIR"

# shellcheck source=scripts/lib/common.sh
source "$ROOT_DIR/scripts/lib/common.sh"
# shellcheck source=scripts/lib/brew.sh
source "$ROOT_DIR/scripts/lib/brew.sh"

ALL_COMPONENTS=(git zsh zim fzf starship tmux tldr fastfetch lazygit codex claude opencode mole)
SELECTED_COMPONENTS=()
SKIP_COMPONENTS=()
DRY_RUN=0
FORCE=0
PLATFORM="$(detect_platform)"

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--all] [--only a,b,c] [--skip a,b,c] [--dry-run] [--force]
USAGE
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

component_supported() {
  local name="$1"
  local script="$2"
  local item
  for item in $("$script" platforms); do
    if [[ "$item" == "all" || "$item" == "$PLATFORM" ]]; then
      return 0
    fi
  done
  return 1
}

collect_selected_components() {
  local name
  local filtered=()

  if [[ ${#SELECTED_COMPONENTS[@]} -eq 0 ]]; then
    SELECTED_COMPONENTS=("${ALL_COMPONENTS[@]}")
  fi

  for name in "${SELECTED_COMPONENTS[@]}"; do
    contains_word "$name" "${ALL_COMPONENTS[@]}" || die "Unknown component: $name"
    if [[ ${#SKIP_COMPONENTS[@]} -gt 0 ]] && contains_word "$name" "${SKIP_COMPONENTS[@]}"; then
      continue
    fi
    filtered+=("$name")
  done

  SELECTED_COMPONENTS=("${filtered[@]}")
}

filter_supported_components() {
  local name
  local script
  local filtered=()
  for name in "${SELECTED_COMPONENTS[@]}"; do
    script="$(component_script "$name")"
    [[ -x "$script" ]] || die "Missing component script: $script"
    if component_supported "$name" "$script"; then
      filtered+=("$name")
    else
      warn "Skipping unsupported component on $PLATFORM: $name"
    fi
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

  for name in "${SELECTED_COMPONENTS[@]}"; do
    script="$(component_script "$name")"
    while IFS= read -r formula; do
      [[ -z "$formula" ]] && continue
      append_unique formulae "$formula"
    done < <("$script" formulae)
    while IFS= read -r cask; do
      [[ -z "$cask" ]] && continue
      append_unique casks "$cask"
    done < <("$script" casks)
  done

  if [[ ${#formulae[@]} -eq 0 && ${#casks[@]} -eq 0 ]]; then
    log "No packages to install"
    return 0
  fi

  ensure_brew
  activate_brew_shellenv
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
    "$script" apply
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
      [[ $# -gt 0 ]] || die "--only requires a value"
      while IFS= read -r item; do
        SELECTED_COMPONENTS+=("$item")
      done < <(parse_csv_into_array "$1")
      ;;
    --skip)
      shift
      [[ $# -gt 0 ]] || die "--skip requires a value"
      while IFS= read -r item; do
        SKIP_COMPONENTS+=("$item")
      done < <(parse_csv_into_array "$1")
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --force)
      FORCE=1
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

export DRY_RUN FORCE PLATFORM
initialize_common_state

[[ "$(basename "$ROOT_DIR")" == ".config" ]] || warn "Expected repo root to be named .config, got: $ROOT_DIR"
collect_selected_components
filter_supported_components

log "Platform: $PLATFORM"
if contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  print_shell_detection_context
fi
log "Selected components: ${SELECTED_COMPONENTS[*]}"
install_packages
apply_components
verify_components
if contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  auto_switch_login_shell_to_zsh
fi
if find_brew_bin >/dev/null 2>&1; then
  activate_brew_shellenv
  ensure_brew_shellenv_for_shells
fi
log "Install completed"
if contains_word "zsh" "${SELECTED_COMPONENTS[@]}"; then
  start_interactive_zsh_session
fi
