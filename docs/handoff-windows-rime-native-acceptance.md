# Windows RIME native acceptance — handoff

Handoff from the macOS development host to a Windows 11 agent. Read this whole
document before running anything. Nothing in this repository has been verified
on Windows, and no PowerShell test has ever executed.

Written: 2026-09-24. Baseline commit: `a28ac55e636d3ba666fb80b45a622089012b8cfe`
on branch `feat/windows-rime`.

> **Status (2026-09-28):** This handoff was executed on a disposable Windows 11
> guest. Results — including PASS/BLOCKED/UNVERIFIED — are recorded in
> [handoff-windows-rime-native-acceptance-evidence.md](handoff-windows-rime-native-acceptance-evidence.md);
> the RIME implementation and the separate `windows-bootstrap/` lifecycle are
> merged to `main`. The "do not commit" rule in section 2 applied only to the
> original dirty macOS checkout and was later superseded by explicit user
> authorization.

## 1. What you are receiving

An uncommitted Windows RIME implementation: one Weasel `0.17.4` runtime, three
isolated profiles (Ice, Mint, Moqi), a fixed `RimeConfig` Junction selector,
Moqi Lite by default with an explicit Full migration, manifest-governed file
ownership, and a hardening pass driven by an independent review.

Authoritative documents, in precedence order:

1. `docs/superpowers/specs/2026-09-24-windows-rime-security-hardening-design.md` — the contract.
2. `docs/superpowers/plans/2026-09-24-windows-rime-security-hardening.md` — the plan, plus the "Audit round 2" section listing what was fixed and what was deferred.
3. `docs/windows-rime-plan.md` — shorter contract summary.
4. `windows/README.md`, `windows/README.zh-CN.md` — user-facing behavior.
5. `docs/architecture.md#native-windows-acceptance` — the acceptance checklist you are here to execute.

## 2. State you must not change

- **Do not commit. Do not push.** Every Windows RIME file is untracked in the
  development checkout; the branch is deliberately dirty.
- **Do not initialize Beads in this checkout.** The only progress ledger is
  issue `my-brain-29h` in `/Users/shiujenyu/my-brain`, which lives on the macOS
  host. Produce an evidence file instead (section 10) and let the macOS side
  update the ledger.
- **Do not "fix" the macOS installer.** `install.sh`, `scripts/lib/*`, and the
  macOS component scripts are out of scope. `tests/integration.sh` exercises
  them through stubs; a failure there is not a Windows RIME failure.
- **Do not weaken the design to make a test pass.** Section 12 lists decisions
  that are settled. If you believe one is wrong, stop and report instead of
  changing it.
- **Do not run acceptance steps against a real user's RIME data** without the
  explicit approval described in section 9.

## 3. Transfer and integrity verification

Transfer the working tree byte-for-byte. Verify every file against this
manifest before you start; if any hash differs, stop and report which file.

```text
1ca606b287d09a1c800675de42cea40549d4d43074dbc9102fc7ffa745f6c4a1  bootstrap.sh
188f30e98dabea5e72dc7928a3eae1f06e31fed7691fd0675ac092af88585047  tests/bootstrap.sh
ed17f88c28005a49d703fb6cf6c8e07e3beef39ee49f9a0be55f62c918c61e68  tests/windows/run.ps1
f40fed0b61856ecee9fb47233249246c72e8556c50c14a1e379b7140443654a7  docs/windows-rime-plan.md
e37d744af800aae9353e98b14d64e24cb363651a8d14176ba73965f06cf6a463  docs/superpowers/specs/2026-09-24-windows-rime-security-hardening-design.md
221e79c791474346c08f280a76f203894043f8796264b89f231896cfedd64372  docs/superpowers/plans/2026-09-24-windows-rime-security-hardening.md
7f8704bb3330cea14c68bfae732cc77fe06f82988c470fb81d60b56687c94519  windows/install.ps1
6684614719efd69a4a02825c37b2699d5d057f83955630ea1c10f9cd8a8b25be  windows/lib/Rime.Core.ps1
ac15e53aaef8bbe9f7e753c23aeb46b62f7eaad3ad558d8fda13b0aa03fc1473  windows/lib/Rime.Install.ps1
430b8310e0a1c07297092d1ec5074848f811618b3e4b3534a2db43503389bba3  windows/lib/Rime.Switch.ps1
a1eadaa391e340f014a04c4af9ab69a971978db14a77820b5bb3274eafbe4281  windows/lib/Rime.Windows.ps1
73719248ae80fbf57d191369fd589ea431e5a70f2f2cbad36c69ae53a961f78f  windows/manifests/rime.lock.json
bfd3204c397c22de353983b2ad36a74a68e89f97a0babb2076cbea89045314b0  windows/raycast/Rime-Ice.bat
e22e03a75b474b7776c03a8731c907ba87df7dac2c1fa85aa3e0c3f1f2edca8e  windows/raycast/Rime-Mint.bat
dd88c881f057b6622da089edc57de9ee506e958a039ba42496a78be054e7b4a5  windows/raycast/Rime-Moqi.bat
74c7d34711b1f59980ada617efc08f585df9bbcfa287e9fe2b4b9556b20069fb  windows/raycast/Rime-Status.bat
143863dd704eb33908149949ffc5fdd318fb7ad7ed6e1d56650de088f7e842f9  windows/raycast/Rime-Toggle.bat
582662ac8046fdf6dd8a889a126fe64b03aacc8dba9422f7d351904493f2f40d  windows/README.md
4de04fc378f089c8a9c511e05c3eae55e98555c7655e6272ee2ef6633ae70f7d  windows/README.zh-CN.md
08d241bc82fde666c133c68590ac7bc7f73f2fc4939b41e2196a18065a29bf2e  windows/scripts/rime-switch.ps1
3763a5ab8aff607054af19c35c01dd4ed2b29c093a34d3a8486aca581b154116  windows/scripts/rime-userdata.ps1
```

Verify with:

```powershell
Get-FileHash -Algorithm SHA256 windows/install.ps1 | Format-List
```

Do this on the transferred copy, before any test run, and record the result.

## 4. Preconditions on the Windows 11 x64 host

| Requirement | Why | How to confirm |
| --- | --- | --- |
| Windows 11 x64, build ≥ 22000 | `Assert-RimeWindowsHost` rejects Windows 10, Server, and 32-bit OS | `[Environment]::OSVersion`, `(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName` |
| PowerShell 7 x64 (`pwsh.exe`) | `#requires -Version 7.0` plus a runtime x64 check | `pwsh -NoProfile -Command '$PSVersionTable.PSVersion; [Environment]::Is64BitProcess'` |
| Developer Mode **or** an elevated shell | `New-Item -ItemType SymbolicLink` fails otherwise; most reparse regressions would skip | `New-Item -ItemType SymbolicLink` in `%TEMP%` |
| Git Bash or MSYS2 (optional) | Only for `bootstrap.sh` and the two Bash suites | `bash --version` |
| A second local user account (optional, invasive) | The only way to verify cross-SID/cross-session stop isolation | `Get-LocalUser` |

Use `pwsh.exe` explicitly rather than `powershell.exe`. Windows PowerShell 5.1
is not supported by these scripts and must not be used to run them.

## 5. Gate 1 — static gates (fast, expect all clean)

From the repository root in `pwsh`:

```powershell
python3 -m json.tool windows/manifests/rime.lock.json > $null   # or: Get-Content -Raw windows/manifests/rime.lock.json | ConvertFrom-Json
Get-ChildItem windows,tests/windows -Recurse -Filter *.ps1 |
  ForEach-Object { "$($_.FullName): $((Get-Content -LiteralPath $_.FullName -TotalCount 1))" }
```

Expect: the lock JSON parses, and every listed `.ps1` reports exactly
`#requires -Version 7.0`. Then, per file, confirm no trailing whitespace and LF
line endings (the Windows checkout may rewrite line endings — that alone would
change every hash in section 3, so check it early).

## 6. Gate 2 — PowerShell parser (must report zero errors)

```powershell
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
```

This is the first thing that has ever parsed these files. Expect 8 files. Any
error here is a real blocker: report it verbatim, do not hand-edit around it.

## 7. Gate 3 — portable suite (the main gate)

```powershell
pwsh -NoProfile -File tests/windows/run.ps1
```

The summary line must read:

```text
Tests: <N> passed, 0 failed, 0 skipped
```

Rules for reading the result:

- **`failed` must be 0.**
- **`skipped` must be 0.** A skip means a symbolic-link fixture could not be
  created, so the reparse cases did not run. `skipped > 0` is not a pass; it is
  an environment gap. Fix the environment (Developer Mode, elevated shell) and
  re-run before drawing conclusions.
- Record the full output to a file and keep it. Do not paraphrase the counts.

121 cases are defined. The suite is portable by design: it stubs
platform-specific seams (`Assert-RimeWindowsHost`, `Get-Process`,
`Get-RimeCurrentSessionId`, `Get-RimeTrustedPowerShellHostFromFacts`) and runs
the rest against real temporary directories.

Two known test-side risks to watch for specifically:

- Cases that create NTFS Junctions run only under `$IsWindows`. Confirm they
  actually executed rather than silently no-op'ing.
- `process enumeration refuses uninspectable current-session candidates` asserts
  our code's behavior with a stubbed `Get-Process`; it does **not** prove that
  `-IncludeUserName` works on your host. That is acceptance item 10.

## 8. Gate 4 — Bash gates

```bash
bash -n bootstrap.sh && bash -n tests/bootstrap.sh && bash -n tests/integration.sh
find . -type f -name '*.sh' -exec bash -n {} +
./tests/bootstrap.sh
./tests/integration.sh
find . -type f -name '*.sh' -exec shellcheck {} +   # if shellcheck is installed
```

Both suites stub platform detection through `RIME_BOOTSTRAP_UNAME` and a stubbed
`uname`, so they are expected to pass on Windows Git Bash. `tests/integration.sh`
is the macOS installer sandbox; if it fails, report the exact output but do not
treat it as a Windows RIME defect and do not modify `install.sh`.

## 9. Native acceptance protocol

`docs/architecture.md#native-windows-acceptance` lists ten items. Execute them
in the order below, and treat Track A as mandatory and Track B as
approval-gated.

### 9.0 Safety rules

1. **Before any invasive step, back up the real Registry state:**

   ```powershell
   reg export "HKCU\Software\Rime\Weasel" "$env:TEMP\weasel-hkcu-backup.reg" /y
   ```

   Also record the current value directly:
   `Get-ItemProperty 'HKCU:\Software\Rime\Weasel' -Name RimeUserDir`.

2. **Use a scratch root, not the user's real profile root.** Pass
   `-RimeRoot` and `-CacheDirectory` under `%LOCALAPPDATA%\RimeAcceptance` or
   `%TEMP%`. The one global side effect that cannot be avoided is
   `HKCU\Software\Rime\Weasel\RimeUserDir`, so back it up first and restore it
   afterward if the user's real setup must keep working.
3. **Never delete anything under the user's real RIME root** to "clean up" a
   failed acceptance run. Preserve `.RimeConfig.<transaction>.previous`,
   `state.json`, and `install-report.json`; they are the evidence.
4. **Stop and ask** before: installing Weasel machine-wide, creating a second
   local user, or changing any real user's `RimeUserDir`.

### 9.1 Track A — non-invasive acceptance

These do not need Weasel and do not deploy. Run them first.

```powershell
$root  = "$env:LOCALAPPDATA\RimeAcceptance"
$cache = "$env:LOCALAPPDATA\RimeAcceptance\downloads"

# 1. Stage all profiles from the pinned archives, without touching the Registry,
#    the selector, or Weasel. Requires network for the first run only.
pwsh -NoProfile -File windows/install.ps1 -RimeRoot $root -CacheDirectory $cache -SkipWeaselInstall -SkipDeploy -PassThru
```

Expect: a JSON report whose `Results` contain `runtime: failed` (Weasel install
was skipped, reported rather than hidden) and one entry per profile. Verify:

- `state.json` is not `completed` (nothing deployed).
- No `RimeConfig` Junction was created.
- `HKCU\Software\Rime\Weasel\RimeUserDir` is unchanged from your recorded value.
- `install-report.json` exists in `$root` and contains every component.

Then verify idempotence and ownership:

```powershell
# 2. Re-run. Expect no conflicts and no changes.
pwsh -NoProfile -File windows/install.ps1 -RimeRoot $root -CacheDirectory $cache -SkipWeaselInstall -SkipDeploy -PassThru

# 3. Hand-edit one managed upstream file, re-run, and confirm the edit is
#    preserved and reported as manual_required, not overwritten.
# 4. Append a line to managed-files.json's files array for a file you create
#    yourself (e.g. "user-notes.yaml" with its real sha256) and re-run.
#    Expect: the manifest is accepted (it is owned and well-formed) and the
#    file is treated as managed only if its hash still matches.
# 5. Replace managed-files.json with a copy that has no "manager" field and
#    re-run. Expect a hard failure BEFORE any file is copied or deleted, and
#    nothing in the profile removed.
```

Item 5 is the forged-manifest check; it must fail closed, not partially apply.

### 9.2 Track B — Weasel, Registry, Junction, deployment

Requires explicit approval for a machine-level Weasel `0.17.4` install.

```powershell
pwsh -NoProfile -File windows/install.ps1 -RimeRoot $root -CacheDirectory $cache -PassThru
```

Then complete, in this order, recording the exact command and observed output
for each:

1. **Host contract.** Confirm a Windows 10 machine and a 32-bit `pwsh` are both
   rejected with the documented messages, before any mutation.
2. **UAC launcher provenance (acceptance item 1).** Put a fake `pwsh.exe` in a
   directory and prepend it to `PATH`. Run the ACL fallback path and confirm the
   elevated host is still the real `$PSHOME\pwsh.exe`. Confirm no
   `Get-Command pwsh.exe` and no PATH resolution exists in the ACL path.
3. **Root ownership gate (acceptance item 9).** Take a root whose
   `.config-rime-root.json` names a different `ownerSid`, run the installer
   against it, and confirm it fails with `Root owner SID mismatch` *before* any
   `icacls` grant runs. Confirm with `icacls <root>` that no new ACE was added.
4. **Registry rollback (acceptance item 2).** Force a switch failure with
   `RimeUserDir` both absent and present. Verify exact restore plus read-back,
   then force a restore failure and confirm `switch: recovery_required` is
   persisted and the process exits nonzero.
5. **Junction transaction recovery (acceptance item 3).** Interrupt between the
   backup rename and the new Junction, then between the new Junction and
   `completed`. Verify recovery restores only the expected managed selector and
   never force-overwrites a selector that reappears.
6. **Deployment artifacts (acceptance item 5).** Confirm Interactive and Quiet
   deployment both produce fresh `build/*.prism.bin` and `build/*.table.bin`,
   and that a GUI that opens without compiling is reported as failure, not
   success.
7. **Moqi Lite/Full (acceptance item 6).** Install Lite, then migrate with
   `-MoqiFull`, then attempt an implicit downgrade and confirm it is refused.
   Confirm Full-only tables appear only in Full.
8. **Runtime control (acceptance item 4 and 10).** With `WeaselServer.exe`
   running, deliberately make `-IncludeUserName` fail (for example by running
   non-elevated in a configuration where it is denied) and confirm the run
   reports an inspection failure instead of "no server running". Then confirm
   graceful stop and forced stop work, and that the final re-enumeration gate
   throws if a matching process survives.
9. **Cross-user isolation (acceptance item 4).** With a second local account,
   run the same runtime directory and confirm stopping the current user's server
   leaves the other user's server running. This is the only real proof of the
   multi-SID design; `skipped` or bypassing it must be stated plainly.
10. **Concurrency (acceptance item 9).** Start `windows/install.ps1` and, while
    it holds `install.lock`, invoke `windows/scripts/rime-switch.ps1`. Confirm
    the switch is refused rather than racing.
11. **Reparse races (acceptance item 7).** Swap a managed ancestor for a
    reparse point between validation and the operation. Confirm fail-closed
    behavior, and confirm the residual syscall race is still documented as
    unresolved — do not upgrade the claim.

### 9.3 Acceptance item 8 — Raycast

```powershell
pwsh -NoProfile -File windows/install.ps1 -RimeRoot $root -RaycastScriptDir "$env:APPDATA\Raycast\scripts" -PassThru
```

Execute each of the five wrappers from the real Raycast script directory and
confirm: no `%*` forwarding, no arbitrary argument acceptance, correct report
states (`completed` / `manual_required` / `failed` / `recovery_required`), and a
missing Raycast directory producing `manual_required` without undoing profiles.

## 10. Evidence to return

Write one file, for example `docs/handoff-windows-rime-native-acceptance-evidence.md`,
or return the same content in chat. Do not commit it.

```markdown
# Windows RIME acceptance evidence

Host: <Windows edition, build, arch>; pwsh <version>, 64-bit: <yes/no>
Transfer integrity: <verified / which hashes differed>
Run timestamps: <UTC>

## Gate results
- JSON/manifest parse: <result>
- `#requires` line 1 on all ps1: <count> files, <result>
- Parser: <output>
- Portable suite: <exact summary line: passed / failed / skipped>
- Bash syntax + suites: <result per command>

## Acceptance items
| # | Item | Command | Observed | Verdict |
| 1 | UAC launcher provenance | ... | ... | PASS/FAIL/BLOCKED |
...

## Failures
<For each: exact command, exact error text, whether it is a product defect,
 a test defect, or an environment gap, and the smallest reproduction.>

## Unverified
<Anything not executed, and why.>
```

Never write "tests pass" without the literal summary line and a zero skip
count. Never describe portable stubs as Windows-native proof.

## 11. Claims that are currently unverified — do not repeat them

A prior session recorded "85 passed" for this suite. That figure is stale and
cannot be true of the current file: `tests/windows/run.ps1` contained a missing
`)` that made the whole script unparseable. It was fixed on the macOS host, but
the suite has still never run. Treat all of the following as unproven until you
produce evidence:

- Any statement that the PowerShell suite or parser passed.
- `MainWindowHandle != 0` as the gate for `CloseMainWindow()`. If it is always
  zero for a windowless server, every switch silently waits the full timeout and
  then force-stops.
- NTFS `Move-Item` semantics for renaming a Junction into a transaction backup,
  and `New-Item -ItemType Junction` / `Remove-Item` behavior.
- `Get-AuthenticodeSignature` subject matching against the Microsoft signer.
- `Process.SessionId` / `-IncludeUserName` availability on a non-elevated host.
- Full handle-relative no-follow protection. It does not exist. The residual
  check-to-use race in every managed path operation is a known, documented
  Windows-native security blocker.

## 12. Settled design decisions — do not change silently

- One Weasel `0.17.4` runtime; Ice/Mint/Moqi are isolated user-data profiles
  under one managed root.
- Daily switching changes only the `RimeConfig` Junction target. The Registry is
  written once.
- Moqi is Lite by default; `-MoqiFull` is explicit; a managed Full profile is
  never silently downgraded.
- Weasel's username-wide named-pipe shutdown is never invoked. Stop is scoped by
  PID, path, SID, session, and start time.
- Deletion authority comes from an owned manifest marker
  (`manager: config-rime`) plus a matching recorded hash — never from a path.
- Selected, staging, legacy-backup, and review-export copies are `CreateNew`
  only. Control scripts and Raycast wrappers go through the managed manifest and
  may replace an unmodified owned file.
- Staging precedence: main archive first, then overlays in declared order; the
  last declared overlay wins. Moqi stage identity is `moqi-stage-v4` and
  includes the declared overlay position.
- Failed or unprovable temporary artifacts are preserved on purpose.
- A switch takes `install.lock` before `switch.lock`.

## 13. Stop and ask

Report back instead of proceeding when:

- A static or parser gate fails.
- The suite reports any `failed` or any `skipped` after fixing the environment.
- An acceptance step would require touching a real user's RIME data, installing
  Weasel machine-wide, or creating a new local account without approval.
- A step reveals behavior that contradicts sections 11 or 12.
- You are tempted to edit production code to make an acceptance step pass.

## 14. If something fails

Follow the same discipline the macOS side used:

1. Reproduce reliably and read the exact error first.
2. Find the root cause before proposing a fix. No symptom patches.
3. Write a failing regression in `tests/windows/run.ps1` first, watch it fail,
   then make it pass. A fix without a test that failed first is not verified.
4. Change production code only in `windows/**`; keep policy in
   `Rime.Core.ps1` / `Rime.Install.ps1` and Windows-only behavior in
   `Rime.Windows.ps1`.
5. Record every deviation from this handoff as an explicit decision with its
   cost if wrong, so the macOS side can fold it into the ledger.
