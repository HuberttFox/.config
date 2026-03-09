#!/usr/bin/env bash
set -euo pipefail

: "${CONFIG_REPO:=}"
: "${PLATFORM:=}"
: "${DRY_RUN:=0}"
: "${FORCE:=0}"
: "${BACKUP_RUN_ID:=}"

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

detect_platform() {
  case "$(uname -s)" in
    Darwin) printf 'darwin\n' ;;
    Linux) printf 'linux\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

initialize_common_state() {
  if [[ -z "$CONFIG_REPO" ]]; then
    CONFIG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export CONFIG_REPO
  fi
  if [[ -z "$PLATFORM" ]]; then
    PLATFORM="$(detect_platform)"
    export PLATFORM
  fi
  if [[ -z "$BACKUP_RUN_ID" ]]; then
    BACKUP_RUN_ID="$(date +%Y%m%d-%H%M%S)"
    export BACKUP_RUN_ID
  fi
}

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

contains_word() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

append_unique() {
  local array_name="$1"
  local value="$2"
  eval "local current=(\"\${${array_name}[@]-}\")"
  contains_word "$value" "${current[@]}" && return 0
  eval "${array_name}+=(\"$value\")"
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY]'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

ensure_dir() {
  local path="$1"
  [[ -d "$path" ]] && return 0
  run_cmd mkdir -p "$path"
}

backup_path() {
  local path="$1"
  local rel
  local target
  local target_dir

  [[ -e "$path" || -L "$path" ]] || return 0

  rel="${path#$HOME/}"
  if [[ "$rel" == "$path" ]]; then
    rel="${path#/}"
  fi

  target="$CONFIG_REPO/.backup/$BACKUP_RUN_ID/$rel"
  target_dir="$(dirname "$target")"
  ensure_dir "$target_dir"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would back up $path -> $target"
    return 0
  fi

  cp -a "$path" "$target"
}

ensure_symlink() {
  local target="$1"
  local link_path="$2"
  local current_target=""

  if [[ -L "$link_path" ]]; then
    current_target="$(readlink "$link_path")"
    if [[ "$current_target" == "$target" ]]; then
      log "Symlink already correct: $link_path -> $target"
      return 0
    fi
  fi

  if [[ -e "$link_path" || -L "$link_path" ]]; then
    backup_path "$link_path"
    run_cmd rm -rf "$link_path"
  fi

  ensure_dir "$(dirname "$link_path")"
  run_cmd ln -s "$target" "$link_path"
}

write_managed_file() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"

  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    log "File already up to date: $path"
    return 0
  fi

  if [[ -e "$path" || -L "$path" ]]; then
    backup_path "$path"
    run_cmd rm -rf "$path"
  fi

  ensure_dir "$(dirname "$path")"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would write managed file: $path"
    rm -f "$tmp"
    return 0
  fi

  mv "$tmp" "$path"
}

ensure_line_in_file() {
  local path="$1"
  local line="$2"

  if [[ -f "$path" ]] && grep -Fqx "$line" "$path"; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would append line to $path: $line"
    return 0
  fi

  ensure_dir "$(dirname "$path")"
  touch "$path"
  printf '\n%s\n' "$line" >> "$path"
}

require_repo_file() {
  local rel="$1"
  local path="$CONFIG_REPO/$rel"
  [[ -e "$path" ]] || die "Missing repo-managed file: $path"
}
