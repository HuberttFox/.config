# Windows RIME / Bootstrap acceptance evidence

Written: 2026-09-29 (UTC+08:00)
Repository: `HuberttFox/.config`, `main` worktree
Guest: `Win11BootstrapTest` / `WINBOOTTEST`
Guest user: `WINBOOTTEST\tester`

This record separates evidence from claims. `/init` and PowerShell Direct were used as host transport only. No host-side output is treated as guest acceptance evidence.

## Host and transfer

- Windows edition reported by the guest: Windows 11 Pro, build `26200`, x64. The registry `ProductName` still reports `Windows 10 Pro`; the implementation accepts that label only with a Windows 11 build number and rejects Server products.
- PowerShell 7: `7.6.6`, x64. Windows PowerShell: `5.1.26100.7920`/`5.1.26100.9549` observations during acceptance. Guest process ran elevated as `WINBOOTTEST\tester`.
- Git, WinGet, Windows Terminal, WSL, and Weasel runtime were present in the guest fixture.
- The protected Spotify fixture's `fixture-source.json` binds its earlier success-path evidence to its recorded source hashes. The final ACL retry acceptance exported an exact pre-override production Core copy in `final-acceptance-07/bootstrap/user-wsl-resume-minimal-da3ad7a12ec34f2bb9dd57281d438eec/source-production-Bootstrap.Core.ps1`; its `SHA256SUMS` passed:
  - `windows-bootstrap/lib/Bootstrap.Core.ps1`: `e8b3d4b754b956e7e737b8e4f3d2c2a3ebc42f81853e536d2547302f89caf8b3`
  - `windows-bootstrap/install.ps1`: `1c4778424605418b32b0cdf74e20415c6a575b1794789ec245ac6dd108697017`
  - `windows-bootstrap/tests/run.ps1`: `83f3f6b3e582f3f4f70cc134a3f4450b6c3436d4f0372d5593eff8eb50ad524b`
  - production `windows-bootstrap/packages/core.json`: `364860990b8894ed5f5a314eec51a8e0d45d4fab2e1825b1e1064c7e4ad1e9d6`
- The same fixture records `productionCoreSha256` before appending its fixture-only WSL resolver, then exports the resulting fixture copy as `0f4fc7241f3afbb67a0cefd215aa25f3fee5c6499ce6a3e1241ec741ae3805c3`. Its controlled Core manifest is `52f302f55ec70b6e5fe402d57f70956fdc693238e844a7aee1026e7f8bf8f62f`.
- Production `windows-bootstrap/packages/optional.json` remains `3fa508c671ad71da771d9d559a5ab06860a4fa429c3839f9285572580204fdff`; it is outside this controlled Core fixture.
- The native Spotify fixture intentionally replaces only its selected Optional manifest with a Spotify-only copy (`edff08203ce2732e438e8de0ac22dad90b97e16210b061b03814cf3625f9a03f`) and uses empty Base/Core manifests. It proves normal-user provenance/UAC import behavior, not a full production Optional install.
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
- Current `windows-bootstrap/tests/run.ps1` was run against the current worktree under Windows PowerShell 5.1 and PowerShell 7. Each literal summary: `Tests: 50 passed, 0 failed`. These are temporary-root tests; they do not invoke installers.
- RIME suite includes live Windows reparse/Junction cases. It does not certify Weasel process identity across users, UAC provenance, real Raycast execution, or the residual check-to-use race.
- Bash gate evidence: `evidence/gate4.txt` records `bash -n` success and `tests/bootstrap.sh exit=0`. Existing macOS `tests/integration.sh` reached its expected Windows-host shim boundary but ended with unrelated `~/.zimrc is not a symlink`; no macOS installer files were changed.
- `git diff --check` passed for repository changes. ACL retry fix and evidence update were committed and pushed as `67cf35d` (`fix(windows): allow user-phase ACL retry`).

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
- The historical follow-up run, before later package additions and after Spotify/PotPlayer were removed from `optional.json`, used 14 items (13 WinGet/Microsoft Store plus dwall) and finished with 18 `completed` results and no `failed` or `manual_required` entries; `final-verification` completed. Artifacts: `report-optional-final.json` / `state-optional-final.json`.
- In the earlier run, `final-verification` had reported only the WSL gap (`manual_required`) for the Optional-only scope.

### D-drive package additions (2026-09-28)

The current source was synced into the same disposable guest and exercised through a cold `-Profile Optional` run after removing the prior manual test install:

- `Microsoft.VisualStudioCode` completed with `before=false`; `attemptedLocation` and `actualLocation` both resolved to `D:\Program Files\Microsoft VS Code`; `Code.exe` was present on D: and absent on C:.
- `JetBrains.PyCharm.Community` version `2025.2.6.1` completed with `before=false`; `attemptedLocation` and `actualLocation` both resolved to `D:\Program Files\JetBrains\PyCharm Community Edition`; `bin\pycharm64.exe` was present on D: and absent on C:.
- That historical complete run reported `failed=0`, `failed_uncleaned=0`, and `manual_required=[]`; its package set contained 15 WinGet/Microsoft Store entries plus pinned-download `dwall` in `optional.json` (16 optional entries, 25 manifest items at that time).
- Evidence: `bootstrap/d-drive-verify/report-vscode.json`, `bootstrap/d-drive-verify/report-pycharm.json`, and the updated `bootstrap/d-drive-verify/README.md`; bundle `SHA256SUMS` verification passed.

### Requested software expansion (2026-09-28)

> Historical section: the results below predate the normal-user Spotify phase and the controlled PotPlayer PortableApps handoff. They remain evidence for the earlier 36-item manifest only; do not use their `manual_required=[Spotify, PotPlayer]` result as acceptance for current source.

The current source was synced into the disposable guest and run through `-Profile Optional` after the new package entries were added:

- Automated entries completed without failed components: Firefox, Microsoft Edge, Google Chrome, Python 3.14, 7-Zip, Notepad4, SumatraPDF, Quicker, and PixPin.
- D-drive probes resolved Firefox, 7-Zip, Notepad4, SumatraPDF, Quicker, and PixPin under `D:\Program Files\...`. Chrome ignored the requested location; Python's Burn installer did not expose a stable executable path at the requested location; neither declares `installLocation`. Edge remains Windows-managed.
- PotPlayer and Spotify were recorded as `manual_required`, not attempted as unattended installs. PotPlayer timed out with `/S` and override probing; Spotify refused administrator context.
- Guest report summary: `failed=0`, `failed_cleaned=0`, `failed_uncleaned=0`, `manual_required=[Spotify, PotPlayer]`.
- Historical manifest totals: 36 items across Base/Core/Optional; Optional then contained 24 WinGet items, one pinned download (`dwall`), and two manual items.
- Evidence: `bootstrap/new-apps-verify/report.json`, `bootstrap/new-apps-verify/evidence.json`, and `bootstrap/new-apps-verify/README.md`; bundle `SHA256SUMS` verification passed.

### Normal-user Spotify and PotPlayer PortableApps follow-up (current source)

Current source replaces the two historical manual records without claiming unattended GUI success:

- `Spotify.Spotify` is a `winget` item with `executionContext: user` and `--scope user`. A normal-user parent runs it before UAC; the elevated child imports only a current-user-SID, matching-run-ID, fresh, canonical-manifest-fingerprint handoff and rechecks `winget list`. An already elevated invocation cannot reverse UAC and records it as `manual_required`.
- `PotPlayer` is a `portable-handoff` item pinned to PortableApps.com `PotPlayerPortable_1.7.22980.paf.exe`, URL `https://download2.portableapps.com/portableapps/PotPlayerPortable/PotPlayerPortable_1.7.22980.paf.exe`, SHA-256 `9c6b0364be94af7bbd117dd05df7485dfd965ee8785e44af6a0129c745f21913`. Default behavior downloads and hashes only. GUI launch requires `-LaunchPortableHandoff`; `completed` requires explicit `-ConfirmPortableHandoff` plus launcher/core-EXE revalidation. No automated extraction or GUI result is asserted.
- Portable PowerShell regression coverage covers user-context contracts, run IDs, medium-integrity/session-zero rejection, protected root/file DACLs, hostile/stale/foreign/injected handoffs, full selected-manifest fingerprint mutation, relay marker propagation, and PortableApps layout traversal rejection.

#### Spotify native UAC success path

Evidence: `F:\Win11BootstrapTest\evidence\final-acceptance-07\bootstrap\spotify-uac-protected`. Its `SHA256SUMS` covers 19 raw artifacts and passed after collection. `fixture-source.json` binds the fixture to the current production hashes above; the fixture's scope is intentionally Spotify-only.

- Task `WB-Uac2-3686b57cf4c74757aa286a76fa7379de` was registered as `WINBOOTTEST\tester`, `InteractiveToken`, and `LeastPrivilege`. Its parent record shows the genuine desktop token: SID `S-1-5-21-1666337339-1272416324-4167337723-1000`, session `1`, non-administrator, Medium Mandatory Level `S-1-16-8192`; it completed with child exit `0`.
- The auto-approved UAC child report/state use run ID `59c817e0a4c7487891110709f73f9932`, phase `completed`, and non-null `logPath`. The child ran as the same SID in session `1` at high integrity `S-1-16-12288`.
- The elevated child imported the handoff and recorded Spotify `completed` with `liveVerification: winget-list`; its failure/recovery lists are empty. The handoff preserves the normal-token host metadata and canonical fingerprint `a6aeeda10da7f8146032a0cbc36d601cb019ca88e293a55a51a54ae91bcbd3f6`.
- Both `%LOCALAPPDATA%\WindowsBootstrap\UserPhase\59c817e0a4c7487891110709f73f9932` and `handoff.json` have protected DACLs with only `WINBOOTTEST\tester` and `SYSTEM`, both FullControl; no handoff `*.tmp` files remained.
- A separate `InteractiveToken`/`LeastPrivilege` task then ran `winget list --id Spotify.Spotify --exact` from the same session-1 Medium token. Exit `0` reported `Spotify.Spotify 1.3.1.234.g59d6bf59` from source `winget`.

This is native acceptance for Spotify's normal-user-to-UAC success path and protected handoff import. The separate cancellation/retry fixture below covers that control-flow boundary; neither fixture proves a full production Optional installation.

#### Real UAC cancellation then retry

Evidence: `F:\Win11BootstrapTest\evidence\final-acceptance-07\bootstrap\uac-cancel-retry-deb99d090d944087832c14a13b025c26`. `SHA256SUMS` covers 29 guest-produced artifacts; its SHA-256 is `8ee2f753d845c3db0c190a725155b3eb9a92d175b5c19690d3dadcb23ee6c688`, and `sha256sum -c SHA256SUMS` passed for every hashed artifact after export. `fixture-source.json` records copied production `install.ps1` SHA-256 `1c4778424605418b32b0cdf74e20415c6a575b1794789ec245ac6dd108697017` and `Bootstrap.Core.ps1` SHA-256 `e8b3d4b754b956e7e737b8e4f3d2c2a3ebc42f81853e536d2547302f89caf8b3`. The fixture's deliberately manual-only Core manifest is separately recorded as SHA-256 `0db29f615107b3f0a4a340b8b8d81fe671938a3a91675f7d923b526df6ad6717`.

- The disposable guest temporarily changed UAC from its auto-approval baseline (`EnableLUA=1`, `ConsentPromptBehaviorAdmin=0`, `PromptOnSecureDesktop=1`) to real administrator confirmation (`ConsentPromptBehaviorAdmin=2`, `PromptOnSecureDesktop=0`). The two actual attempts came from `WINBOOTTEST\tester` desktop launchers `WindowsBootstrap-UAC-CANCEL.cmd` and `WindowsBootstrap-UAC-RETRY.cmd`, not from the fixture's recorded scheduled-task definitions.
- In the first attempt, the desktop user clicked **No**. The parent record is `WINBOOTTEST\tester`, same SID, session `2`, non-administrator, Medium integrity `S-1-16-8192`, with exit `1`. Its guest raw stderr is ANSI code page 936; after decoding it says `操作已被用户取消。` (`The operation was canceled by the user`). At capture time the machine state root, state/report/log, and lock did not exist. The normal-user handoff was present and both its root and `handoff.json` had protected owner/SYSTEM-only FullControl DACLs.
- In the second attempt, the desktop user clicked **Yes**. A fresh handoff was created under the same run ID; the retry parent was again the same Medium desktop SID/session and exited `0`. Its JSON relay, state, and report share run ID `deb99d090d944087832c14a13b025c26`; state reached `completed`. The child report records the same SID/session at High integrity `S-1-16-12288` and `userPhase.status=imported`. Failure and recovery lists are empty. `manual_required` remains only for the intentional manual-only fixture item and fixture-environment final verification gaps (`wsl`, two profile checks).
- `task-cleanup.json` records removal of both fixture tasks, later task checks confirm absence, and both the recorded restored UAC policy and a later live read match the original auto-approval baseline. No `consent.exe` remained.
- Scope: this proves a real user cancellation followed by a real retry/import in one normal-user desktop session. It does not prove a full production Core/Optional run, a real WSL installation, PotPlayer interaction, or package installation success.

#### Elevated-child failure relay

Evidence: `F:\Win11BootstrapTest\evidence\final-acceptance-07\bootstrap\relay-child-failure-869f38288af64edda682967081be2f02`. Its checksum manifest covers the parent stdout/stderr, child state/report, handoff, relay marker, task XML, and fixture-source snapshot.

- Medium, session-1 parent returned `parentExitCode=1` after an intentional elevated-child failure.
- Parent stdout remained one parseable JSON report, stderr was empty, and child report/state/relay marker share run ID `869f38288af64edda682967081be2f02`.
- This is native acceptance for the `-PassThru` child-failure relay contract. It is not UAC decline/retry evidence.

#### Combined normal-user and WSL Resume

Evidence: `F:\Win11BootstrapTest\evidence\final-acceptance-07\bootstrap\user-wsl-resume-minimal-da3ad7a12ec34f2bb9dd57281d438eec`. `sha256sum -c SHA256SUMS` passed for all 18 exported guest artifacts, including state/report/log, initial/final handoffs, task XML, controlled UTF-16LE `wsl.exe`, exact pre-override production Core source, and copied fixture source.

- Run ID `a1bdd26ea1b04635b4b81466b6852e40` began in `WINBOOTTEST\tester` session 2, non-admin, Medium integrity `S-1-16-8192`. It reached `awaiting-reboot` and registered `WindowsBootstrap-Resume-a1bdd26ea1b04635b4b81466b6852e40` as `InteractiveToken` + `Limited`.
- The Limited Resume task ran a second normal-user phase under the same Medium SID/session, safely reprotected the existing owner/SYSTEM-only root and `handoff.json`, then imported it in the high-integrity child. The initial and final handoff records preserve Medium provenance; both DACL snapshots contain only `WINBOOTTEST\tester` and `SYSTEM`, FullControl, with inheritance disabled.
- Controlled WSL output used UTF-16LE. Resume changed the stub from reboot-required to ready; WSL completed, state reached `completed`, `requiresReboot=false`, and the Resume task file no longer existed.
- Scope: controlled Core fixture only. It proves normal-user handoff retry plus Limited-token WSL Resume, not a real WSL installation or full production package profile.

PotPlayer remains **BLOCKED**: cold-guest download/hash, explicit GUI launch, user-selected destination, confirmation/live layout-hash check, upgrade/re-run, and cleanup boundaries still need native evidence before any `completed` claim.

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
| Spotify normal-user UAC handoff | native guest success path + portable guards | PASS for Spotify success path | `final-acceptance-07/bootstrap/spotify-uac-protected`: InteractiveToken/Limited parent was session-1 Medium, UAC child was session-1 High, protected handoff imported, and elevated/live WinGet verification passed. The separate cancellation/retry fixture does not install Spotify. |
| UAC cancellation followed by retry | native guest manual-only Core fixture | PASS for UAC fixture scope | `final-acceptance-07/bootstrap/uac-cancel-retry-deb99d090d944087832c14a13b025c26`: a session-2 Medium desktop parent returned `1` after raw CP936 stderr said `操作已被用户取消。`; no machine-phase artifacts existed. A fresh Medium handoff then imported in a session-2 High child; parent exit `0`, JSON relay/state/report run IDs matched, state reached `completed`, cleanup restored policy/tasks, and 29 guest artifacts checksum-validated. No production profile/package result is claimed. |
| Elevated-child `-PassThru` failure relay | native guest fixture | PASS | `final-acceptance-07/bootstrap/relay-child-failure-869f38288af64edda682967081be2f02`: Medium parent exits nonzero while stdout remains parseable JSON and state/report/relay run IDs match. |
| Normal-user handoff retry plus Limited-token WSL Resume | native guest controlled fixture | PASS for fixture scope | `final-acceptance-07/bootstrap/user-wsl-resume-minimal-da3ad7a12ec34f2bb9dd57281d438eec`: two Medium user phases, protected DACL retry, high child import, UTF-16LE WSL ready check, completed state, task cleanup, and exact pre-override production Core source; not real WSL installation/full production profile. |
| Registry rollback, absent/present value, forced recovery | native fixture | PASS | `0077`/`0079` records exact restore and `recovery_required` behavior. |
| Junction interruption/recovery and reappearing selector | native filesystem fixture | PASS | Guest suite plus native recovery records; ambiguous selector is preserved, never force-overwritten. |
| Weasel Interactive/Quiet deployment artifacts | native runtime | BLOCKED | Existing Weasel deployment attempts reached runtime/version/deployer problems and timeout/stale-artifact paths. No clean fresh Interactive and Quiet acceptance pair was obtained. |
| Moqi Lite/Full and no implicit downgrade | native staging/switch fixtures | PASS for staging and downgrade guard; BLOCKED for clean live Weasel deploy | Lite/Full resource and dependency cases pass; live deploy pair remains unavailable. |
| Runtime control: `-IncludeUserName`, graceful stop, forced stop, revalidation | native process | BLOCKED | Uninspectable current-session behavior is covered by stubs and throws correctly. A clean real process matrix with forced/graceful stop was not completed. |
| Cross-user/session isolation | native process | UNVERIFIED | No second local user/session was created. Do not claim cross-SID proof. |
| Install/switch concurrency item 10 | native lock | BLOCKED | Lock semantics are covered by suite and Bootstrap lifecycle. Earlier live attempt used stale installed control files; no clean current-source live pair retained. |
| Reparse race | controlled native filesystem fixtures | PASS for final validation cases; residual race remains open | Final-operation reparse injections pass. Handle-relative no-follow protection is not implemented; check-to-use window remains a release security blocker. |
| Raycast wrappers | source/portable + manual fallback | PASS for wrapper contract; UNVERIFIED for actual Raycast directory | Five wrappers contain fixed arguments and no `%*`; missing directory reports `manual_required`. Real configured Raycast directory was not available. |
| Extension interface, read-only path | native guest read-only | PASS for read-only scope | `final-acceptance-08/bootstrap/extension-native-2bc15a8b42c981bdcd9631213f7b8f0c` plus `extension-native-limited-69f2bfcfb13e1c84f08da020e7244ebf`: guest build `26200`; host-source SHA-256 recorded; the elevated PSSession run showed the expected ACL owner failures (55/58) while a Limited/Medium scheduled task run passed both PS 5.1 and PS7 suites `58/58`; `PlanOnly` hash, `DryRun` no-state, invalid-schema rejection, and raw-`Resume` rejection were captured with checksummed evidence. A real WinGet install with real UAC elevation remains unverified. |
| Mint input-method default | native user configuration | MANUAL_REQUIRED | Expected TIP `0804:E0210804` missing. Existing English/unrelated TIPs preserved; no unrelated language settings changed. |

## Known failures and gaps

1. Weasel 0.17.4 machine/runtime verification did not yield a clean fresh deployment acceptance. Prior Track B output records `Weasel installer completed but exact runtime verification failed`, deployment timeout, and stale-artifact rejection. These are environment/runtime acceptance gaps, not silently upgraded to success.
2. The live runtime-control matrix (`-IncludeUserName`, window-handle graceful close, windowless forced stop, final PID revalidation) remains unverified. Portable tests prove fail-closed logic only.
3. Cross-SID/session isolation and actual Raycast execution remain unverified because required user/session and Raycast setup were not introduced.
4. The compact final health collector experienced intermittent PowerShell Direct credential/remoting failures. Existing successful health output and the isolated harness summary remain the retained recovery evidence.
5. PotPlayer's PortableApps path has no cold-guest interactive acceptance yet: download/hash, GUI launch, selected root, explicit confirmation, upgrade/re-run, and cleanup remain open.
6. Existing macOS integration failure in `evidence/gate4.txt` (`~/.zimrc is not a symlink`) is unrelated to Windows changes; no macOS installer source was edited.
7. The restricted Extension interface has read-only native acceptance only. A real WinGet install with real UAC elevation and the protected-snapshot import for a mutating extension remains open.

## Cleanup and preservation

- Historical evidence bundle: `F:\Win11BootstrapTest\evidence\final-acceptance-06` with `SHA256SUMS`; `sha256sum -c` passed before cleanup.
- Current protected Spotify UAC bundle: `F:\Win11BootstrapTest\evidence\final-acceptance-07\bootstrap\spotify-uac-protected`. Its 19-artifact `SHA256SUMS` passed after collection; raw task XML, parent record, state/report/log, handoff, ACL facts, fixture provenance, source copies, and limited-token live WinGet result are retained.
- Real UAC cancellation/retry bundle: `F:\Win11BootstrapTest\evidence\final-acceptance-07\bootstrap\uac-cancel-retry-deb99d090d944087832c14a13b025c26`. Its `SHA256SUMS` covers 29 guest-produced artifacts and `sha256sum -c` passed for all of them. It retains archived desktop-launcher copies, both parent records/streams, initial and retry handoffs, ACL facts, state/report/log, restored UAC policy, task cleanup, fixture provenance, and copied source.
- Post-export operational cleanup restored the disposable `tester` account credential and removed both live desktop launchers. A guest-side read confirmed baseline UAC policy, no `WB-Uac*` fixture tasks, no `consent.exe`, and absent launchers; this live cleanup verification is separate from the immutable evidence bundle.
- Disposable guest fixture roots and temporary lifecycle roots were removed after metadata archival. `remove-isolated-06-roots-robocopy.json` records `remaining: []` for both `C:\repo\bootstrap-native-isolated-mint-06` and `C:\repo\rime-isolation-backup-06`.
- Legacy `RimeAcceptance` data was not deleted. Cleanup verification reported `legacyExists: true`, `targetExists: true`, and `legacySelector=C:\Users\tester\AppData\Local\RimeAcceptance\RimeConfig`.
- `bootstrap.lock`/`install.lock` paths may remain by design; active handles were released.
- Host accidental fixture roots, stale helper queues, and credential-bearing disposable harness scripts were removed; they were not product evidence.
- Authored on `feat/windows-bootstrap` and fast-forward merged to `main` in this repository.
