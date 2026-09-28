# Windows Bootstrap Packages

**English** | [简体中文](windows-bootstrap-packages.zh-CN.md)

Per-item reference for the manifests consumed by [`windows-bootstrap/install.ps1`](../windows-bootstrap/install.ps1). The JSON files under [`windows-bootstrap/packages/`](../windows-bootstrap/packages/) are the source of truth; this page explains what each item installs and how it is verified.

Run order and group selection: `Base` → `Core` → `Optional`. `-Profile Base|Core|Optional|All` selects the subset; `-NoOptional` removes the optional group from `All`.

## Execution model

Every manifest item must define the full contract below, or the installer throws before running anything:

| Field | Purpose |
| --- | --- |
| `name` | Component name used in state and report |
| `mode` | `winget`, `wsl`, `font`, `rime`, `input-method`, `powershell-profile`, or `manual` |
| `version` | Version policy (`winget-latest-stable`, a pinned release, or `manual-review`) |
| `architecture` | `x64` or `all` |
| `silentInstallArgs` | Array of non-interactive arguments |
| `uninstallCommand` | `{ type, args }`; `{wingetId}` is replaced when the uninstall runs |
| `source` | Where the package comes from |
| `checksum` | Integrity/verification policy |
| `verification` | `{ type, ... }` verification metadata |
| `wingetId` | Required when `mode: winget` |
| `wingetSource` | Optional WinGet source override: `winget` (default) or `msstore` |
| `cleanupMode` | `winget-uninstall-if-new`, `owned-files-only`, `backup-restore`, or `manual` |
| `reason` | Required for `manual` items; recorded in the report |

Mode behavior:

- `winget` — `winget list --id <id> --exact` first. Already installed → `completed`, package left untouched. Otherwise `winget install --id <id> --exact --source <winget|msstore> <silentInstallArgs>`, then re-check with `winget list`. The source defaults to `winget`; `wingetSource: msstore` (or a `source: msstore:<productId>` prefix) selects the Microsoft Store source, used for Raycast. Existing packages are never uninstalled or upgraded.
- Failure cleanup — when an install fails after the package became registered, `cleanupMode: winget-uninstall-if-new` removes it immediately; the component result is `failed_cleaned` if removal succeeded, otherwise `failed_uncleaned`.
- `manual` — nothing is installed or downloaded. The item is recorded as `manual_required` with its `reason`, and the run continues.
- Non-WinGet modes are executed by dedicated bootstrap functions (WSL, font, RIME bridge, input method, managed profiles).

Post-run `final-verification` checks `git.exe`, `pwsh.exe`, `wt.exe`, a live WSL 2 Ubuntu, the managed PowerShell profile block, and live completion for the Font, Mint RIME, input-method, and profile components.

## Base group — `base.json`

| Item | WinGet ID | Silent arguments | Verified by | Cleanup |
| --- | --- | --- | --- | --- |
| Git | `Git.Git` | `--silent --accept-source-agreements --accept-package-agreements --disable-interactivity` | `winget list`; final check runs `git.exe --version` | uninstall-if-new |
| PowerShell 7 | `Microsoft.PowerShell` | same | `winget list`; final check requires `pwsh.exe` with major version ≥ 7 | uninstall-if-new |
| Windows Terminal | `Microsoft.WindowsTerminal` | same | `winget list`; final check runs `wt.exe --version` | uninstall-if-new |
| lazygit | `JesseDuffield.lazygit` | same | `winget list` | uninstall-if-new |

## Core group — `core.json`

| Item | Mode | Source / action | Verification | Cleanup |
| --- | --- | --- | --- | --- |
| WSL 2 + Ubuntu LTS | `wsl` | `wsl --install --distribution Ubuntu-24.04 --no-launch`, then default version 2 | `wsl --list --verbose`: Ubuntu distribution present with version 2 | manual — Windows servicing; if a reboot is required the bootstrap registers a one-time logon resume task and continues with `-Resume` |
| JetBrains Mono Nerd Font | `font` | pinned `v3.5.1` release archive, `sha256:fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e` | selected TTF files exist and each has its `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` registration | owned-files-only |
| Mint RIME | `rime` | runs `windows/install.ps1 -Profiles mint -InitialProfile mint -DeployMode Quiet -NoRaycast` | a fresh `install-report.json` written during this invocation (time window + SHA-256), a `completed` mint result, and the matching root/Junction | manual |
| Mint input method default | `input-method` | current-user language list | expected TIP (`0804:E02\d+0804`) present, English entry preserved, default input-method override set when the API is available | manual |
| PowerShell profiles | `powershell-profile` | [`windows-bootstrap/config/powershell/profile.ps1`](../windows-bootstrap/config/powershell/profile.ps1) managed block | exact managed block present in both Windows PowerShell 5.1 and PowerShell 7 profile files | backup-restore |

## Optional group — `optional.json`

WinGet items — same silent arguments, verify via `winget list`, cleanup `winget-uninstall-if-new`:

| Item | WinGet ID |
| --- | --- |
| Obsidian | `Obsidian.Obsidian` |
| Typora | `Typora.Typora` |
| Thunderbird | `Mozilla.Thunderbird` |
| Telegram | `Telegram.TelegramDesktop` |
| Spotify | `Spotify.Spotify` |
| Steam | `Valve.Steam` |
| PotPlayer | `Daum.PotPlayer` |
| CC-Switch | `farion1231.CC-Switch` |
| Clash Verge Rev | `ClashVergeRev.ClashVergeRev` |
| Zen Browser | `Zen-Team.Zen-Browser` |
| Raycast | `9PFXXSHC64H3` (Microsoft Store source) |
| Baidu Netdisk | `Baidu.BaiduNetdisk` |
| Quark Netdisk | `Alibaba.QuarkCloudDrive` |
| Eudic | `EuSoft.Eudic` |
| Geek Uninstaller | `GeekUninstaller.GeekUninstaller` |

Only `dwall` remains `manual_required` — never installed automatically; the report carries its reason:

| Item | Reason |
| --- | --- |
| dwall | No stable, reviewed unattended Windows package contract in the repository; its GitHub release installer is not yet a managed download |

## Changing the manifests

- Add every required contract field; `windows-bootstrap/tests/run.ps1` includes manifest-contract regression coverage (missing fields, unsupported architecture, missing WinGet ID).
- Promote a `manual` item to `winget` after its package ID, silent install, verification, and silent uninstall are all pinned and tested; use `wingetSource: msstore` for Microsoft Store-only products.
- Pinned release sources (like the font archive) must carry an exact URL and SHA-256; WinGet items rely on the WinGet source and signature checks.
