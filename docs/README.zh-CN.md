# 文档

[English](README.md) | **简体中文**

dotfiles 引导仓库的技术文档。

## 索引

| 文档 | 内容 |
| --- | --- |
| [架构](architecture.zh-CN.md) | 安装流程、组件模型、事务系统、Zsh 策略、范围与忽略路径 |
| [组件](components.zh-CN.md) | 逐组件参考：formula、tap、cask、apply/verify 行为 |
| [开发](development.zh-CN.md) | 环境、验证、Bash 风格、组件编写清单 |
| [故障排查](troubleshooting.zh-CN.md) | 常见失败、报错信息与修复 |
| [密钥](secrets.zh-CN.md) | `.env` 约定、渲染器行为、安全规则 |

## 速查

- 安装器：`./install.sh`（见 [README](../README.zh-CN.md)）
- 代理指南：[AGENTS.md](../AGENTS.md)
- 沙箱测试：`./tests/integration.sh`
