#!/usr/bin/env bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Browser Mode
# @raycast.mode silent
# @raycast.packageName browser-mode
# @raycast.description Switch Finicky browser mode

# Optional parameters:
# @raycast.icon 🧭

set -euo pipefail

mode="${1:-}"

if [[ -z "$mode" ]]; then
  choices=()
  defaults=(
    "Dia"
    "ChatGPT Atlas"
    "Arc"
    "Google Chrome"
    "Firefox"
    "Safari"
    "Microsoft Edge"
    "Brave Browser"
    "Vivaldi"
    "Opera"
    "Zen"
  )

  for app in "${defaults[@]}"; do
    if [[ -d "/Applications/${app}.app" ]]; then
      choices+=("$app")
    fi
  done

  if [[ ${#choices[@]} -eq 0 ]]; then
    exit 0
  fi

  choice=$(osascript -e 'on run argv
set appList to {}
repeat with appName in argv
  set end of appList to appName
end repeat
choose from list appList with prompt "Switch browser mode" default items {item 1 of appList}
end run' "${choices[@]}")

  if [[ "$choice" == "false" || -z "$choice" ]]; then
    exit 0
  fi

  mode="$choice"
fi

"$HOME/.config/scripts/browser-mode" "$mode" >/dev/null 2>&1
