#!/usr/bin/env bash
set -euo pipefail

: "${CONFIG_REPO:=}"
: "${CURRENT_COMPONENT:=installer}"

# shellcheck source=transaction.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/transaction.sh"

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

initialize_common_state() {
  if [[ -z "$CONFIG_REPO" ]]; then
    CONFIG_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    export CONFIG_REPO
  fi
}

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

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

run_cmd() { "$@"; }

ensure_dir() {
  local path="$1"
  [[ -d "$path" ]] && return 0
  mkdir -p "$path"
}

remove_managed_path_if_exact_file() {
  local path="$1"
  local expected="$2"
  local tmp
  [[ -f "$path" && ! -L "$path" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-legacy.XXXXXX")"
  printf '%s' "$expected" > "$tmp"
  if cmp -s "$tmp" "$path"; then
    local seq
    seq="$(transaction_prepare "$path" "$CURRENT_COMPONENT")"
    rm -f "$path"
    transaction_applied "$seq" "$path"
    log "Removed legacy loader: $path"
  else
    warn "Preserving user-managed file: $path"
  fi
  rm -f "$tmp"
}

ensure_symlink() {
  local target="$1"
  local link_path="$2"
  local current_target=""
  local seq
  if [[ -L "$link_path" ]]; then
    current_target="$(readlink "$link_path")"
    if [[ "$current_target" == "$target" ]]; then
      log "Symlink already correct: $link_path -> $target"
      return 0
    fi
  fi
  seq="$(transaction_prepare "$link_path" "$CURRENT_COMPONENT")"
  [[ ! -e "$link_path" && ! -L "$link_path" ]] || rm -rf "$link_path"
  mkdir -p "$(dirname "$link_path")"
  ln -s "$target" "$link_path"
  transaction_applied "$seq" "$link_path"
}

write_managed_file() {
  local path="$1"
  local tmp
  local seq
  mkdir -p "$TRANSACTION_RUN_DIR/tmp"
  tmp="$(mktemp "$TRANSACTION_RUN_DIR/tmp/managed.XXXXXX")"
  cat > "$tmp"
  if [[ -f "$path" && ! -L "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    log "File already up to date: $path"
    return 0
  fi
  seq="$(transaction_prepare "$path" "$CURRENT_COMPONENT")"
  [[ ! -e "$path" && ! -L "$path" ]] || rm -rf "$path"
  mkdir -p "$(dirname "$path")"
  mv "$tmp" "$path"
  transaction_applied "$seq" "$path"
}

ensure_line_in_file() {
  local path="$1"
  local line="$2"
  local seq
  if [[ -f "$path" ]] && grep -Fqx "$line" "$path"; then return 0; fi
  seq="$(transaction_prepare "$path" "$CURRENT_COMPONENT")"
  mkdir -p "$(dirname "$path")"
  if [[ -s "$path" ]] && [[ "$(tail -c 1 "$path" 2>/dev/null || true)" != '' ]]; then printf '\n' >> "$path"; fi
  printf '%s\n' "$line" >> "$path"
  transaction_applied "$seq" "$path"
}

require_repo_file() {
  local path="$CONFIG_REPO/$1"
  [[ -e "$path" ]] || die "Missing repo-managed file: $path"
}

current_shell_path() {
  local shell_path=""
  command -v ps >/dev/null 2>&1 && shell_path="$(ps -p "$PPID" -o comm= 2>/dev/null | awk '{$1=$1; print}')"
  [[ -n "$shell_path" ]] || shell_path="${SHELL:-unknown}"
  printf '%s\n' "$shell_path"
}

shell_is_zsh() { [[ "$(basename "$1")" == zsh ]]; }

login_shell_path() {
  local username="${USER:-$(id -un)}"
  local shell_path=""
  shell_path="$(dscl . -read "/Users/$username" UserShell 2>/dev/null | awk '/UserShell:/{print $2}')"
  printf '%s\n' "${shell_path:-unknown}"
}

system_zsh_path() {
  [[ -x /bin/zsh ]] || return 1
  printf '%s\n' /bin/zsh
}

shells_file_path() { printf '%s\n' /etc/shells; }

shell_is_registered() {
  local shells_file
  shells_file="$(shells_file_path)"
  [[ -r "$shells_file" ]] && grep -Fqx "$1" "$shells_file"
}

print_shell_detection_context() {
  log "Current shell: $(current_shell_path)"
  log "Login shell: $(login_shell_path)"
}

switch_login_shell_to_system_zsh() {
  local login_shell zsh_path shells_file
  [[ -t 0 && -t 1 ]] || { warn "Cannot switch login shell without an interactive terminal"; return 1; }
  zsh_path="$(system_zsh_path)" || { warn "Missing system Zsh: /bin/zsh"; return 1; }
  login_shell="$(login_shell_path)"
  [[ "$login_shell" == "$zsh_path" ]] && { log "Login shell already uses system Zsh: $zsh_path"; return 0; }
  shells_file="$(shells_file_path)"
  shell_is_registered "$zsh_path" || { warn "$zsh_path is not registered in $shells_file; register it before switching shells"; return 1; }
  chsh -s "$zsh_path" || { warn "Shell switch failed; run: chsh -s $zsh_path"; return 1; }
  log "Login shell switched to system Zsh: $zsh_path"
}

command_path() {
  local name="$1" candidate
  command -v "$name" >/dev/null 2>&1 && { command -v "$name"; return; }
  for candidate in "/opt/homebrew/bin/$name" "/usr/local/bin/$name" "/bin/$name" "/usr/bin/$name"; do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return; }
  done
  return 1
}

ensure_command_available() {
  local resolved
  resolved="$(command_path "$1")" || die "$1 not found"
  log "Verified command: $1 -> $resolved"
}
