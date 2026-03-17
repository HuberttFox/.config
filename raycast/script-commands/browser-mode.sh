#!/usr/bin/env bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Browser Mode
# @raycast.mode silent
# @raycast.packageName browser-mode
# @raycast.description Switch Finicky browser mode

# Optional parameters:
# @raycast.icon 🧭
# @raycast.argument1 { "type": "dropdown", "placeholder": "Select browser", "data": [ {"title": "Dia", "value": "Dia"} , {"title": "ChatGPT Atlas", "value": "ChatGPT Atlas"} , {"title": "Arc", "value": "Arc"} , {"title": "Google Chrome", "value": "Google Chrome"} , {"title": "Firefox", "value": "Firefox"} , {"title": "Safari", "value": "Safari"} , {"title": "Zen", "value": "Zen"} ] }

set -euo pipefail

mode="${1:-}"
if [[ -z "$mode" ]]; then
  exit 0
fi

"$HOME/.config/scripts/browser-mode" "$mode" >/dev/null 2>&1
