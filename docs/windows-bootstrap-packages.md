# Windows Bootstrap Packages

**English** | [简体中文](windows-bootstrap-packages.zh-CN.md)

Per-item reference for the manifests consumed by [`windows-bootstrap/install.ps1`](../windows-bootstrap/install.ps1). The JSON files under [`windows-bootstrap/packages/`](../windows-bootstrap/packages/) are the source of truth; this page explains what each item installs and how it is verified.

Run order and group selection: `Base` → `Core` → `Optional`. `-Profile Base|Core|Optional|All` selects the subset; `-NoOptional` removes the optional group from `All`.

External `format: 2` manifests are not built-in package manifests and cannot be
mixed into these groups. They use `-Profile Extension`, an explicit plan hash
approval, repository-owned providers, and a protected UAC/Resume snapshot. See
[Windows Bootstrap Extensions](windows-bootstrap-extensions.md).

## Execution model

Every manifest item must define the full contract below, or the installer throws before running anything:

| Field | Purpose |
| --- | --- |
| `name` | Component name used in state and report |
| `mode` | `winget`, `download`, `portable-handoff`, `wsl`, `font`, `rime`, `input-method`, `powershell-profile`, or `manual` |
| `version` | Version policy (`winget-latest-stable`, a pinned release, or `manual-review`) |
| `architecture` | `x64` or `all` |
| `silentInstallArgs` | Array of non-interactive arguments |
| `uninstallCommand` | `{ type, args }`; `{wingetId}` is replaced when the uninstall runs |
| `source` | Where the package comes from |
| `checksum` | Integrity/verification policy |
| `verification` | `{ type, ... }` verification metadata |
| `wingetId` | Required when `mode: winget`; retained as reference metadata for a controlled portable handoff |
| `wingetSource` | Optional WinGet source override: `winget` (default) or `msstore` |
| `url` | Required for `mode: download` and `mode: portable-handoff`; exact HTTPS artifact URL |
| `installerType` | Metadata only (`nsis`, `inno`, ...); the silent switches live in `silentInstallArgs` |
| `installLocation` | Preferred absolute install directory (e.g. `D:\Program Files\Git`); used with WinGet `--location` when the drive policy prefers D: |
| `locationSupport` | `inno`, `msi`, `nsis`, `exe`, `portable`, or `none`; `none` disables `--location` for the item |
| `locationProbe` | Relative file checked under the attempted and fallback directories to report the actual location |
| `cleanupMode` | `winget-uninstall-if-new`, `owned-files-only`, `backup-restore`, or `manual` |
| `executionContext` | `elevated` (default) or `user`; user-scoped items run before UAC and are imported through a SID/run-ID-bound handoff |
| `portableDirectory` | Required for `portable-handoff`; safe relative directory under `-PortableAppsRoot` |
| `reason` | Required for `manual` items; portable-handoff reasons describe the non-automated GUI boundary |

Mode behavior:

- `winget` — `winget list --id <id> --exact` first. Already installed → `completed`, package left untouched. Otherwise `winget install --id <id> --exact --source <winget|msstore> <silentInstallArgs>`, then re-check with `winget list`. The source defaults to `winget`; `wingetSource: msstore` (or a `source: msstore:<productId>` prefix) selects the Microsoft Store source, used for Raycast. Existing packages are never uninstalled or upgraded.
- Failure cleanup — when an install fails after the package became registered, `cleanupMode: winget-uninstall-if-new` removes it immediately; the component result is `failed_cleaned` if removal succeeded, otherwise `failed_uncleaned`.
- Timeout — WinGet installs and uninstalls run under bounded timeouts (900 s install, 300 s uninstall). A stalled process tree is killed and recorded as a failure instead of blocking the run.
- `download` — pinned direct download. The installer runs with `silentInstallArgs` under a 900 s timeout, then the component polls the uninstall registry for up to 60 s. On failure, `cleanupMode: download-uninstall-if-new` runs the registered uninstaller; an incomplete attempt is kept in the failed list so `-CleanupFailed` can retry.
- `portable-handoff` — normal-user phase downloads the pinned HTTPS PortableApps artifact, checks SHA-256, and records `manual_required`. It never invokes an unverified silent switch. `-LaunchPortableHandoff -PortableAppsRoot <root>` explicitly opens the verified interactive installer; after the user finishes it, `-ConfirmPortableHandoff -PortableAppsRoot <root>` requires the expected launcher and core executable before a `completed` result is possible. Download cache is under the current user's `%LOCALAPPDATA%\WindowsBootstrap\UserPhase\<runId>` and cleanup never removes the selected PortableApps destination.
- `manual` — nothing is installed or downloaded. The item is recorded as `manual_required` with its `reason`, and the run continues.
- Normal-user phase — a non-elevated `Run`/`Resume` first runs only manifest items with `executionContext: user`, then starts the administrator child. The source phase must be non-admin, session ≥1, and Medium Mandatory Level; the handoff root and file must have protected owner-and-SYSTEM-only DACLs. The child requires the current SID, run ID, profile, fresh timestamp, exact result set, and a canonical SHA-256 fingerprint of every selected manifest item, then live-verifies Spotify with `winget list` before recording success. Starting already elevated cannot downgrade its token, so user-context items remain `manual_required` rather than being run incorrectly.
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
| Typora | `appmakes.Typora` |
| Thunderbird | `Mozilla.Thunderbird` |
| Telegram | `Telegram.TelegramDesktop` |
| Steam | `Valve.Steam` |
| CC-Switch | `farion1231.CC-Switch` |
| Clash Verge Rev | `ClashVergeRev.ClashVergeRev` |
| Zen Browser | `Zen-Team.Zen-Browser` |
| Raycast | `9PFXXSHC64H3` (Microsoft Store source) |
| Baidu Netdisk | `Baidu.BaiduNetdisk` |
| Quark Netdisk | `Alibaba.QuarkCloudDrive` |
| Eudic | `EuSoft.Eudic` |
| Visual Studio Code | `Microsoft.VisualStudioCode` |
| PyCharm Community Edition | `JetBrains.PyCharm.Community` |
| Firefox | `Mozilla.Firefox` |
| Microsoft Edge | `Microsoft.Edge` |
| Google Chrome | `Google.Chrome` |
| Python 3.14 | `Python.Python.3.14` |
| 7-Zip | `7zip.7zip` |
| Notepad4 | `zufuliu.notepad4` ([GitHub](https://github.com/zufuliu/notepad4)) |
| SumatraPDF | `SumatraPDF.SumatraPDF` ([GitHub](https://github.com/sumatrapdfreader/sumatrapdf)) |
| Quicker | `LiErHeXun.Quicker` |
| PixPin | `PixPin.PixPin` |
| Geek Uninstaller | `GeekUninstaller.GeekUninstaller` |
| Spotify | `Spotify.Spotify` — normal-user phase only, `--scope user` |

## Normal-user special items

| Item | Mode / source | Default result | Completion boundary |
| --- | --- | --- | --- |
| Spotify | `winget:Spotify.Spotify`, `--scope user` | `completed` only after normal-user install and elevated `winget list` recheck | Must begin from a normal, medium-integrity desktop terminal. The WinGet installer rejects an administrator token. |
| PotPlayer | `portable-handoff`, PortableApps.com `PotPlayerPortable_1.7.22980.paf.exe` | `manual_required` after download + SHA-256 check | No silent extraction is claimed. User explicitly launches the verified GUI installer, chooses a destination below `-PortableAppsRoot`, then explicitly confirms a launcher/core-EXE layout check. |

PotPlayer's official `Daum.PotPlayer` WinGet/NSIS route remains excluded from automation: guest testing stalled with `/S` and override arguments. The PortableApps.com page states that its package is made with publisher permission and publishes SHA-256 `9c6b0364be94af7bbd117dd05df7485dfd965ee8785e44af6a0129c745f21913`; the bootstrap pins both the direct HTTPS URL and that hash. This is a controlled interactive handoff, not a claim of first-party portable distribution or unattended installation.

Commands for the explicit PotPlayer handoff (run from a normal, non-elevated desktop terminal):

```powershell
# Download and verify only; installer is not launched.
.\windows-bootstrap\install.ps1 -Profile Optional -PortableAppsRoot 'D:\PortableApps'

# Explicitly open verified GUI installer. Choose D:\PortableApps\PotPlayerPortable in its UI.
.\windows-bootstrap\install.ps1 -Profile Optional -PortableAppsRoot 'D:\PortableApps' -LaunchPortableHandoff

# After the installer exits, verify launcher/core files and record completion.
.\windows-bootstrap\install.ps1 -Profile Optional -PortableAppsRoot 'D:\PortableApps' -ConfirmPortableHandoff
```

## Pinned download item — `dwall`

| Item | Version | URL | SHA-256 | Silent args | Verification | Cleanup |
| --- | --- | --- | --- | --- | --- | --- |
| dwall | 0.2.5 | `https://github.com/dwall-rs/dwall/releases/download/v0.2.5/Dwall.Settings_0.2.5_x64-setup.exe` | `sha256:c448c0d28843523f6121d9edff7d03dd74f422b83f97d0de42b3087f3a182fee` | `/S` | uninstall-registry entry `Dwall Settings` | download-uninstall-if-new |

## Install location policy

When `D:` is a local fixed disk (`DriveType 3`) with at least 10 GB free, items that declare `installLocation` are attempted there through WinGet `--location`; otherwise the same relative path on the system drive is used. Installers that ignore the request still install normally, and the run records `attemptedLocation` plus, when `locationProbe` matches, `actualLocation` — the report never claims a move that did not happen. Git, Visual Studio Code, PyCharm Community Edition, Firefox, 7-Zip, Notepad4, SumatraPDF, Quicker, and PixPin are verified pilots for this behavior.

Machine scope remains necessary for the Git, Visual Studio Code, and PyCharm installers; the other location-preference entries use their source-specific, guest-tested scope contracts. Guest verification resolved the listed pilots under `D:\Program Files\...`. Chrome ignored the requested location and Python's Burn installer rewrote it during probing, so neither declares `installLocation`; Edge remains at its Windows-managed default location.

## Changing the manifests

- Add every required contract field; `windows-bootstrap/tests/run.ps1` includes manifest-contract regression coverage (missing fields, unsupported architecture, missing WinGet ID).
- Promote a `manual` item to `winget` after its package ID, silent install, verification, and silent uninstall are all pinned and tested; use `wingetSource: msstore` for Microsoft Store-only products. User-scope packages must declare `executionContext: user` and `--scope user`; do not try to reverse UAC from an elevated process.
- Direct-download items require an HTTPS `url`, a `sha256:` checksum, a `registry-uninstall` uninstall contract, and an `uninstall-registry` verification display name; the suite covers the contract and command-line parsing.
- A `portable-handoff` requires HTTPS, pinned SHA-256, `executionContext: user`, `uninstallCommand.type: manual`, a safe relative `portableDirectory`, and safe relative launcher/core-executable layout paths. It must not gain silent arguments unless a repeatable unattended installer contract is independently accepted.
- Pinned release sources (like the font archive) must carry an exact URL and SHA-256; WinGet items rely on the WinGet source and signature checks.
