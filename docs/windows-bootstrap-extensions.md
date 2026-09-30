# Windows Bootstrap Extensions

**English** | [简体中文](windows-bootstrap-extensions.zh-CN.md)

`windows-bootstrap/install.ps1` accepts a deliberately small external package
interface. An extension is a local `format: 2` JSON manifest. It declares
software only; it cannot supply PowerShell, shell commands, download URLs,
installer arguments, verification commands, or a provider implementation.

Repository-owned code and [`windows-bootstrap/providers/registry.json`](../windows-bootstrap/providers/registry.json)
are the authority for every action taken after parsing.

## Scope and trust boundary

Use `-Profile Extension` only. External packages cannot be combined with
`Base`, `Core`, `Optional`, or `All`.

The public provider allowlist is:

| Provider | Context | Behavior |
| --- | --- | --- |
| `winget` | `elevated`, `user` | Repository-generated silent WinGet invocation, live `winget list` verification, bounded cleanup when this run introduced the package |
| `manual` | `elevated` | Records `manual_required`; performs no install, download, command execution, verification, or cleanup |

`download`, `portable-handoff`, WSL, fonts, profiles, RIME, input methods, and
other built-in behavior are not extension providers. Adding a provider changes
the elevated trust boundary: add repository code, portable tests, this contract,
and applicable Windows 11 native acceptance before enabling it in the registry.

## Authoring a manifest

Start from one of these tracked templates:

- [`extension-winget.json`](../windows-bootstrap/templates/extension-winget.json)
- [`extension-manual.json`](../windows-bootstrap/templates/extension-manual.json)

Root schema:

```json
{
  "format": 2,
  "id": "example-tools",
  "items": []
}
```

Rules:

- Root allows only `format`, `id`, and `items`.
- `format` is exactly integer `2`.
- IDs use lowercase `[a-z][a-z0-9-]{0,63}`. Manifest IDs and item IDs must be
  unique across the submitted set.
- At most 16 manifests, 256 KiB each, 64 items per manifest, and 256 items
  total.
- Files must be ordinary local `.json` files. Reparse paths are rejected.
- JSON must be UTF-8; UTF-8 BOM is accepted.
- Duplicate object fields are rejected, including escaped spellings such as
  `\u0069d` for `id`, so the reviewed text cannot differ from the parsed plan.
- Unknown fields fail closed. Do not include `command`, `installCommand`,
  `installScript`, `verifyCommand`, `url`, `args`, an external `.ps1`, or an
  equivalent escape hatch.

### `winget` item

```json
{
  "id": "example-cli",
  "name": "Example CLI",
  "provider": "winget",
  "version": "winget-latest-stable",
  "architecture": "x64",
  "executionContext": "elevated",
  "source": "winget:Contoso.ExampleCli",
  "wingetId": "Contoso.ExampleCli",
  "wingetSource": "winget",
  "install": {
    "scope": "machine",
    "silent": true,
    "timeoutSeconds": 900
  }
}
```

Allowed item fields are exactly `id`, `name`, `provider`, `version`,
`architecture`, `executionContext`, `source`, `wingetId`, `wingetSource`, and
`install`.

- `version` must be `winget-latest-stable`.
- `architecture` is `x64` or `all`.
- `wingetSource` is exactly `winget` or `msstore`; `source` must exactly equal
  `<wingetSource>:<wingetId>`.
- `executionContext: elevated` requires `install.scope: machine`.
- `executionContext: user` requires `install.scope: user`. It runs only from
  the existing same-SID, interactive, Medium-integrity user phase.
- `install.silent` must be `true`; `timeoutSeconds` is an integer from 1 to
  900.

The extension cannot customize WinGet flags. Bootstrap generates:

```text
--silent --accept-source-agreements --accept-package-agreements
--disable-interactivity --scope <machine|user>
```

Cleanup and verification are fixed to repository-owned `winget uninstall` and
`winget list` contracts. Existing packages are not upgraded or removed.

### `manual` item

```json
{
  "id": "vendor-gui-tool",
  "name": "Vendor GUI Tool",
  "provider": "manual",
  "version": "manual-review",
  "architecture": "x64",
  "executionContext": "elevated",
  "source": "manual:vendor/gui-tool",
  "checksum": "manual-review",
  "reason": "Vendor workflow requires visible interactive confirmation."
}
```

Allowed item fields are exactly `id`, `name`, `provider`, `version`,
`architecture`, `executionContext`, `source`, `checksum`, and `reason`.

`manual` is an explicit boundary, not an installer:

- Context is only `elevated`.
- `version` and `checksum` are exactly `manual-review`.
- `source` matches `manual:<lowercase-safe-reference>`.
- `reason` is required.
- Result is `manual_required`; no installer, downloader, verifier, or cleanup
  runs.

## Plan, approval, and execution

First produce a read-only plan:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-bootstrap\install.ps1 `
  -Profile Extension `
  -ExtensionManifest C:\path\tools.json `
  -PlanOnly
```

The JSON result contains `hash`. Review every package and approve that exact
hash in a separate command:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-bootstrap\install.ps1 `
  -Profile Extension `
  -ExtensionManifest C:\path\tools.json `
  -ApprovePlan <64-lowercase-hex-hash>
```

The hash is a canonical UTF-8 SHA-256 projection of normalized items and
manifest provenance. It binds manifest ID, absolute local manifest path, and
manifest file SHA-256. Moving the manifest to another path creates a different
plan hash even when its bytes are identical.

A mutating extension invocation requires the matching `-ApprovePlan`. An
unapproved or malformed extension is rejected before machine state, logs,
locks, caches, backups, UAC, WinGet discovery, or a package action.

`-PlanOnly` is read-only and prints JSON. `-DryRun` parses the plan and reports
skipped work but creates no state/report/log/lock/cache, does not elevate, and
does not call an installer, WinGet, host policy, Registry, WSL, profile, or
input-method discovery.

## UAC, resume, and provenance

A normal-user extension run parses raw manifests once, writes
`%LOCALAPPDATA%\WindowsBootstrap\UserPhase\<runId>\package-plan.json`, then
uses that protected snapshot for the normal-user phase, UAC child, and Resume.
The snapshot root and file must be plain paths with a protected DACL granting
FullControl only to the owner SID and `SYSTEM`.

The snapshot binds run ID, owner SID, profile, approval hash, creation window,
normalized plan, manifest SHA-256 records, and reconstructed plan hash. Every
reader validates all of them and fails closed. UAC child parameters remove
`-ExtensionManifest` and replace it with only the protected snapshot plus the
approved hash.

`Resume`, `Verify`, and `CleanupFailed` use the state-recorded protected
snapshot/hash pair; they reject a raw manifest, reject caller attempts to
substitute a different snapshot or approval, and reject a persisted state that
is not an Extension run. A stale, foreign, malformed, reparse, ACL-invalid, or
tampered snapshot blocks package work.

A user-context extension WinGet package follows the existing normal-user
handoff contract. Its handoff also carries `packagePlanHash`; the elevated
phase requires it to match the protected plan before accepting user results.

## Validation

Portable coverage lives in
[`windows-bootstrap/tests/run.ps1`](../windows-bootstrap/tests/run.ps1). It
checks parser/schema and duplicate-field rejection, singleton JSON arrays on
Windows PowerShell 5.1, UTF-8 BOM input, canonical hashing, provider/context
restrictions, duplicate IDs, manifest limits, snapshot protection/tamper
rejection, UAC/Resume provenance helpers, and read-only entry-point regressions
for `-PlanOnly`, `-DryRun`, malformed schemas, and persisted
`Verify`/`CleanupFailed` provenance.

Portable coverage passes on the host under Windows PowerShell 5.1 and
PowerShell 7. A disposable Windows 11 guest (build 26200, PS 5.1.26100.7920,
pwsh 7.6.6) also passed both suites 58/58 when run with a Medium-integrity
Limited token, and reproduced the read-only real entry-point behavior:
`-PlanOnly` emits the approval hash, `-DryRun` creates no state, an
unknown-field manifest fails before state, and a raw `-ExtensionManifest` on
`Resume` is rejected.

That native run also covered the mutating path: a Limited (Medium-integrity)
scheduled task in the guest created the protected snapshot, opened the real
UAC child, and the elevated child installed and live-verified
`zufuliu.notepad4` from the approved plan; state reached `completed`, the
recorded plan hash matched the approval and snapshot, and the snapshot ACL
contained only the owner SID and `SYSTEM`.

That native evidence also covers the user-context path: a Limited
(Medium-integrity) parent installed a `executionContext: user` WinGet item,
wrote the protected snapshot plus `handoff.json`, and the elevated child
imported and live-verified it. The recorded handoff shows
`IsAdministrator: false` with `S-1-16-8192`, the plan hash matches the
approval, and the snapshot/handoff DACLs are owner/SYSTEM-only.

Still open: `manual` items in a real run and any provider other than
`winget`/`manual`. Do not claim those without a new guest acceptance bundle.

Portable tests do not prove a real package installation, UAC prompt, ACL
behavior, or WinGet result. Provider changes that mutate a Windows host need
separate Windows 11 x64 guest acceptance evidence.
