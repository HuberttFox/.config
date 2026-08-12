# 密钥

[English](secrets.md) | **简体中文**

本仓库如何处理密钥与本地覆盖。

## 约定

- **绝不在跟踪文件中放入密钥值。** `.env.example` 只定义变量名，值为空。
- `.env` 与生成的 `raycast/ai/providers.yaml` 已 gitignore，仅保留本地。
- 其他 gitignore 的本地覆盖：`git/config.local`、`zsh/env.local.zsh`。

## 设置

```bash
cp .env.example .env
chmod 600 .env
```

填入本地值：

```dotenv
CONTEXT7_API_KEY=
RAYCAST_MODELSCOPE_API_KEY=
RAYCAST_PERPLEXITY_API_KEY=
```

## Zsh 加载

Zsh 从 `.env` 加载简单的 `NAME=VALUE` 赋值（`zsh/env.zsh`）。不执行任意 shell：

- 行必须匹配 `NAME=VALUE`；非法行会被忽略并告警。
- 多行值会被拒绝。
- 不支持命令替换或 shell 执行。

## Raycast 渲染器

Raycast 不会插值 `.env`。请显式生成其忽略的 provider 文件：

```bash
./scripts/render-raycast-providers
```

渲染器行为：

- 从 `.env` 读取 `RAYCAST_MODELSCOPE_API_KEY` 与 `RAYCAST_PERPLEXITY_API_KEY`（可通过 `DOTFILES_ENV_FILE` 与 `RAYCAST_PROVIDERS_FILE` 覆盖）。
- 缺失值、重复变量或非法字符时失败。
- 原子写入（临时文件 + rename），权限 `0600`。
- 绝不打印密钥值。

## 安全规则

- 环境加载器只解析赋值；绝不评估任意 shell 代码。
- 密钥渲染器测试使用哑值，并断言无输出泄漏且权限为 `0600`。
- Raycast 模板/渲染器改动要求集成测试覆盖：哑密钥、缺失值失败、无输出泄漏、权限 `0600`。
