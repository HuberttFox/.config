# Windows RIME implementation plan

Execution authority: user-approved three-profile design, direct native implementation, test first. Beads `my-brain-29h` holds progress. Committing and pushing were later authorized by the user; the macOS installer remains unchanged.

## Contract

Windows 11 x64, signed PowerShell 7 x64 (`pwsh.exe`). Existing Windows PowerShell 5.1 profiles remain unchanged but are unsupported by new RIME scripts. One Weasel 0.17.4 runtime. Three separate profile directories under an explicitly managed root. HKCU points once to `RimeConfig`; daily switching changes only this validated Junction. Root precedence: explicit argument, JSON config, existing managed registry Junction, marked D drive location, LOCALAPPDATA. Correct initiating user SID owns state and receives Modify ACL. Never run daily switching as SYSTEM or another user.

Schemas: ice `rime_ice`, mint `rime_mint_flypy`, moqi `moqi_wan_flypymo` then `moqi_single_xh`. Moqi defaults to Lite; `-MoqiFull` enables Full. Lite preserves native algebra, dictionaries, reverse lookup, Lua, OpenCC and required language model; only unused schemes/resources are omitted. Both variants use pinned upstream commit/archive checksums. No upstream source or runtime data committed here.

Interactive deployment is default (no arguments, 600 second timeout); Quiet uses `/deploy`, with no GUI fallback. Wait for completion, verify fresh compiled schema/table/prism artifacts, then cold-start server. GUI opening alone is not success. Runtime control is scoped by exact executable path, current SID, session, and process start time, never bare process-name killing. Do not call Weasel's username-wide named-pipe shutdown; attempt `CloseMainWindow()` only on revalidated matching PIDs, then force only freshly revalidated matching processes. Timeout means `manual_required` and rollback.

Switch transactions take an exclusive file lock; validate real paths and Junction type/target; journal before mutation; retain previous Junction through rename; recover interrupted transactions explicitly. Refuse unexpected directories, symlinks, reparse parents or external targets. Never recursively delete profile data. Failed deployment restores previous selector and restarts previous runtime. Preserve unknown user edits on reinstall/update; never downgrade Full automatically.

Raycast has five thin .bat commands (Ice, Mint, Moqi, Toggle, Status). Core and local config travel with generated commands. Missing Raycast directory is a separate `manual_required` result, not grounds to undo profiles. Export copies only explicitly listed user-managed plain text into a new review directory; databases/build/binaries never copied or merged.

## File responsibilities and verification sequence

1. `tests/windows/run.ps1`: dependency-free assertions on real file/profile/transaction behavior. Platform adapters alone are stubbed. `windows/lib/Rime.Core.ps1`: path/marker validation, exclusive locks, atomic JSON, archive/file selection, schema patches, profile staging, managed text export. RED: root precedence, malformed marker, path escape, archive traversal, Lite/Full difference, reinstall preserving customizations and databases. GREEN: temporary-directory tests on portable PowerShell; no network or installation in tests.
2. `windows/lib/Rime.Switch.ps1`: transaction coordinator and recovery. `windows/lib/Rime.Windows.ps1`: Windows-only registry, ACL, Junction, executable/process and deployment adapters. RED: switch success, wrong target, directory refusal, lock contention, failed deployment, GUI timeout, failed rollback, interrupted journal, stale build. GREEN: stubbed integration exercising journal/state/files. Native Junction checks run only on Windows temporary directories, never on real RIME data.
3. `windows/manifests/rime.lock.json`: versions, URLs, SHA-256, schemas, precise resource lists. `windows/install.ps1`: current-user preflight, verified downloads, runtime installation with UAC limited to machine operations, profile initialization, selector setup, deployment and report. `windows/scripts/rime-switch.ps1`, `rime-userdata.ps1`: validated public entry points. RED: hash mismatch, unsupported OS, config parsing, no implicit root adoption, partial failure reports, text allowlist. GREEN: stubbed adapters, local archive fixtures.
4. `windows/raycast/*.bat` and renderer: literal relative entry point, no transaction logic in CMD, current-user execution, Status visible output. `bootstrap.sh`: Darwin delegates unchanged; MINGW/MSYS/CYGWIN converts only entry path and forwards an argument array; Linux/WSL rejects. RED: stub routing/exit code, spaces/Unicode, metacharacters. GREEN: `tests/bootstrap.sh`, then existing `tests/integration.sh`.
5. Documentation and constraints: `windows/README.md`, config example, README links and platform-scoped AGENTS guidance. Record unsupported broader Windows bootstrap components. Run all PowerShell tests/parser checks, Bash syntax checks and existing integration tests. Fresh read-only reviewer examines uncommitted files; parent fixes safety/correctness findings with regression tests. Windows 5.1 and actual Weasel acceptance remain explicitly separate from macOS stub evidence.

## Review focus

- Hostile/unexpected reparse parents, malformed state, wrong SID, external targets: fail closed before stop or deletion.
- Crash between Junction renames or state write: explicit recovery restores known previous selector, preserves journal on unresolved conflict.
- GUI exits without deployment, old build artifacts, timeout: never report success from process launch or stale files.
- Existing runtime/profile/customizations and Full-to-Lite reinstall: preserve user data and reject ambiguous ownership instead of overwrite.
- Paths with spaces, Chinese, `%`, `!`, quotes and shell metacharacters: no eval; unsafe CMD-rendered paths rejected with actionable error.

## Evidence boundary

No live WinGet, DISM, WSL, scheduled tasks, reboot, input-method installation, or registry changes on this development host. Release downloads for pinning are read-only research outside test execution. Current baseline: `a28ac55`; `tests/integration.sh` passed with expected checkout-name warnings. PowerShell 7 portable tests do not certify Windows-native Registry, ACL, Junction, Weasel deployment, process isolation, Raycast, or residual reparse-race behavior.
