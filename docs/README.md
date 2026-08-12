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

## Quick reference

- Installer: `./install.sh` (see [README](../README.md))
- Agent guidelines: [AGENTS.md](../AGENTS.md)
- Sandbox tests: `./tests/integration.sh`
