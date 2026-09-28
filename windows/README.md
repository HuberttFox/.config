# Windows RIME profiles

[简体中文](README.zh-CN.md) | **English**

Windows-only RIME deployment for this repository. It installs one standard
Weasel `0.17.4` runtime and maintains isolated Ice, Mint, and Moqi user-data
profiles. It does **not** extend the repository's macOS/Homebrew bootstrap to
Windows.

For the broader unattended Windows bootstrap (WSL, WinGet packages, managed
profiles, fonts), see
[`../windows-bootstrap/README.md`](../windows-bootstrap/README.md).

All Windows RIME code requires **PowerShell 7 x64** (`pwsh.exe`) on Windows
11 x64. Existing Windows PowerShell 5.1 profiles are outside this feature,
are never edited, and cannot run these scripts.

## Prerequisites

- Windows 11 x64.
- A signed PowerShell 7 x64 `pwsh.exe` host. The ACL UAC fallback accepts only
  the current non-reparse executable when it exactly matches `$PSHOME\pwsh.exe`
  and has a valid Microsoft Authenticode signature; it never resolves `pwsh.exe`
  through `PATH`. The five Raycast wrappers and `bootstrap.sh` do launch
  `pwsh.exe` through `PATH`, because Windows has no enforced install location: a
  hostile earlier `PATH` entry could run attacker-chosen code in the current
  user context. That path never elevates; restrict `PATH` if that residual risk
  is unacceptable.
- An interactive user session. Do not run daily profile switching as `SYSTEM`,
  a scheduled task under another account, or an administrator account that is
  not the managed profile owner.
- Internet access only when a pinned Weasel or source archive is not already
  cached. Every downloaded archive is verified against
  [`manifests/rime.lock.json`](manifests/rime.lock.json).

The installer performs UAC operations only for the machine-level Weasel
installer and, when needed, the managed-root ACL fallback. Daily switches do
not elevate.

## Entrypoints

From PowerShell 7 on Windows:

```powershell
pwsh.exe -NoProfile -File .\windows\install.ps1
```

From Git Bash, MSYS2, or Cygwin on Windows:

```bash
./bootstrap.sh
```

`bootstrap.sh` dispatches to `windows/install.ps1` only from MINGW/MSYS/Cygwin.
On macOS it delegates to the existing `install.sh`; on Linux and WSL it exits
with status `2`. Run the Windows installer from the Windows host, not WSL.

Useful installation variants:

```powershell
# Install only Ice and Mint; choose Mint as initial active profile.
pwsh.exe -NoProfile -File .\windows\install.ps1 `
  -Profiles ice,mint -InitialProfile mint

# Install all profiles. Moqi Lite is the default.
pwsh.exe -NoProfile -File .\windows\install.ps1

# Explicitly select Moqi Full and use Weasel's quiet /deploy mode.
pwsh.exe -NoProfile -File .\windows\install.ps1 `
  -Profiles moqi -MoqiFull -DeployMode Quiet

# Create/update profiles without changing HKCU RimeUserDir or RimeConfig.
pwsh.exe -NoProfile -File .\windows\install.ps1 -SkipDeploy

# Adopt a known legacy layout only after a recovery backup is written.
pwsh.exe -NoProfile -File .\windows\install.ps1 -BackupLegacy
```

Other supported parameters include `-RimeRoot`, `-ConfigPath`,
`-CacheDirectory`, `-RaycastScriptDir`, `-WeaselInstallDirectory`,
`-SkipWeaselInstall`, `-NoRaycast`, and `-PassThru`. Use absolute local paths
for custom roots and cache locations.

`-MoqiFull` is deliberate. A managed Moqi Full profile is never silently
downgraded to Lite. Keep `-MoqiFull` for later updates or perform an explicit,
reviewed migration before returning to Lite.

## Managed layout and root selection

The resolved root has this shape:

```text
<RimeRoot>\
├── .config-rime-root.json       # manager and owner-SID marker
├── RimeConfig                   # Junction to exactly one profile
├── profiles\
│   ├── Rime_Ice\
│   ├── Rime_Mint\
│   └── Rime_Moqi\
├── state.json                   # switch journal
├── install-report.json
├── review-export\
└── switch.lock / install.lock
```

Root precedence is fixed:

1. `-RimeRoot`
2. `root` in the requested JSON config
3. Existing managed `HKCU\Software\Rime\Weasel\RimeUserDir` selector
4. A marked `D:\ProgramData\Rime`
5. `%LOCALAPPDATA%\RimeProfiles`

The canonical discovery config is `%LOCALAPPDATA%\config-rime\rime.json`.
Supplying `-ConfigPath` also writes the canonical config after validating that
both paths identify the same managed root. This lets thin control scripts and
Raycast wrappers find the root without arbitrary arguments.

The registry value is set once to `<RimeRoot>\RimeConfig`; normal switching
changes only that validated Junction target. The target must be one of the
three profile directories. Untrusted directories, symbolic links, Junction
parents, UNC/device paths, alternate streams, and targets outside the managed
layout are rejected.

## Profiles and dependency closure

| Profile | Active schema(s) | Source policy |
| --- | --- | --- |
| Ice | `rime_ice` | Pinned `iDvel/rime-ice` archive, including its active dictionaries, Lua, OpenCC, `melt_eng`, and `radical_pinyin` assets. |
| Mint | `rime_mint_flypy` | Pinned `Mintimate/oh-my-rime` archive, including its active dictionaries, Lua, OpenCC, `radical_pinyin`, `wubi98_mint`, `stroke`, and `melt_eng` assets. |
| Moqi Lite | `moqi_wan_flypymo`, `moqi_single_xh` | Pinned Moqi archive plus pinned Cangjie, Stroke, and official Luna Pinyin overlays. Lite generates `moqi_wan.lite` and omits Full-only large/cell dictionaries. |
| Moqi Full | same schemas | Same closure, with `moqi_wan.extended`, all selected `cn_dicts`, `cn_dicts_common`, and `cn_dicts_cell` resources. |

Moqi's pinned upstream archive already contains the exact
`radical_flypy`, reverse-lookup, emoji, Easy English, Japanese, Lua, and
Moqi-specific OpenCC assets consumed by its selected schemas. An additional
unreferenced radical-pinyin archive is intentionally not fetched. Cangjie and
Stroke require `luna_quanpin` and `luna_pinyin`, so the installer overlays a
separately pinned official `rime/rime-luna-pinyin` archive. Do not rely on
Weasel shared data for Luna schemas or dictionaries.

Weasel's machine runtime owns its shared data directory. Managed profiles only
copy source-specific configuration; the installer never copies a second Weasel
runtime or stores downloaded upstream source trees in this repository.

## Switching and status

The installer copies control scripts and their libraries to:

```text
%LOCALAPPDATA%\config-rime\scripts
```

Examples:

```powershell
$control = "$env:LOCALAPPDATA\config-rime\scripts\rime-switch.ps1"

pwsh.exe -NoProfile -File $control -Status
pwsh.exe -NoProfile -File $control -Profile ice
pwsh.exe -NoProfile -File $control -Profile mint
pwsh.exe -NoProfile -File $control -Profile moqi
pwsh.exe -NoProfile -File $control -Toggle

# Record a requested action without runtime discovery or selector mutation.
pwsh.exe -NoProfile -File $control -Profile ice -NoDeploy
```

`-Status` is read-only and does not discover or start Weasel. A real switch:

1. Takes the exclusive root lock and recovers any pending selector backup.
   A user-invoked switch also takes `install.lock`, so it cannot run
   concurrently with `windows/install.ps1`, which rewrites profiles and the
   Registry selector.
2. Validates the owner SID, active target, and requested profile.
3. Journals `switching`, snapshots build artifacts, and stops only matching
   `WeaselServer.exe` processes (exact install path, initiating SID, session,
   and process start time). It never invokes Weasel's username-wide named-pipe
   shutdown; it uses a revalidated PID's `CloseMainWindow()` and only then a
   revalidated forced stop after timeout.
4. Renames the old Junction into a transaction backup, creates the new
   Junction, deploys, and verifies fresh required schema/table/prism artifacts.
5. Writes `completed` state, then removes the selector backup.

On failure, it restores the previous selector when one existed; on a first-time
switch it clears only the selector created by that transaction. If stopping was
attempted, it restarts the previous runtime after rollback. The installer also
snapshots the exact prior Registry property state (`Exists` plus raw value).
A failed switch with a verified Registry rollback is reported as `failed`; a
rollback error or read-back mismatch is reported as `recovery_required` and
exits nonzero. Leave `.RimeConfig.<transaction>.previous`, `state.json`, and
registry evidence alone: the next managed switch performs Junction recovery
under the lock, while a registry `recovery_required` result needs review.

Interactive deployment is the default. It opens Weasel deployment without
arguments and waits up to 600 seconds. `-DeployMode Quiet` uses `/deploy`.
GUI appearance is not success; required generated artifacts must be fresh.

## Raycast wrappers

Five wrappers live in [`raycast/`](raycast/): Ice, Mint, Moqi, Toggle, and
Status. If `-RaycastScriptDir` names an existing Raycast script directory, the
installer copies only its managed wrappers there. Otherwise it reports
`manual_required`; profile installation remains intact.

Each wrapper calls the installed control script with fixed arguments. It does
not forward `%*`, accept arbitrary transaction arguments, or contain Junction
logic.

## Review-only text export

Export is intentionally narrow:

```powershell
$export = "$env:LOCALAPPDATA\config-rime\scripts\rime-userdata.ps1"
pwsh.exe -NoProfile -File $export `
  -Files 'custom_phrase/personal.txt','personal.custom.yaml'
```

Only explicitly named `custom_phrase/*.txt` and top-level `*.custom.yaml`
files are copied into a new review directory. User databases, compiled tables,
`build/`, binaries, and opaque profile state are refused. Export never merges
or imports data back into a profile.

## Legacy adoption and safety

An unmarked legacy `Rime_Ice`, `Rime_Mint`, or `Rime_Moqi` layout requires
`-BackupLegacy`. The backup is created and validated before profile copying.
Unknown legacy data, ordinary `RimeConfig` directories, foreign Junction
paths, edited managed files, and conflicting profile copies fail closed rather
than being overwritten or recursively removed.

Managed ownership is recorded in JSON markers: `.config-rime-root.json` for
the root, and `.config-rime-profile.json`, `managed-files.json`,
`.config-rime-control.json`, or `.config-rime-raycast.json` for each managed
directory. A manifest that is missing the `config-rime` marker, carries an
invalid entry, points outside its directory, or changes while it is read is
rejected before any copy or delete. Together with the change hashes, this is
what authorises removal of a stale managed file; without it a forged manifest
could name arbitrary files.

Staging, legacy-backup, and review-export copies always create a new
destination: a destination that already exists, or that appears between
validation and the write, fails closed instead of being overwritten. Control
scripts and Raycast wrappers instead go through the managed manifest: an
unmodified owned file is replaced under its recorded change hash, while a
user-edited file is preserved and reported as `manual_required`. When a profile
is staged, the main archive is copied first and declared overlays are
applied in order, so a later overlay wins a path collision; collisions are
resolved before any file is written. Failed or superseded temporary artifacts
(unique `.tmp` and `.download` files, unmarked staging directories) are
deliberately left in place, because no handle-relative identity check can prove
they are still ours.

Profile updates preserve user dictionaries, generated state, and user-edited
managed files. Conflicts are reported as `manual_required` instead of being
silently replaced. Managed source/target ancestors are checked for reparse
points again immediately before copy, delete, write, extraction, staging,
control-script, and export operations. This narrows detectable swaps but does
not eliminate the remaining syscall check-to-use window; handle-relative
no-follow protection is still a Windows-native security blocker.

## Validation boundary

A Windows 11 agent taking over native acceptance should start from
[`../docs/handoff-windows-rime-native-acceptance.md`](../docs/handoff-windows-rime-native-acceptance.md):
it carries the file-integrity manifest, the gate commands, the scratch-root
protocol, and the list of claims that are still unverified. Executed results
are recorded in
[`../docs/handoff-windows-rime-native-acceptance-evidence.md`](../docs/handoff-windows-rime-native-acceptance-evidence.md).

Portable checks are safe on non-Windows hosts:

```powershell
pwsh -NoProfile -File .\tests\windows\run.ps1
```

Portable `tests/windows/run.ps1` prints separate passed, failed, and skipped
counts and exits nonzero on any failure. A case that cannot build its
symbolic-link fixture reports `SKIP`, not `PASS`; a run with skips has not
verified the reparse cases. Verify that `pwsh` was available and that the skip
count is zero before treating a run as evidence.

They do not perform Registry, UAC, installer, process, live Junction, DISM,
WSL, scheduled-task, reboot, or input-method operations. Before relying on
this on a machine, complete the Windows 11 x64 acceptance checklist in
[architecture.md](../docs/architecture.md#native-windows-acceptance). Portable
tests do not certify NTFS Junction behavior, ACLs, HKCU/HKLM views, deployment,
process isolation, residual reparse-race behavior, or Raycast execution.
