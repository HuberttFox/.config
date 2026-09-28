# Windows RIME / Bootstrap acceptance evidence

Written: 2026-09-28 (UTC+08:00)
Repository: `HuberttFox/.config`, merged to `main`
Guest: `Win11BootstrapTest` / `WINBOOTTEST`
Guest user: `WINBOOTTEST\tester`

This record separates evidence from claims. `/init` and PowerShell Direct were used as host transport only. No host-side output is treated as guest acceptance evidence.

## Host and transfer

- Windows edition reported by the guest: Windows 11 Pro, build `26200`, x64. The registry `ProductName` still reports `Windows 10 Pro`; the implementation accepts that label only with a Windows 11 build number and rejects Server products.
- PowerShell 7: `7.6.6`, x64. Windows PowerShell: `5.1.26100.7920`/`5.1.26100.9549` observations during acceptance. Guest process ran elevated as `WINBOOTTEST\tester`.
- Git, WinGet, Windows Terminal, WSL, and Weasel runtime were present in the guest fixture.
- Current synced source hashes recorded on the guest:
  - `windows-bootstrap/lib/Bootstrap.Core.ps1`: `C33BC61E17B60FF123BACC56AA6ACADF6C58433AFD4EE47D15F95F17B4C361C7`
  - `windows-bootstrap/install.ps1`: `8462487EC910C917CDCCA16A87B7D4B2144F76E4DA9E4CFDDD9082539C6FDAA7`
  - `windows-bootstrap/tests/run.ps1`: `7A285B33E144167A9331597876FC3867DCF6560FBB5D985268BD93A3A8A043A3`
- Font manifest SHA-256: `fab782a66f7d3019da64f6572db9fc5d3a4bcb19f9fa13e2d8a62e3693d6396e`.

## Static and portable gates

Evidence retained under `F:\Win11BootstrapTest` (`/mnt/f/Win11BootstrapTest` on host):

- RIME PowerShell parser and portable/native filesystem suite: `native-rime-suite-latest.json`.
  Literal summary: `Tests: 128 passed, 0 failed, 0 skipped`.
- Bootstrap focused regression suite: `native-bootstrap-focused.json`.
  PowerShell 7 literal summary: `Tests: 20 passed, 0 failed`.
  Windows PowerShell 5.1 literal summary: `Tests: 20 passed, 0 failed`.
- Additional Bootstrap regression suite after serialization, ANSI/control, Registry, WSL, Font, and cleanup fixes: `bootstrap-tests-ps7-regressions2.txt` and `bootstrap-tests-ps51-regressions2.txt`.
  Literal summary in both: `Tests: 23 passed, 0 failed`.
- RIME suite includes live Windows reparse/Junction cases. It does not certify Weasel process identity across users, UAC provenance, real Raycast execution, or the residual check-to-use race.
- Bash gate evidence: `evidence/gate4.txt` records `bash -n` success and `tests/bootstrap.sh exit=0`. Existing macOS `tests/integration.sh` reached its expected Windows-host shim boundary but ended with unrelated `~/.zimrc is not a symlink`; no macOS installer files were changed.
- `git diff --check` passed for repository changes. No commit or push was performed.

## Bootstrap lifecycle evidence

### Fresh isolated Mint run `-06`

Primary evidence in `evidence/final-acceptance-06`:

- `rime/raw-isolated-06-streams.json`
- `rime/direct-health-final-06.txt`
- `rime/isolated-06/summary.json`, `state.json`, and `report.json`

Disposable guest harness source was removed after serialized outputs and recovery health evidence were archived; those guest-produced outputs remain authoritative.

The raw guest stdout reports:

- `bootstrapExitCode: 0`
- `bootstrapStatePhase: completed`
- `JetBrains Mono Nerd Font`: `completed`, `Installed/verified 96 JetBrains Mono Nerd Font files`
- `Mint RIME`: `completed`
- `WSL 2 + Ubuntu LTS`: `completed`
- `PowerShell profiles`: `completed`
- `bootstrapFailed: []`
- `Mint input method default`: `manual_required`, because expected TIP `0804:E0210804` was not registered; existing input methods were preserved
- `final-verification`: `manual_required` only for that input-method gap
- RIME report: runtime, Mint, switch, and control all `completed`
- target selector during isolated run: Junction to `RimeProfiles\profiles\Rime_Mint`
- target Registry value during isolated run: `...\RimeProfiles\RimeConfig`
- legacy backup: `robocopyExitCode: 1` (normal `robocopy` success range), 1,411 plain entries copied and fingerprint-matched
- `legacyRootUnchangedBeforeRestart: true`
- `configDirectoryRestored: true`
- `registryRestored: true`
- `restoreErrors: []`
- `completed: true`

The first poll reported the launcher PID as exited and no state root. Raw guest streams later showed the worker had completed successfully; the poll result is a harness observation, not product failure.

### Recovery after interrupted-looking `-06` attempt

`direct-health-final-06.txt` confirms after restoration:

- `userdir=C:\Users\tester\AppData\Local\RimeAcceptance\RimeConfig`
- selector target: `C:\Users\tester\AppData\Local\RimeAcceptance\profiles\Rime_Moqi`
- no pending `.RimeConfig.*.previous` backups
- expected ACL entries for `WINBOOTTEST\tester`, `SYSTEM`, `Administrators`, and `RESTRICTED`

The old `RimeAcceptance` tree and canonical `config-rime\rime.json` were restored by the isolation harness. The final compact collector intermittently failed to open through PowerShell Direct with `The credential is invalid` or a remoting data-structure error; this transport issue does not replace the successful `direct-health-final-06.txt` and raw harness evidence.

### Earlier isolated run `-05`

`inspect-final-05.json` and `verify-isolated-05-current.json` show a completed isolated Mint run with 11 report results, preserved legacy config/Registry, and no old-tree mutation. Its original final report predates the Font object-shape fix; the later `-Verify` record is the authoritative Font-clean result:

- Verify exit code `0`
- live Font check passed
- live Mint RIME check passed
- WSL, Git, PowerShell 7, Terminal, and both profiles passed
- only Mint input-method default remained `manual_required`

## Bootstrap operation semantics

`native-bootstrap-lifecycle-06.json` records native Windows PowerShell 5.1 fixture evidence:

- Intentional missing RIME installer: exit `1`, result `failed_uncleaned`; WSL and profiles still completed; state/report remained parseable and phase reached `completed`.
- Malformed managed profile: component failure continued; `-CleanupFailed` restored the owned first profile and preserved the malformed second profile.
- Unfinished state: new Run rejected with exit `1` and `Previous Windows bootstrap run is unfinished (failed); use -Resume or inspect -Report before starting a new run`.
- Live lock contention: rejected while another process held `bootstrap.lock`; after holder exit, retry succeeded with exit `0`. Lock path persistence is expected and is not a completion marker.
- Resume against completed state: rejected with exit `1`.
- Manual-only run: exit `0`, `manual_required` recorded, failure lists empty.
- Windows PowerShell 5.1 `-Report`: JSON parsed and contained no escaped `\u001b`.
- `native-bootstrap-verify-04b.json`: fresh Verify/Report evidence preserves `phase=initialized` for Verify rather than falsely claiming completion.

### Optional-group verification (2026-09-28)

A fresh `-Profile Optional` run in the same disposable guest finished with 14 `completed` components and 2 `manual_required` components (Spotify, PotPlayer); no failures. Artifacts: `evidence/final-acceptance-06/bootstrap/optional-verify/report.json`, `probe.json`, `state.json`, and the download-mode records `report-download-mode.json` / `state-download-mode.json`.

- Installed and verified by the bootstrap: Obsidian, Typora (`appmakes.Typora`), Thunderbird, Telegram, Steam, CC-Switch, Clash Verge Rev, Zen Browser, Raycast (Microsoft Store), Baidu Netdisk, Quark Netdisk, Geek Uninstaller, Eudic, and dwall; the new base item lazygit passed the per-item probe.
- `Typora.Typora` no longer exists in the WinGet source; the manifest now pins `appmakes.Typora`.
- `Spotify.Spotify` refuses an administrator context and the Microsoft Store package is unavailable in the guest; `Daum.PotPlayer` stalls in its interactive installer even with `--override /S`. Both were removed from `optional.json` after this verification instead of staying as permanent `manual_required` entries.
- dwall uses the new `download` mode: pinned `v0.2.5` installer URL plus `sha256:c448c0d28843523f6121d9edff7d03dd74f422b83f97d0de42b3087f3a182fee`, silent `/S`, and uninstall-registry verification. The first download-mode attempt failed as `failed_uncleaned` (exit 124): under Windows PowerShell 5.1 the argument builder quoted `/S` as `"/S"`, so NSIS never entered silent mode and the installer waited in its GUI. `ConvertTo-BootstrapProcessArgument` now quotes only when required.
- The same attempt exposed an unbounded WinGet hang; `Invoke-BootstrapExternal` enforces timeouts (900 s install, 300 s uninstall) and kills the process tree on timeout.
- The follow-up run after Spotify and PotPlayer were removed from `optional.json` (14 items: 13 WinGet/Microsoft Store plus dwall) finished with 18 `completed` results and no `failed` or `manual_required` entries; `final-verification` completed. Artifacts: `report-optional-final.json` / `state-optional-final.json`.
- In the earlier run, `final-verification` had reported only the WSL gap (`manual_required`) for the Optional-only scope.

## RIME Track A and native safety evidence

- Track A profile staging completed for Ice, Mint, and Moqi with pinned archives and overlays. Managed-file edits were preserved as `manual_required`; forged/unowned manifests failed closed before destructive work. Evidence: `evidence/final-acceptance-06/rime/1038-trackA-run.json` and `evidence/final-acceptance-06/rime/1039-trackA345.json`.
- Moqi Lite/Full staging, dictionary-derived prism names, dependency closure, Junction switching, and managed ownership checks are covered by the 128-case guest suite and earlier native fixture records.
- Registry rollback fixture: `evidence/final-acceptance-06/rime/0077-poll-native-final.json` and `evidence/final-acceptance-06/rime/0079-poll-native-final2.json` record restoration for both pre-existing and absent `RimeUserDir`, plus a forced `recovery_required` path with nonzero outcome.
- Junction recovery fixture records recovery when selector is absent and refusal to overwrite a selector that reappears. The current production change preserves both ambiguous paths and throws `Junction selector appeared during recovery`.
- Root owner-SID gate: `evidence/final-acceptance-06/rime/0031-accept-3-10.json` records `Root owner SID mismatch` before ACL mutation; the controlled fixture reported `aclChanged=False`.
- Concurrency fixture: the earlier run initially used stale copied control libraries and is not product evidence. The current 128-case suite proves lock ordering/pure behavior; a clean live installer-plus-control-script run remains open below.

## Acceptance matrix

| Item | Scope | Verdict | Evidence / limitation |
|---|---|---|---|
| Windows 11 x64 and signed PS7 x64 host contract | native | PASS | Guest build `26200`, x64, PS7 `7.6.6`; parser and host-policy cases pass. Registry label is `Windows 10 Pro`, handled by build-aware detection. |
| UAC launcher provenance and hostile PATH | portable/stubbed only | BLOCKED | Trusted-host logic and hostile-PATH fixtures pass in suite. Real elevated fallback provenance was not independently completed; no fake host was elevated. |
| Registry rollback, absent/present value, forced recovery | native fixture | PASS | `0077`/`0079` records exact restore and `recovery_required` behavior. |
| Junction interruption/recovery and reappearing selector | native filesystem fixture | PASS | Guest suite plus native recovery records; ambiguous selector is preserved, never force-overwritten. |
| Weasel Interactive/Quiet deployment artifacts | native runtime | BLOCKED | Existing Weasel deployment attempts reached runtime/version/deployer problems and timeout/stale-artifact paths. No clean fresh Interactive and Quiet acceptance pair was obtained. |
| Moqi Lite/Full and no implicit downgrade | native staging/switch fixtures | PASS for staging and downgrade guard; BLOCKED for clean live Weasel deploy | Lite/Full resource and dependency cases pass; live deploy pair remains unavailable. |
| Runtime control: `-IncludeUserName`, graceful stop, forced stop, revalidation | native process | BLOCKED | Uninspectable current-session behavior is covered by stubs and throws correctly. A clean real process matrix with forced/graceful stop was not completed. |
| Cross-user/session isolation | native process | UNVERIFIED | No second local user/session was created. Do not claim cross-SID proof. |
| Install/switch concurrency item 10 | native lock | BLOCKED | Lock semantics are covered by suite and Bootstrap lifecycle. Earlier live attempt used stale installed control files; no clean current-source live pair retained. |
| Reparse race | controlled native filesystem fixtures | PASS for final validation cases; residual race remains open | Final-operation reparse injections pass. Handle-relative no-follow protection is not implemented; check-to-use window remains a release security blocker. |
| Raycast wrappers | source/portable + manual fallback | PASS for wrapper contract; UNVERIFIED for actual Raycast directory | Five wrappers contain fixed arguments and no `%*`; missing directory reports `manual_required`. Real configured Raycast directory was not available. |
| Mint input-method default | native user configuration | MANUAL_REQUIRED | Expected TIP `0804:E0210804` missing. Existing English/unrelated TIPs preserved; no unrelated language settings changed. |

## Known failures and gaps

1. Weasel 0.17.4 machine/runtime verification did not yield a clean fresh deployment acceptance. Prior Track B output records `Weasel installer completed but exact runtime verification failed`, deployment timeout, and stale-artifact rejection. These are environment/runtime acceptance gaps, not silently upgraded to success.
2. The live runtime-control matrix (`-IncludeUserName`, window-handle graceful close, windowless forced stop, final PID revalidation) remains unverified. Portable tests prove fail-closed logic only.
3. Cross-SID/session isolation and actual Raycast execution remain unverified because required user/session and Raycast setup were not introduced.
4. The compact final health collector experienced intermittent PowerShell Direct credential/remoting failures. Existing successful health output and the isolated harness summary remain the retained recovery evidence.
5. Existing macOS integration failure in `evidence/gate4.txt` (`~/.zimrc is not a symlink`) is unrelated to Windows changes; no macOS installer source was edited.

## Cleanup and preservation

- Final evidence bundle: `F:\Win11BootstrapTest\evidence\final-acceptance-06` with `SHA256SUMS`; `sha256sum -c` passed before cleanup.
- Disposable guest fixture roots and temporary lifecycle roots were removed after metadata archival. `remove-isolated-06-roots-robocopy.json` records `remaining: []` for both `C:\repo\bootstrap-native-isolated-mint-06` and `C:\repo\rime-isolation-backup-06`.
- Legacy `RimeAcceptance` data was not deleted. Cleanup verification reported `legacyExists: true`, `targetExists: true`, and `legacySelector=C:\Users\tester\AppData\Local\RimeAcceptance\RimeConfig`.
- `bootstrap.lock`/`install.lock` paths may remain by design; active handles were released.
- Host accidental fixture roots, stale helper queues, and credential-bearing disposable harness scripts were removed; they were not product evidence.
- Authored on `feat/windows-bootstrap` and fast-forward merged to `main` in this repository.
