#!/usr/bin/env bash
set -euo pipefail

target_pane="${1:-}"
if [[ -z "$target_pane" ]]; then
  target_pane="$(tmux display-message -p '#{pane_id}')"
fi

# Clear common terminal modes that leaking TUIs leave behind in a pane:
# mouse tracking, focus events, and bracketed paste.
tmux send-keys -t "$target_pane" C-c
tmux send-keys -t "$target_pane" "printf '\\033[?1000l\\033[?1002l\\033[?1003l\\033[?1004l\\033[?1005l\\033[?1006l\\033[?1015l\\033[?2004l'; stty sane 2>/dev/null || true; clear" Enter
