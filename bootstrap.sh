#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
platform="${RIME_BOOTSTRAP_UNAME:-$(uname -s)}"

case "$platform" in
  Darwin)
    exec "$ROOT_DIR/install.sh" "$@"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    command -v pwsh.exe >/dev/null 2>&1 || {
      printf 'PowerShell 7 (pwsh.exe) required for Windows RIME entrypoint.\n' >&2
      exit 127
    }
    windows_root="${RIME_BOOTSTRAP_WINDOWS_ROOT:-}"
    if [[ -n "$windows_root" ]]; then
      # An explicit dispatcher root wins over PATH tooling: Git Bash always ships
      # cygpath, so this is also the only reliable override on Windows.
      windows_script="$windows_root/windows/install.ps1"
    elif command -v cygpath >/dev/null 2>&1; then
      windows_script="$(cygpath -w "$ROOT_DIR/windows/install.ps1")"
    else
      windows_root="$(cd "$ROOT_DIR" && pwd -W 2>/dev/null || true)"
      if [[ -z "$windows_root" ]]; then
        printf 'Cannot convert repository path for PowerShell 7. Install cygpath or use windows/install.ps1 directly.\n' >&2
        exit 2
      fi
      windows_script="$windows_root/windows/install.ps1"
    fi
    exec pwsh.exe -NoProfile -File "$windows_script" "$@"
    ;;
  WSL*|Linux)
    printf 'Run Windows RIME installer from Windows host with PowerShell 7; WSL/Linux is not supported.\n' >&2
    exit 2
    ;;
  *)
    printf 'Unsupported platform: %s\n' "$platform" >&2
    exit 2
    ;;
esac
