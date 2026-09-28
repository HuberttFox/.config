# Documentation

**English** | [简体中文](README.zh-CN.md)

Technical documentation for the dotfiles bootstrap repository.

## Index

| Doc | Contents |
| --- | --- |
| [Architecture](architecture.md) | Installer pipeline, component model, transaction system, Zsh policy, scope and ignored paths |
| [Components](components.md) | Per-component reference: formulae, taps, casks, apply/verify behavior |
| [Development](development.md) | Setup, validation, Bash style, component authoring checklist |
| [Troubleshooting](troubleshooting.md) | Common failures, error messages, and fixes |
| [Secrets](secrets.md) | `.env` contract, renderer behavior, security rules |
| [Windows bootstrap](../windows-bootstrap/README.md) | Unattended Windows 11 entry, lifecycle state machine, recovery, manifests |
| [Windows RIME](../windows/README.md) | Separate Windows 11/PowerShell 7 x64 RIME profiles, recovery/report semantics, and native acceptance boundary |
| [Windows acceptance evidence](handoff-windows-rime-native-acceptance-evidence.md) | Disposable-guest PASS/BLOCKED/UNVERIFIED record for bootstrap and RIME |

## Quick reference

- macOS installer: `./install.sh` (see [README](../README.md))
- Windows bootstrap: `pwsh.exe -NoProfile -File .\windows-bootstrap\install.ps1` on Windows 11 x64 (Windows PowerShell 5.1 or PowerShell 7); `-DryRun` is mutation-free.
- Windows RIME: `pwsh.exe -NoProfile -File .\windows\install.ps1` on Windows 11 x64; `bootstrap.sh` dispatches only from Windows MINGW/MSYS/Cygwin.
- Agent guidelines: [AGENTS.md](../AGENTS.md)
- macOS sandbox tests: `./tests/integration.sh`
- Windows portable tests: `pwsh -NoProfile -File .\tests\windows\run.ps1`; they are not Windows-native acceptance.
