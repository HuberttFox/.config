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

current_shell_path() {
  local shell_path=""

  case "$PLATFORM" in
    linux)
      if [[ -L "/proc/$$/exe" ]]; then
        shell_path="$(readlink "/proc/$$/exe" 2>/dev/null || true)"
      fi
      ;;
    darwin)
      if command -v ps >/dev/null 2>&1; then
        shell_path="$(ps -p $$ -o comm= 2>/dev/null | awk '{$1=$1; print}')"
      fi
      ;;
  esac

  if [[ -z "$shell_path" ]] && command -v ps >/dev/null 2>&1; then
    shell_path="$(ps -p $$ -o comm= 2>/dev/null | awk '{$1=$1; print}')"
  fi

  if [[ -z "$shell_path" && -n "${ZSH_VERSION:-}" ]]; then
    shell_path="$(command_path zsh 2>/dev/null || true)"
  fi

  if [[ -z "$shell_path" && -n "${BASH_VERSION:-}" ]]; then
    shell_path="$(command_path bash 2>/dev/null || true)"
  fi

  printf '%s\n' "${shell_path:-${SHELL:-unknown}}"
}

login_shell_path() {
  local username
  local shell_path=""
  username="${USER:-$(id -un)}"
  case "$PLATFORM" in
    darwin)
      shell_path="$(dscl . -read "/Users/$username" UserShell 2>/dev/null | awk '/UserShell:/{print $2}')"
      ;;
    linux)
      if command -v getent >/dev/null 2>&1; then
        shell_path="$(getent passwd "$username" 2>/dev/null | awk -F: '{print $7}')"
      fi
      if [[ -z "$shell_path" && -r /etc/passwd ]]; then
        shell_path="$(awk -F: -v user="$username" '$1 == user {print $7; exit}' /etc/passwd)"
      fi
      ;;
  esac
  printf '%s\n' "${shell_path:-unknown}"
}

preferred_zsh_path() {
  local candidate
  if command -v zsh >/dev/null 2>&1; then
    command -v zsh
    return 0
  fi
  for candidate in /opt/homebrew/bin/zsh /home/linuxbrew/.linuxbrew/bin/zsh /usr/local/bin/zsh /bin/zsh; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

switchable_zsh_path() {
  local candidate
  local candidates=()
  local preferred=""

  if preferred="$(preferred_zsh_path 2>/dev/null)"; then
    append_unique candidates "$preferred"
  fi

  for candidate in /home/linuxbrew/.linuxbrew/bin/zsh /opt/homebrew/bin/zsh /usr/local/bin/zsh /bin/zsh /usr/bin/zsh; do
    [[ -x "$candidate" ]] || continue
    append_unique candidates "$candidate"
  done

  for candidate in "${candidates[@]}"; do
    if shell_is_registered "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  for candidate in "${candidates[@]}"; do
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

shell_is_registered() {
  local shell_path="$1"
  [[ -n "$shell_path" ]] || return 1
  [[ -r /etc/shells ]] || return 1
  grep -Fqx "$shell_path" /etc/shells
}

ensure_shell_registered() {
  local shell_path="$1"

  shell_is_registered "$shell_path" && return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would run: printf '%s\\n' '$shell_path' | sudo tee -a /etc/shells >/dev/null"
    return 0
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    warn "Cannot auto-register $shell_path in /etc/shells without an interactive terminal"
    return 1
  fi

  command -v sudo >/dev/null 2>&1 || {
    warn "Cannot auto-register $shell_path because sudo is unavailable"
    return 1
  }

  log "Registering zsh in /etc/shells: $shell_path"
  if printf '%s\n' "$shell_path" | sudo tee -a /etc/shells >/dev/null; then
    shell_is_registered "$shell_path" && return 0
  fi

  warn "Failed to register $shell_path in /etc/shells"
  return 1
}

print_shell_detection_context() {
  local current_shell login_shell
  current_shell="$(current_shell_path)"
  login_shell="$(login_shell_path)"
  log "Current shell: $current_shell"
  log "Login shell: $login_shell"
}

maybe_print_zsh_switch_notice() {
  local current_shell login_shell zsh_path
  current_shell="$(current_shell_path)"
  login_shell="$(login_shell_path)"

  [[ "$login_shell" != "unknown" ]] || return 0
  [[ "$login_shell" != */zsh ]] || return 0

  if ! zsh_path="$(preferred_zsh_path 2>/dev/null)"; then
    warn "zsh is not available in PATH yet; skipping shell-switch guidance"
    return 0
  fi

  warn "Default login shell is not zsh"
  if [[ "$current_shell" != */zsh ]]; then
    warn "Current shell is also not zsh"
  fi

  if shell_is_registered "$zsh_path"; then
    log "Run this command to switch your default shell:"
    log "  chsh -s $zsh_path"
  else
    warn "The detected zsh path is not listed in /etc/shells: $zsh_path"
    log "If you want to switch, add it to /etc/shells first, then run:"
    log "  echo '$zsh_path' | sudo tee -a /etc/shells"
    log "  chsh -s $zsh_path"
  fi

  log "Log out and back in for the shell change to take effect"
}

auto_switch_login_shell_to_zsh() {
  local login_shell current_shell zsh_path
  current_shell="$(current_shell_path)"
  login_shell="$(login_shell_path)"

  [[ "$login_shell" != "unknown" ]] || return 0
  if [[ "$login_shell" == */zsh ]]; then
    log "Login shell already uses zsh: $login_shell"
    return 0
  fi

  if ! zsh_path="$(switchable_zsh_path 2>/dev/null)"; then
    warn "Unable to resolve a usable zsh path for automatic shell switching"
    return 0
  fi

  if ! shell_is_registered "$zsh_path"; then
    if ! ensure_shell_registered "$zsh_path"; then
      warn "Automatic shell switch skipped: $zsh_path is not listed in /etc/shells"
      log "Run these commands manually if you want zsh as your login shell:"
      log "  printf '%s\n' '$zsh_path' | sudo tee -a /etc/shells >/dev/null"
      log "  chsh -s $zsh_path"
      return 0
    fi
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would run: chsh -s $zsh_path"
    return 0
  fi

  log "Switching login shell to zsh: $zsh_path"
  if chsh -s "$zsh_path"; then
    log "Login shell updated to: $zsh_path"
    if [[ "$current_shell" != */zsh ]]; then
      log "Open a new terminal session to start using zsh"
    fi
    return 0
  fi

  warn "Automatic shell switch failed"
  warn "Run this command manually: chsh -s $zsh_path"
}

start_interactive_zsh_session() {
  local current_shell zsh_path
  current_shell="$(current_shell_path)"

  [[ "$DRY_RUN" != "1" ]] || return 0
  [[ -t 0 && -t 1 ]] || return 0
  [[ "$current_shell" != */zsh ]] || return 0

  if ! zsh_path="$(preferred_zsh_path 2>/dev/null)"; then
    warn "Skipping zsh session handoff because zsh is not available in PATH"
    return 0
  fi

  log "Starting a new login zsh session"
  export SHELL="$zsh_path"
  exec "$zsh_path" -l
}

npm_global_package_installed() {
  local package="$1"
  local npm_cmd=""
  npm_cmd="$(command_path npm 2>/dev/null)" || return 1
  "$npm_cmd" list -g --depth=0 "$package" >/dev/null 2>&1
}

ensure_npm_global_package() {
  local package="$1"
  local npm_cmd=""
  if [[ "$DRY_RUN" == "1" ]]; then
    if npm_global_package_installed "$package"; then
      log "npm package already installed globally: $package"
    else
      log "Would install npm package globally: $package"
    fi
    return 0
  fi

  npm_cmd="$(command_path npm 2>/dev/null)" || die "npm not found"
  if npm_global_package_installed "$package"; then
    log "npm package already installed globally: $package"
  else
    run_cmd "$npm_cmd" install -g "$package"
  fi
}

command_path() {
  local name="$1"
  local candidate
  local npm_bin=""

  if candidate="$(command -v "$name" 2>/dev/null)"; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for candidate in \
    "/opt/homebrew/bin/$name" \
    "/home/linuxbrew/.linuxbrew/bin/$name" \
    "/usr/local/bin/$name" \
    "/bin/$name" \
    "/usr/bin/$name"
  do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  if command -v npm >/dev/null 2>&1; then
    npm_bin="$(npm prefix -g 2>/dev/null)/bin"
    candidate="$npm_bin/$name"
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

ensure_command_available() {
  local name="$1"
  local resolved=""

  if [[ "$DRY_RUN" == "1" ]]; then
    if resolved="$(command_path "$name" 2>/dev/null)"; then
      log "Verified command: $name -> $resolved"
    else
      log "Would verify $name after install"
    fi
    return 0
  fi

  resolved="$(command_path "$name" 2>/dev/null)" || die "$name not found"
  log "Verified command: $name -> $resolved"
}
