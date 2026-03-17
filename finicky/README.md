# Finicky browser mode (macOS)

This setup uses Finicky as the system URL router and a Raycast Script Command to switch the active browser mode without modifying your click habits.

## Files

- `finicky/finicky.dia.js`: Always open links in Dia.
- `finicky/finicky.atlas.js`: Always open links in ChatGPT Atlas.
- `finicky/finicky.custom.js`: Generated on the fly when selecting other browsers.
- `~/.finicky.js`: Symlink pointing at the active config.
- `scripts/browser-mode`: Mode switcher and notification helper.
- `raycast/script-commands/browser-mode.sh`: Raycast entry that prompts for a browser.

## How switching works

1. `browser-mode` swaps the `~/.finicky.js` symlink to the chosen config.
2. It touches the symlink to signal a change.
3. If Finicky is already running, it receives `HUP` to reload configuration.
4. A system notification confirms the chosen mode.

## Raycast usage

1. Add the script directory: `~/.config/raycast/script-commands`.
2. Run **Browser Mode** in Raycast.
3. Pick a browser from the list.

## Adding a new browser

The Raycast script lists common browsers in `/Applications`. If your browser is installed elsewhere:

1. Pass its app name directly (e.g., `Browser Mode` → `MyBrowser`).
2. Or pass the bundle id (e.g., `com.vendor.browser`).

`browser-mode` resolves app names to bundle ids with `osascript` and generates `finicky/finicky.custom.js` automatically.

## Troubleshooting

- No notification: Ensure `terminal-notifier` is installed or allow notifications for Terminal/Raycast.
- Wrong app opens: Confirm the bundle id with `osascript -e 'id of app "App Name"'`.
- Changes not applied: Make sure Finicky is running so it can reload on `HUP`.
