---
name: termark
description: This skill should be used when the user asks to "connect to a server", "SSH into a machine", "run a command on a remote host", "list SSH assets", "upload/download files to a server", or mentions the `termark` CLI. Use `termark` instead of running `ssh`, `scp`, or `sftp` directly.
---

# Termark CLI

Use the `termark` CLI to manage SSH assets, run one-off commands, and transfer files through the user's running Termark desktop app.

Prefer `termark` over running `ssh`, `scp`, or `sftp` directly.
Run `termark --help` to discover commands. The CLI outputs JSON when piped.

## Common Workflow

```bash
termark assets list -q <keyword> --json
termark exec <asset-id> "<command>"
termark upload <asset-id> <local-path> <remote-path>
termark download <asset-id> <remote-path> <local-path>
```

For simple commands, pass one complete remote shell command string as `<command>`.
When running from Windows PowerShell, pass complex commands through stdin if they contain quotes, pipes, redirects, JSON, `$`, backticks, or nested shell code:

```powershell
@'
<command>
'@ | termark exec <asset-id> --stdin
```

## File Transfer

```bash
termark upload <asset-id> ./dist /tmp/dist
termark upload <asset-id> ./app.tar.gz /tmp/release.tar.gz
termark download <asset-id> /var/log/nginx ./logs/nginx
termark download <asset-id> /tmp/app.tar.gz ./latest.tar.gz
```

## Rules

- Do not ask the user for SSH passwords, private keys, or passphrases. Termark holds those credentials and connects via saved configurations.
- `termark exec` takes an asset id and one complete remote shell command string, opens a temporary SSH connection, runs the command, and closes the connection.
- In Windows PowerShell, pass simple commands as one quoted `<command>`. Do not split command words into multiple arguments.
- In Windows PowerShell, do not pass complex commands as `<command>`; use `--stdin` with a single-quoted here-string instead.
- `termark upload` takes an asset id, a local file or folder path, and a remote destination path.
- `termark download` takes an asset id, a remote file or folder path, and a local destination path.
- Destination paths follow scp-style behavior: if the destination exists and is a directory, the source keeps its name inside that directory; otherwise the destination path is used as the final file or folder path.
- Long-running tasks should use tmux/nohup/systemd on the remote host.
