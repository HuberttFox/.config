# CLAUDE.md

This repository's macOS bootstrap guidance lives in [AGENTS.md](AGENTS.md).

## Windows contract

Two Windows features are separate from macOS `install.sh`:

- `windows-bootstrap/` — unattended Windows 11 x64 bootstrap; supports Windows
  PowerShell 5.1 and PowerShell 7; scripts declare `#requires -Version 5.1`.
  `-DryRun` stays mutation-free; component failures continue with explicit
  outcomes (`completed`, `failed`, `failed_uncleaned`, `recovery_required`,
  `manual_required`); cleanup touches only current-run owned paths. Mutating
  operations request UAC elevation when the window is not elevated;
  `-DryRun`/`-Report` never elevate. Progress lines and a `Write-Progress`
  bar are standard, child output streams into `logs\bootstrap.log`, and
  `-Quiet`/`-NoProgress` reduce console output.
- `windows/` — RIME deployment targeting Windows 11 x64 and signed PowerShell 7
  x64 (`pwsh.exe`); existing Windows PowerShell 5.1 profiles remain untouched
  and unsupported by new RIME scripts.

- Every new Windows RIME `.ps1` starts with `#requires -Version 7.0` on line 1.
- Daily operations run only as managed marker-owner SID, never `SYSTEM`,
  another user, or a 32-bit PowerShell process.
- Tests never run live Registry, UAC, ACL, Junction, Weasel installer/deploy/
  process, DISM, WSL, scheduled-task, reboot, or input-method operations.
- Portable evidence proves only pure logic and controlled temporary-directory
  behavior. Never call it Windows-native Registry, ACL, Junction, Weasel,
  process-isolation, reparse-race, or Raycast acceptance.
- Final path checks narrow reparse races but do not provide handle-level
  no-follow protection. Preserve that residual Windows-native blocker.

Run `windows-bootstrap/tests/run.ps1` under both Windows PowerShell 5.1 and
PowerShell 7, plus the Windows RIME suite and parser with PowerShell 7, then
`./tests/bootstrap.sh`, `./tests/integration.sh`, shell syntax checks, JSON
validation, and explicit untracked-file whitespace checks listed in
[AGENTS.md](AGENTS.md). If `pwsh` is unavailable, record the exact failure; do
not claim PowerShell tests or parser passed.
