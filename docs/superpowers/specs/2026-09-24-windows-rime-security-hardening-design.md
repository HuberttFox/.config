# Windows RIME security hardening design

## Purpose

Repair verified independent-review findings in the uncommitted Windows RIME implementation without changing the three-profile model, macOS installer, or user-data ownership rules. The target remains Windows 11 x64 with PowerShell 7 x64. This document is design-only: no implementation, commit, or push is authorized by it.

## Fixed constraints

- One Weasel `0.17.4` runtime; Ice, Mint, and Moqi profiles remain isolated under one managed root.
- Moqi remains Lite by default; Full remains explicit through `-MoqiFull` and never silently downgrades.
- New Windows RIME scripts require `#requires -Version 7.0`; existing Windows PowerShell 5.1 profiles remain untouched.
- Daily actions run only as managed initiating user, never `SYSTEM`, another SID, or an unowned root.
- Tests never perform live Registry, UAC, Weasel installation/deployment, input-method, scheduled-task, reboot, or production Junction/ACL mutation.
- Portable tests prove pure logic and controlled temporary-directory behavior only. Windows-native behavior remains a separate release gate.
- No commit or push during implementation. Beads issue `my-brain-29h` remains the sole progress ledger.

> Amendment (2026-09-24): after the hardening round and its independent review completed, the user authorized committing and pushing the uncommitted Windows RIME work. The design and plan below are unchanged by that authorization; only the "no commit/push" execution constraint was lifted.

## Findings and disposition

| Finding | Decision |
| --- | --- |
| UAC ACL fallback resolves `pwsh.exe` through `PATH` | Fix now. Launch only a validated current PowerShell 7 executable path, never `Get-Command` or PATH lookup. |
| Registry selector rollback error is swallowed | Fix now. Snapshot property existence/value, restore exactly, read back, and record `recovery_required` on failed or unverifiable rollback. |
| Weasel `/quit` uses user-name named-pipe IPC rather than PID/SID/session scoped IPC | Fix now. Do not invoke `/quit`; use only selected, revalidated process objects. Try PID-scoped `CloseMainWindow()` where available; then force-stop only freshly revalidated matching PIDs. |
| Host assertion accepts Windows 10 | Fix now. Require a Windows 11 product identity, build >= `22000`, x64 OS, and x64 PowerShell 7 process. |
| Moqi stage identity omits archive SHA/pattern rules/stage format | Fix now. Version the stage format and hash all lock identity fields plus ordered main/overlay patterns and Lite/Full variant. |
| Control/Raycast failures bypass install report | Fix now. Convert each component exception into a report result; preserve previously completed/failed results; top-level return and exit semantics derive from report. |
| Daily public scripts omit x64-process assertion | Fix now. Share one PowerShell-7-x64 assertion and call it before root/Registry discovery in both scripts. |
| Documentation divergence | Fix now. Correct 5.1 wording, relative links, add Chinese Windows guide, and link Windows contract from root/docs/architecture/troubleshooting/guidelines. |
| File-operation reparse TOCTOU | Partially mitigate now; retain as native-security acceptance blocker. Revalidate source/target parent chain immediately before every managed copy/delete/write. A complete handle-relative no-follow implementation needs a dedicated Windows-native interop design and cannot be honestly certified by portable tests. |

## Architecture

### Trusted elevated PowerShell host

`Invoke-RimeElevatedRootAcl` receives a path from a new `Get-RimeTrustedPowerShellHost` helper. The helper derives the executable from the current process and `$PSHOME`, not `PATH`; normalizes it; requires leaf name `pwsh.exe`; rejects reparse paths; confirms it is the currently running PowerShell executable; and, on Windows, requires a valid Authenticode signature from Microsoft. The UAC payload continues to independently validate root and SID.

The helper is intentionally narrow. It does not choose a secondary installed PowerShell, inspect `PATH`, or accept a caller-provided executable. If validation cannot establish a trusted launcher, ACL fallback fails before elevation.

### Windows 11 and PowerShell process contract

`Get-RimeWindowsHostInfo` reads platform, product name, build, OS architecture, process architecture, and PowerShell major version behind mockable helpers. `Assert-RimeWindowsHost` requires Windows 11 product identity and build `>=22000` on x64 OS. `Assert-RimePowerShell7X64` adds PS major `>=7` and x64 process checks. Installer and public scripts invoke both before any Registry/root discovery.

`#requires -Version 7.0` remains a parser-level guard; runtime assertions provide clear errors and prevent a 32-bit host from using wrong Registry views.

### Registry snapshot and recovery

The install path snapshots `RimeUserDir` as `{ Exists, Value }`, not only a nullable string. Restore performs the inverse operation: exact raw value when it existed, otherwise remove exactly that property. It then re-reads state and compares existence/value. When profile switching fails, registry restore failure or mismatch becomes a `switch: recovery_required` result with both original switch error and rollback error. It must not claim ordinary `failed` state after incomplete recovery.

This behavior is exposed through small testable helpers so tests can simulate set, remove, read-back, and restore errors without touching HKCU.

### Process stopping

Weasel 0.17.4 `/quit` connects to `\\.\pipe\<username>\WeaselNamedPipe`; source review shows no PID, SID, or session selector. Calling it is therefore unsafe in a multi-session/user environment.

`Get-RimeMatchingServerProcesses` records process ID, normalized executable path, SID, session, and start time. Before each action, a helper reacquires that PID and compares all identity fields, preventing PID reuse from widening the target set. `Stop-RimeWeasel` calls `CloseMainWindow()` only on those verified process objects when a window exists. It waits, then invokes forced termination only on a newly enumerated matching set. It never launches `WeaselServer.exe /quit`.

Windows-native acceptance must cover two user SIDs/sessions sharing an install directory and prove no unselected server stops.

### Cache-stage identity

Moqi stage identity is a hash over a canonical ordered list:

1. literal stage-format version, e.g. `moqi-stage-v3`;
2. for main Moqi and every overlay: repository, commit, URL, SHA-256;
3. ordered main patterns;
4. each overlay name plus ordered overlay patterns;
5. `lite` or `full`.

A changed lock SHA, URL, selection rule, overlay rule, stage format, dependency pin, or variant produces a different stage directory. Existing content manifests still detect tampering within one identity.

### Install report boundary

Runtime, each profile, selector switch, control-script installation, and Raycast installation each execute behind result-recording boundaries. A component error becomes one result containing its error. The report is saved in `finally`; `-PassThru` returns it; outer exit is nonzero if any result is `failed` or `recovery_required`. Components not reached after a fatal precondition remain absent rather than falsely marked complete.

### Reparse TOCTOU scope

Existing path checks run before traversal. This change adds final immediate checks before source reads, destination-parent creation, file replacement, file deletion, temporary JSON replacement, archive extraction writes, and export copies. It narrows detectable races and makes injected reparse swaps fail closed in controlled tests.

It does **not** eliminate the tiny interval between final check and Windows file system operation. Full elimination needs directory-handle-relative APIs with no-follow semantics across every ancestor and explicit final object identity verification. That work remains outside this hardening increment and stays listed as a Windows-native blocker. Documentation must say this plainly.

### Managed ownership and exclusive creation

Deletion authority comes from a marker, not from a path. `managed-files.json`,
`.config-rime-control.json`, and `.config-rime-raycast.json` must declare
`manager: config-rime`; the manifest must live in the destination directory it
describes; every entry must be a safe relative path with a lowercase SHA-256;
duplicate entries are rejected; and the manifest's own hash is captured before
and after parsing so a change during the read fails the run. Only a change hash
recorded by an owned manifest authorises replacing or deleting a file, so a
forged or legacy manifest cannot name arbitrary files for removal.

Updates follow one of three shapes: an absent destination is created with
`CreateNew`; an owned destination is copied to a unique temporary file, hash
verified, then swapped with `File.Replace` after a second ownership check; a
destination whose hash no longer matches its recorded owner becomes a conflict,
keeps its previous manifest entry, and its temporary file is left in place.
Selected, staging, backup, and export copies are `CreateNew` only and never
overwrite. When a path collision occurs across staged sources, the main source
is copied first and each declared overlay is applied in order, so the last
declared overlay wins; the winner is chosen during planning, before any write.

Artifacts that cannot be proven ours are preserved rather than cleaned up:
unique `.tmp` and `.download` failures, unmarked cache or staging collisions,
and replaced paths. This is a deliberate trade of disk residue for not deleting
something we cannot identify.

## Test design

Portable `tests/windows/run.ps1` gains deterministic unit/regression cases for:

- malicious `PATH` candidate cannot influence trusted pwsh path;
- invalid current process host/signature/path is rejected before `Start-Process`;
- Windows 10 and x86 PowerShell rejected; Windows 11 x64 PowerShell 7 accepted via mocked host facts;
- public control scripts call shared x64 assertion before Registry discovery;
- failed selector switch plus failed registry restore yields persisted `recovery_required` evidence;
- restore of missing original registry property verifies absence;
- no `/quit` launch exists and selected PID identity is revalidated before close/force actions;
- stage identities differ when SHA, URL, stage format, main pattern, overlay pattern, dependency pin, or variant changes;
- production Moqi source-root path rebuilds a distinct stage after selection/lock identity changes;
- control and Raycast exceptions become report records while earlier records survive;
- a test hook or controlled reparse swap before final operation is detected before copy/delete;
- a selected, staging, or export copy refuses a destination that appears after validation;
- a forged or unowned manifest cannot authorise replacing or deleting any file;
- a manifest that changes while it is read or while it is updated fails the run;
- an overlay path collision resolves to the last declared overlay before any write;
- a generated artifact replaced between its verification reads is preserved;
- an existing selector whose Junction target is outside the managed profiles is never moved into a transaction backup.

PowerShell parser tests and Bash bootstrap/integration tests remain separate gates. Windows-native tests are specified but not claimed as run here.

## Documentation contract

Add `windows/README.zh-CN.md`; fix the English README native-acceptance relative link; make plan wording PowerShell 7 x64; add Windows RIME links and scope statements to root README, Chinese root README, docs indexes, architecture, troubleshooting, `AGENTS.md`, and `CLAUDE.md`. Architecture includes a dedicated native acceptance checklist for host version, UAC launcher provenance, registry rollback, multi-session stopping, Junction transaction recovery, reparse race, deployment artifacts, Lite/Full migration, and Raycast execution.

## Success criteria

- Every review finding marked “Fix now” has a prior failing regression test, minimal implementation, and fresh green portable suite once PowerShell 7 is available.
- No elevated PowerShell executable comes from `PATH`.
- Selector rollback cannot be silently reported as ordinary failure.
- No code invokes broad Weasel `/quit` IPC.
- Windows 10/x86 host paths reject before mutation.
- Cache changes invalidate stale Moqi stages deterministically.
- Partial install failures persist in report.
- Documentation accurately distinguishes portable evidence from Windows-native acceptance.
- Reparse race mitigation is explicitly bounded; no claim of complete handle-level protection without native proof.
- No file is replaced or deleted unless an owned manifest records its previous hash and the hash still matches at the moment of the operation.
- No staging, backup, control, or export copy can overwrite an existing destination, including one that appears after validation.
