#!/usr/bin/env bash
set -euo pipefail

command -v pbcopy >/dev/null 2>&1 || {
  printf 'pbcopy not found\n' >&2
  exit 1
}

content=$(tr -d '\r')
tmux set-buffer -w -- "$content"
printf '%s' "$content" | pbcopy
