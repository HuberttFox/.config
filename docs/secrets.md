# Secrets

**English** | [简体中文](secrets.zh-CN.md)

How this repository handles secrets and local overrides.

## Contract

- **Never put secret values in tracked files.** `.env.example` contains variable names with empty values only.
- `.env` and generated `raycast/ai/providers.yaml` are gitignored and remain local.
- Other gitignored local overrides: `git/config.local`, `zsh/env.local.zsh`.

## Setup

```bash
cp .env.example .env
chmod 600 .env
```

Fill local values:

```dotenv
CONTEXT7_API_KEY=
RAYCAST_MODELSCOPE_API_KEY=
RAYCAST_PERPLEXITY_API_KEY=
```

## Zsh loading

Zsh loads simple `NAME=VALUE` assignments from `.env` (`zsh/env.zsh`). It does not evaluate arbitrary shell:

- Lines must match `NAME=VALUE`; invalid lines are ignored with a warning.
- Multiline values are rejected.
- No command substitution or shell execution.

## Raycast renderer

Raycast does not interpolate `.env`. Generate its ignored provider file explicitly:

```bash
./scripts/render-raycast-providers
```

Renderer behavior:

- Reads `RAYCAST_MODELSCOPE_API_KEY` and `RAYCAST_PERPLEXITY_API_KEY` from `.env` (overridable via `DOTFILES_ENV_FILE` and `RAYCAST_PROVIDERS_FILE`).
- Fails on missing values, duplicate variables, or invalid key characters.
- Writes atomically (temp file + rename) with mode `0600`.
- Never prints secret values.

## Security rules

- Environment loaders parse assignments; never evaluate arbitrary shell code.
- Secret renderer tests use dummy values and assert no output leakage plus `0600` permissions.
- Raycast template/renderer changes require integration tests with dummy keys, missing-value failure, no output leakage, and mode `0600`.
