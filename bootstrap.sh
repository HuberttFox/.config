#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
platform="${RIME_BOOTSTRAP_UNAME:-$(uname -s)}"

case "$platform" in
  Darwin)
    exec "$ROOT_DIR/install.sh" "$@"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    # Prefer PowerShell 7; Windows PowerShell 5.1 can run the bootstrap and
    # install PowerShell 7 before the RIME step needs it.
    powershell_host=''
    if command -v pwsh.exe >/dev/null 2>&1; then
      powershell_host='pwsh.exe'
    elif command -v powershell.exe >/dev/null 2>&1; then
      powershell_host='powershell.exe'
    else
      printf 'PowerShell 5.1 or PowerShell 7 is required for the Windows bootstrap.\n' >&2
      exit 127
    fi
    windows_root="${RIME_BOOTSTRAP_WINDOWS_ROOT:-}"
    if [[ -n "$windows_root" ]]; then
      # An explicit dispatcher root wins over PATH tooling: Git Bash always ships
      # cygpath, so this is also the only reliable override on Windows.
      windows_script="$windows_root/windows-bootstrap/install.ps1"
    elif command -v cygpath >/dev/null 2>&1; then
      windows_script="$(cygpath -w "$ROOT_DIR/windows-bootstrap/install.ps1")"
    else
      windows_root="$(cd "$ROOT_DIR" && pwd -W 2>/dev/null || true)"
      if [[ -z "$windows_root" ]]; then
        printf 'Cannot convert repository path for PowerShell. Install cygpath or run windows-bootstrap/install.ps1 directly.\n' >&2
        exit 2
      fi
      windows_script="$windows_root/windows-bootstrap/install.ps1"
    fi
    exec "$powershell_host" -NoProfile -ExecutionPolicy Bypass -File "$windows_script" "$@"
    ;;
  WSL*|Linux)
    printf 'Run the .config bootstrap from the Windows host; WSL/Linux is not supported.\n' >&2
    exit 2
    ;;
  *)
    printf 'Unsupported platform: %s\n' "$platform" >&2
    exit 2
    ;;
esac
