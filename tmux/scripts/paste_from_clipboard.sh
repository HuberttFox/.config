#!/usr/bin/env bash
set -euo pipefail

command -v pbpaste >/dev/null 2>&1 || {
  printf 'pbpaste not found\n' >&2
  exit 1
}

content=$(pbpaste | tr -d '\r')
[[ -n "$content" ]] || exit 0

tmux set-buffer -- "$content"
tmux paste-buffer -p -d
