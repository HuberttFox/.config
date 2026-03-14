# terminal-rescue

## Purpose

This hook mitigates dirty terminal state after an abnormal disconnect in the chain:

`kitty -> tmux -> ssh -> opencode`

When SSH drops unexpectedly, the remote process may not have time to restore terminal modes before the shell regains control. The result is that mouse tracking, focus reporting, or bracketed paste can remain enabled in the current tmux pane.

Typical symptoms after returning to the shell:

- moving the mouse prints sequences such as `35;82;32M`
- focus or terminal queries print sequences such as `997;1n`
- the prompt itself is otherwise normal; the problem is leaked control sequences, not text corruption

## Current behavior

`terminal-rescue.zsh` registers a `precmd` hook in interactive zsh shells.

Before each prompt is shown, it sends this reset sequence:

```text
\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l
```

That disables:

- mouse tracking (`1000`, `1002`, `1003`, `1006`)
- focus reporting (`1004`)
- bracketed paste (`2004`)

This is a shell-side fallback. It does not fix the disconnect itself.

## What it solves

- repeated mouse/focus control sequences continuing to leak after returning to a shell prompt
- persistent dirty pane state that survives until the next prompt

## What it does not solve

- bytes already queued in the tty input buffer before the hook runs
- a fully broken line discipline (`stty` problems)
- alternate screen cleanup
- general terminal attribute reset beyond the modes above

Because `precmd` runs only when zsh is about to print a prompt, a small tail of already-buffered control bytes may still appear before the cleanup takes effect.

## Manual recovery

If the pane is already badly contaminated, use this one-shot recovery command:

```bash
printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l\033[?2004l'; stty sane; tput rmcup 2>/dev/null; tput sgr0; clear
```

If the current input line is garbled, press `Ctrl-C` first and then run the command.

## Future options

If the remaining tail of leaked bytes becomes annoying enough to address, the next candidate is a guarded stdin drain before prompt display. That would trade a cleaner recovery for a small risk of discarding user type-ahead input, so it is intentionally not enabled yet.
