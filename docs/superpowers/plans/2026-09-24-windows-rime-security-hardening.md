# Windows RIME security hardening implementation plan

> **For agentic workers:** Follow this plan task-by-task. Use `my-brain-29h` in Beads as the only status ledger; do not create Markdown task tracking, commit, or push. Implement with test-first cycles and request a fresh read-only review after code and documentation gates.

**Goal:** Close verified Windows RIME security, recovery, cache, reporting, host-contract, and documentation gaps while preserving the one-runtime, three-profile design.

**Architecture:** Keep policy and portable logic in `Rime.Core.ps1` / `Rime.Install.ps1`; keep Registry, UAC, process, host, and Junction behavior in `Rime.Windows.ps1`; retain `windows/install.ps1` as thin orchestration. Add narrowly testable helpers rather than widening the public CLI. Reparse protection gets final-operation revalidation now; complete handle-relative no-follow protection remains a separately documented Windows-native blocker.

**Tech stack:** PowerShell 7 x64, Windows Registry/ACL/Junction APIs, .NET file APIs, JSON lock manifests, Bash bootstrap tests, Windows 11 x64 native acceptance.

**Spec:** `docs/superpowers/specs/2026-09-24-windows-rime-security-hardening-design.md`

## Global constraints

- Target only Windows 11 x64 and PowerShell 7 x64 (`pwsh.exe`); leave existing Windows PowerShell 5.1 profiles unchanged.
- Preserve one Weasel `0.17.4` runtime, isolated Ice/Mint/Moqi profiles, fixed `RimeConfig` Junction selector, Lite-by-default Moqi, and explicit Full-only migration.
- No new RIME script may omit `#requires -Version 7.0` as its first line.
- Never run live Registry, UAC, installer, input-method, deployment, scheduled-task, reboot, or production Junction/ACL actions in tests.
- Never use `Get-Command pwsh.exe`, PATH lookup, `%*`, broad `/quit` IPC, or unfiltered process-name termination in privileged or daily-control paths.
- Preserve user-owned files; only delete exact verified managed artifacts.
- Keep `bootstrap.sh` Darwin behavior unchanged and Linux/WSL rejection intact.
- Do not commit or push during implementation. Do not initialize Beads in this checkout. Update only `/Users/shiujenyu/my-brain` issue `my-brain-29h` after verified evidence.

> Amendment (2026-09-24): the user later authorized committing and pushing the Windows RIME work. The window opened only after the fix pass finished; the PowerShell suite and Windows-native acceptance are still unrun, so this is not a verification claim.
- Portable macOS/Linux PowerShell evidence, if available, does not certify Windows-native behavior.

## Review focus

1. A user-controlled earlier PATH entry named `pwsh.exe` must never become the elevated UAC executable.
2. A selector write followed by failed profile switch and failed Registry restore must persist `recovery_required`, not conceal recovery loss.
3. A second user/session Weasel server using the same runtime directory must never receive a broad shutdown request.
4. Existing Moqi stage cache must rebuild when lock bytes, URL, source/overlay rules, stage format, or variant changes.
5. A reparse point inserted after planning but before a managed write/delete must be detected at the final check; the remaining syscall race must remain explicit in native acceptance documentation.

## Execution sequence

### Task 1: Establish red regression cases and shared test seams

**Files:**

- Modify: `tests/windows/run.ps1`
- Inspect while editing: `windows/lib/Rime.Windows.ps1`, `windows/lib/Rime.Install.ps1`, `windows/install.ps1`, `windows/scripts/rime-switch.ps1`, `windows/scripts/rime-userdata.ps1`

**Interfaces to introduce through tests:**

```powershell
Get-RimeWindowsHostInfo
Assert-RimeWindowsHost
Assert-RimePowerShell7X64
Get-RimeTrustedPowerShellHost
Get-RimeWeaselUserDirectorySnapshot
Restore-RimeWeaselUserDirectorySnapshot
Get-RimeMoqiStageIdentityParts
Get-RimeVerifiedServerProcess
```

**Red cases to add before production edits:**

```powershell
Case 'trusted elevated PowerShell ignores PATH and requires current signed pwsh host' {
    # Override host-info/signer seams. Set a hostile $env:PATH containing fake\pwsh.exe.
    # Assert Get-RimeTrustedPowerShellHost returns only mocked current-process/$PSHOME pwsh.exe.
    # Assert an unsigned, reparse, wrong-name, or mismatched current process host throws.
}

Case 'Windows 11 x64 PowerShell contract rejects Windows 10 and x86 process' {
    # Mock host facts: Windows 10 product/build => throw; Windows 11 build <22000 => throw;
    # Windows 11 x64 + PS 7 x64 => no throw; x86 process => Assert-RimePowerShell7X64 throws.
}

Case 'registry rollback failure produces recovery-required evidence' {
    # Stub snapshot/set/read/restore and a switch adapter that throws.
    # Make restore throw or read-back mismatch.
    # Assert persisted report result has Profile switch, Status recovery_required,
    # original failure plus rollback error, and no completed switch result.
}

Case 'Weasel stop never invokes broad quit IPC and revalidates selected PID identity' {
    # Inspect or stub process helpers. Assert no Start-Process /quit branch exists.
    # Simulate changed start time/SID/session/path for same PID and assert no CloseMainWindow/Stop-Process occurs.
}

Case 'Moqi stage identity changes for current lock and selection inputs' {
    # Compare identities differing only in main SHA, main URL, stage version,
    # a main pattern, an overlay pattern, a dependency SHA, and lite/full.
    # Every pair must differ.
}

Case 'control and Raycast exception survive in install report' {
    # Stub successful profile result then throw separately from control and Raycast.
    # Assert report preserves profile result and appends named failed component result.
}

Case 'final managed operation check rejects injected reparse parent' {
    # Use a controlled test seam that creates a symbolic-link/reparse parent after planning.
    # Assert copy/delete aborts before content mutation; skip only if fixture creation is unavailable.
}
```

**Execution:**

1. Add only the tests and minimal function test seams; do not alter production behavior yet.
2. Run `pwsh -NoProfile -File tests/windows/run.ps1` on a host with PowerShell 7. Confirm each new case fails for its intended missing behavior, not fixture setup.
3. On this macOS host, record `pwsh: command not found` as an environment blocker instead of claiming red/green execution.

### Task 2: Enforce Windows 11 x64 and trusted UAC launcher provenance

**Files:**

- Modify: `windows/lib/Rime.Windows.ps1`
- Modify: `windows/install.ps1`
- Modify: `windows/scripts/rime-switch.ps1`
- Modify: `windows/scripts/rime-userdata.ps1`
- Test: `tests/windows/run.ps1`

**Implementation:**

1. Add a pure predicate for Windows-11 product/build facts. It must accept Windows 11 product identity with build `>=22000`, reject Windows 10/Server/unknown product names, and avoid relying only on `[Environment]::OSVersion` because compatibility version reporting can lie.
2. Add `Get-RimeWindowsHostInfo` behind mockable accessors. On Windows, read `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion` product name and build, plus OS/process bitness and `$PSVersionTable.PSVersion.Major`.
3. Make `Assert-RimeWindowsHost` require Windows platform, Windows 11 facts, and 64-bit OS. Add `Assert-RimePowerShell7X64` requiring major version >= 7 and `[Environment]::Is64BitProcess`.
4. Call the x64 PowerShell assertion at the start of installer context, `Invoke-RimeSwitchCommand`, and userdata export before root or Registry discovery. Keep status and `-NoDeploy` under the same process contract.
5. Add `Get-RimeTrustedPowerShellHost`:
   - obtain current process executable path without command lookup;
   - require normalized leaf name `pwsh.exe` and exact agreement with normalized `$PSHOME\pwsh.exe`;
   - require regular non-reparse leaf inside a plain path;
   - require a valid Windows Authenticode signature whose signer is Microsoft;
   - return the full path only after all checks pass.
6. Change `Invoke-RimeElevatedRootAcl` to call that helper. Retain encoded payload validation and never accept a caller-provided fallback executable.

**Expected code shape:**

```powershell
function Invoke-RimeElevatedRootAcl([string]$Root, [string]$OwnerSid) {
    Assert-RimeWindowsHost
    Assert-RimePowerShell7X64
    $pwsh = Get-RimeTrustedPowerShellHost
    $encoded = New-RimeAclElevatedCommand $Root $OwnerSid
    $process = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -Verb RunAs -Wait -PassThru -ErrorAction Stop
    if ($process.ExitCode -ne 0) { throw "Elevated RIME ACL setup failed with exit code $($process.ExitCode)" }
}
```

**Verification:**

- Run new host/launcher cases first red, then green.
- Parse all Windows PowerShell files with `[System.Management.Automation.Language.Parser]::ParseFile` and require zero errors.
- On Windows 11 x64 later, verify a normal signed `pwsh.exe` passes and a test-only PATH shadow cannot change the UAC file path without invoking UAC.

### Task 3: Make Registry selector rollback exact, observable, and report-safe

**Files:**

- Modify: `windows/install.ps1`
- Modify if shared helpers belong there: `windows/lib/Rime.Windows.ps1`
- Modify: `tests/windows/run.ps1`

**Implementation:**

1. Replace nullable-string rollback state with a snapshot object:

```powershell
[pscustomobject]@{ Exists = [bool]; Value = [string] }
```

2. Implement `Get-RimeWeaselUserDirectorySnapshot` by querying existence separately from value. Preserve the raw previous string; do not normalize it away before restoring.
3. Implement `Restore-RimeWeaselUserDirectorySnapshot`:
   - if `Exists`, restore exact value;
   - otherwise remove exactly `RimeUserDir`;
   - read back a new snapshot;
   - throw if existence or value differs from expected.
4. In `Invoke-RimeInstall`, isolate initial Registry selector write plus profile switch in one protected block. On switch failure, capture rollback exception/mismatch rather than swallow it.
5. Emit exactly one `switch` result:
   - `failed` if rollback succeeds;
   - `recovery_required` if rollback fails or read-back differs.
   Include original switch failure, expected old selector state, observed state where safe, and rollback error in message fields.
6. Preserve `finally` report saving and make top-level nonzero outcome include both `failed` and `recovery_required`.

**Regression behavior:**

```powershell
# Previous value exists
$before = [pscustomobject]@{ Exists = $true; Value = 'D:\Old\RimeConfig' }
# A deployment failure plus successful restore records failed.
# Same deployment failure plus Restore-RimeWeaselUserDirectorySnapshot throwing
# records recovery_required and persists that result.

# Previous value absent
$before = [pscustomobject]@{ Exists = $false; Value = $null }
# Restore removes property and verifies it remains absent.
```

**Verification:**

- Run only the rollback cases until red then green.
- Run full portable suite after implementation.
- Windows-native acceptance later: force a safe test deployment failure after selector set, verify exact HKCU property restoration for both pre-existing and absent values.

### Task 4: Replace broad Weasel shutdown IPC with PID-identity-scoped control

**Files:**

- Modify: `windows/lib/Rime.Windows.ps1`
- Modify: `tests/windows/run.ps1`
- Modify: `windows/README.md`
- Test source evidence: `/tmp/rime-weasel-review/WeaselServer/WeaselServer.cpp`, `/tmp/rime-weasel-review/include/WeaselIPC.h`

**Implementation:**

1. Record `StartTimeUtc` in `Get-RimeMatchingServerProcesses` alongside ID, normalized executable path, owner SID, and session ID.
2. Add `Get-RimeVerifiedServerProcess($Record, $InstallDirectory, $OwnerSid)` that reacquires the ID and requires exact path, SID, session, and start time before returning a process object. PID reuse or unreadable properties returns no process.
3. Remove `Start-Process ... WeaselServer.exe /quit` entirely. Weasel 0.17.4 source uses a username-based named pipe, so it cannot meet the required isolation scope.
4. For every verified selected process with a usable main window, call its own `CloseMainWindow()`; do not enumerate or signal unselected servers. Wait until timeout while re-enumerating only fresh matching records.
5. After timeout, force-stop only freshly enumerated and reverified matching PIDs. Fail if matching records remain. Do not use `Get-Process -Name` output directly for termination.
6. Make comments/documentation state that PID-scoped close is best-effort; force stop is explicit and limited to verified current-user/session/executable identities.

**Verification:**

- The new test must fail if `/quit` returns or identity revalidation is removed.
- Static/source assertion confirms `Stop-RimeWeasel` contains no `/quit` or broad `Start-Process` server invocation.
- Windows-native multi-session acceptance: run test instances under two SIDs/sessions from same install directory; stop one and verify other remains.

### Task 5: Version and fully key Moqi cached-stage identity

**Files:**

- Modify: `windows/lib/Rime.Install.ps1`
- Modify: `tests/windows/run.ps1`
- Inspect: `windows/lib/Rime.Core.ps1`, `windows/manifests/rime.lock.json`

**Implementation:**

1. Add `Get-RimeMoqiStageIdentityParts($Lock, [bool]$Full, [string[]]$MainPatterns, $OverlayDefinitions)` that returns a deterministic ordered list, not an unordered object serialization.
2. Include a literal format version (`moqi-stage-v3`), main and overlay repository/commit/url/SHA-256 fields, exact ordered main patterns, each named overlay’s exact ordered patterns, and Lite/Full marker.
3. Validate lock field presence and checksum shape before deriving identity. Preserve existing archive SHA validation and cache marker integrity behavior.
4. Make `Get-RimeSourceRootForProfile` use these parts for every Moqi stage. Do not change non-Moqi archive behavior unnecessarily.
5. Ensure newly calculated identity creates a distinct cache directory. Do not delete old valid stage directories merely because source rules changed; they are immutable cache entries and may be removed only by explicit owned-cache cleanup policy in future work.

**Regression behavior:**

```powershell
$baseline = Get-RimeProfileStageIdentity (Get-RimeMoqiStageIdentityParts $lock $false $patterns $overlays)
# Change only one variable at a time: SHA, URL, stage version, main pattern,
# overlay pattern, overlay pin, variant. Every identity differs from $baseline.
```

Use local ZIP fixtures to demonstrate actual `Get-RimeSourceRootForProfile` returns a different stage path after changing a lock SHA/pattern input, while the Lite fixture still excludes the Full sentinel and Full still includes it.

**Verification:**

- Run stage identity/closure/cache tamper cases.
- Inspect cache marker and stage name in temporary fixture; no network access.

### Task 6: Preserve partial installation evidence and narrow reparse operation races

**Files:**

- Modify: `windows/install.ps1`
- Modify: `windows/lib/Rime.Core.ps1`
- Modify as needed: `windows/lib/Rime.Install.ps1`
- Modify: `tests/windows/run.ps1`

**Implementation, reporting:**

1. Wrap `Install-RimeControlFiles` and `Install-RimeRaycastScripts` separately in result-recording `try/catch` blocks. Their exceptions add `control: failed` or `raycast: failed`; they do not skip report saving.
2. Preserve already recorded runtime/profile/switch results. `-PassThru` returns report after partial failure; outer process exits nonzero based on report statuses.
3. Do not label components not reached as successful or manufacture a result for an operation never started.

**Implementation, operation-time revalidation:**

1. Add small helpers that immediately call `Assert-RimePlainPath` for a source leaf, destination parent, destination leaf, and expected leaf/container type immediately before each filesystem mutation.
2. Route direct managed writes/deletes through those helpers in at least:
   - `Write-RimeJson` temporary write/replace/move/cleanup;
   - `Expand-RimeArchiveSafe` entry writes;
   - `Copy-RimeSelectedFiles`;
   - `Copy-RimeManagedFiles` copy and stale deletion;
   - `New-RimeProfileSourceStage` main/overlay copies;
   - generated Lite patch/dictionary writes and generated-artifact deletion;
   - managed export copies;
   - control-file staging and cleanup.
3. Recheck source leaves immediately before opening/read-copying. Recheck target parent and target path immediately before create/replace/delete. Reject any reparse point, unexpected directory, or missing expected leaf.
4. Do not claim this check eliminates all TOCTOU. Keep native no-follow handle work out of this patch and state residual risk in output documentation.

**Regression behavior:**

```powershell
# Control/Raycast throw paths: report contains prior completed profile and named failure.
# Operation test seam creates a link between preflight and final operation check:
# Copy-RimeManagedFiles / deletion throws “reparse”; external target remains unchanged.
```

**Verification:**

- New report cases first red then green.
- New controlled reparse test must prove no external file copy/delete occurred.
- Full portable suite after both subareas pass.

### Task 7: Repair documentation and Windows-native acceptance boundary

**Files:**

- Create: `windows/README.zh-CN.md`
- Modify: `windows/README.md`
- Modify: `docs/windows-rime-plan.md`
- Modify: `README.md`
- Modify: `README.zh-CN.md`
- Modify: `docs/README.md`
- Modify: `docs/README.zh-CN.md`
- Modify: `docs/architecture.md`
- Modify: `docs/architecture.zh-CN.md`
- Modify: `docs/troubleshooting.md`
- Modify: `docs/troubleshooting.zh-CN.md`
- Modify: `AGENTS.md`
- Modify: `CLAUDE.md`

**Content requirements:**

1. Change all current Windows RIME contract text from Windows PowerShell 5.1 to PowerShell 7 x64 (`pwsh.exe`), explicitly saying existing 5.1 profiles are untouched but unsupported by these scripts.
2. Correct English Windows README native-acceptance link from `docs/architecture.md...` to `../docs/architecture.md#native-windows-acceptance`.
3. Write Chinese guide matching English behavior: prerequisites, root precedence, source lock/closure, Lite/Full, fixed Junction selector, switching/status, Raycast, review export, legacy adoption, report/recovery semantics, and portable/native boundary.
4. Add focused root/docs indexes so the legacy macOS-only bootstrap narrative does not imply Windows RIME is part of `install.sh`; point Windows readers to `bootstrap.sh` and `windows/README*`.
5. Add an architecture section named `Native Windows acceptance` and matching Chinese heading. It must require, without claiming completion:
   - Windows 11 x64 + signed PowerShell 7 x64 host;
   - normal and UAC ACL fallback with hostile PATH shadow test;
   - HKCU selector rollback for existing/absent property and forced failure;
   - Junction commit/recovery interruption;
   - same runtime under different SID/session stop isolation;
   - deployment artifact freshness and rollback;
   - Lite/Full migration and dependency closure;
   - reparse-swap test and explicit remaining syscall-race limitation;
   - Raycast execution.
6. Update troubleshooting with diagnosis of untrusted pwsh host, unsupported Windows/bitness, `recovery_required`, stale stage after prior versions, control/Raycast partial report, and native-only failure categories.
7. Update agent guidance with PowerShell parser/full test commands, no-live-operation test rule, explicit untracked-file whitespace check, and no misleading native-success claim.

**Verification:**

- Check every Markdown link relative to its source path.
- Search for stale “Windows PowerShell 5.1” Windows-RIME wording and incorrect `windows/docs/` links.
- Confirm Chinese and English docs agree on safety boundaries, not necessarily literal phrasing.

### Task 8: Run gates, independent review, and Beads evidence update

**Files:**

- No product file unless a gate/review identifies a regression.
- Modify only after verified evidence: `/Users/shiujenyu/my-brain` Beads note for `my-brain-29h`.

**Portable gates (run from `/Users/shiujenyu/config-windows-rime` when PowerShell 7 exists):**

```bash
pwsh -NoProfile -File tests/windows/run.ps1
pwsh -NoProfile -Command '
  $files = Get-ChildItem windows,tests/windows -Recurse -Filter *.ps1
  $bad = foreach ($file in $files) {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { "$($file.FullName): $($errors | ForEach-Object Message -join "; ")" }
  }
  if ($bad) { $bad; exit 1 }
  "PowerShell parser: $($files.Count) files passed"
'
./tests/bootstrap.sh
./tests/integration.sh
find . -type f -name '*.sh' -exec bash -n {} +
python3 -m json.tool windows/manifests/rime.lock.json >/dev/null
git diff --check --no-index /dev/null bootstrap.sh \
  docs/windows-rime-plan.md tests/bootstrap.sh tests/windows/run.ps1 \
  windows/README.md windows/README.zh-CN.md windows/install.ps1 \
  windows/lib/Rime.Core.ps1 windows/lib/Rime.Install.ps1 \
  windows/lib/Rime.Switch.ps1 windows/lib/Rime.Windows.ps1 \
  windows/manifests/rime.lock.json windows/raycast/Rime-Ice.bat \
  windows/raycast/Rime-Mint.bat windows/raycast/Rime-Moqi.bat \
  windows/raycast/Rime-Status.bat windows/raycast/Rime-Toggle.bat \
  windows/scripts/rime-switch.ps1 windows/scripts/rime-userdata.ps1
```

If `pwsh` is absent, record the exact missing-command output and do not represent parser or PowerShell tests as passed. Still run safe Bash/JSON/whitespace gates possible on host.

**Independent review:**

1. Launch a fresh read-only reviewer under the repaired `pi-subagents` workflow, serially if provider capacity is constrained.
2. Require findings categorized P0/P1/P2 with exact locations and an explicit verdict.
3. For every validated P0/P1/P2, return to its task, write a red regression, apply minimal fix, rerun relevant and full gates, then request a final fresh review.
4. Do not substitute an unapproved CLI reviewer if workflow infrastructure fails; report exact blocker.

**Beads update:**

After fresh evidence only, update `my-brain-29h` notes with test counts, report/review verdict, revised cache/host/rollback boundaries, missing PowerShell or Windows-native blockers, and the commit/push state. Do not close it until Windows 11 x64 native acceptance completes.

## Plan self-review

- **Spec coverage:** Tasks 2–6 map all “fix now” review items; Task 7 maps all documentation corrections; Task 8 maps validation, independent review, Beads, and native boundary. The reparse limitation is intentionally not misrepresented as fully solved.
- **Scope:** No second runtime, registry redesign, new source repository, new package manager, or macOS installer modification is included.
- **Interfaces:** New helpers are named in Task 1 and consumed consistently by Tasks 2–5.
- **Review focus:** Each listed failure mode has an owning regression task: UAC/host (2), rollback (3), process isolation (4), cache identity (5), reparse final check (6).
- **Tracking:** This is an execution design, not a task tracker; Beads remains authoritative.

## Audit round 2 (post-review fixes)

A fresh read-only reviewer (no P0) returned four P1 and eight P2 findings. One fix pass was applied; nothing here is verified, because `pwsh` is still absent.

**Fixed in this round:**

1. `Prepare-RimeRoot` and `Ensure-RimeModifyAccess` now read the root marker and enforce `Assert-RimeMarker` **before** any ACL grant or UAC elevation, so a root owned by another SID can no longer receive a recursive `Modify` ACL first. Regression: `ACL setup refuses a root marker owned by another SID`.
2. `Get-RimeMatchingServerProcesses` no longer swallows inspection failures. A current-session candidate that cannot be inspected is reported as an error instead of being treated as “no server running”; other-session candidates remain intentionally out of scope. Session lookup moved to the `Get-RimeCurrentSessionId` seam so this stays testable off-Windows. Regression: `process enumeration refuses uninspectable current-session candidates`.
3. Test harness: `SKIP:` is now a distinct signal with its own counter, so an unavailable symbolic-link fixture can never be counted as `PASS`; the two injected fixture failures were converted to the same signal.
4. Test bug: `orphan selector backup is recovered only with matching transaction` now writes the `state.json` journal the recovery path requires, and a missing `)` made `tests/windows/run.ps1` unparseable — proof that the earlier “85 passed” figure cannot have come from this file.
5. `Test-RimeCacheIntegrity` guards absent marker-entry properties so a structurally incomplete marker returns `$false` (rebuild) instead of throwing.
6. `Get-RimeWeaselInstallDirectory` reads `InstallDir` through `PSObject.Properties` instead of member access on a possibly-absent registry value under StrictMode.
7. `Backup-RimeLegacyState` now asserts `Test-RimeDirectoryTreeEqual` on every copied legacy tree, so “backup created and validated” is true.
8. Moqi stage identity includes the **declared overlay position** (`overlay[<n>]-<name>/...`), because staging precedence uses declaration order; stage format bumped to `moqi-stage-v4`.
9. `Invoke-RimeSwitchCommand` takes `install.lock` before switching, so a user-invoked switch cannot race a running `windows/install.ps1`.
10. Documentation scoped and corrected: control/Raycast copies are manifest-governed replacements, not exclusive creates; PATH-resolved `pwsh.exe` in the wrappers and `bootstrap.sh` is recorded as accepted residual risk; native acceptance gained an owner-SID-gate, install/switch exclusion, enumeration-failure, and windowless-server entry.

**Deferred (recorded, not fixed):**

- The unmarked-root case: an explicit `-RimeRoot` naming a directory that another user already populated has no marker to check. Adoption remains user-authorized, and `-BackupLegacy` is required before adoption, but it cannot be verified by code.
- `MainWindowHandle` as the `CloseMainWindow()` gate, NTFS `Move-Item` Junction rename semantics, `Get-AuthenticodeSignature` subject matching, and `SHA256Managed` versus `[SHA256]::Create()` are all native-only and now listed in the architecture acceptance checklist.
- `Get-RimeTrustedPowerShellHost` (the function actually used by the UAC path) still has no direct regression; only the pure `...FromFacts` helper is covered.
- Full handle-relative no-follow protection remains the outstanding native security blocker.
