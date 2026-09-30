# Windows Bootstrap 扩展

[English](windows-bootstrap-extensions.md) | **简体中文**

`windows-bootstrap/install.ps1` 提供一个刻意很小的外部软件接口。扩展是本地
`format: 2` JSON manifest，只能声明软件；不能提供 PowerShell、shell 命令、下载
URL、安装参数、验证命令或 provider 实现。

解析后的所有动作都只能由仓库代码和
[`windows-bootstrap/providers/registry.json`](../windows-bootstrap/providers/registry.json)
决定。

## 范围与信任边界

只能使用 `-Profile Extension`。外部软件不能与 `Base`、`Core`、`Optional`、`All`
混合。

公开 provider allowlist：

| Provider | context | 行为 |
| --- | --- | --- |
| `winget` | `elevated`、`user` | 仓库生成静默 WinGet 调用，实时 `winget list` 验证；仅本次运行新装的包可做有界清理 |
| `manual` | `elevated` | 记录 `manual_required`；不安装、不下载、不执行命令、不验证、不清理 |

`download`、`portable-handoff`、WSL、字体、profile、RIME、输入法和其他内建行为都
不是 extension provider。新增 provider 等于扩大提权安装器的信任边界，必须同时提交
仓库实现、portable tests、本文档契约，以及适用的 Windows 11 原生验收。

## 编写 manifest

从受跟踪模板开始：

- [`extension-winget.json`](../windows-bootstrap/templates/extension-winget.json)
- [`extension-manual.json`](../windows-bootstrap/templates/extension-manual.json)

根 schema：

```json
{
  "format": 2,
  "id": "example-tools",
  "items": []
}
```

规则：

- 根只允许 `format`、`id`、`items`。
- `format` 必须是整数 `2`。
- ID 必须为小写 `[a-z][a-z0-9-]{0,63}`。本次提交中的 manifest ID 与 item ID 都必须唯一。
- 最多 16 个 manifest，每个最多 256 KiB、64 个 item；总数最多 256 个 item。
- 文件必须是本地普通 `.json` 文件，拒绝 reparse path。
- JSON 必须 UTF-8；允许 UTF-8 BOM。
- 重复的 JSON 对象字段会被拒绝，包括 `\u0069d` 这类转义写法，确保人工审查的文本与
  实际计划一致。
- 未知字段 fail closed。不得添加 `command`、`installCommand`、`installScript`、
  `verifyCommand`、`url`、`args`、外部 `.ps1` 或等价逃逸入口。

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

允许字段严格为 `id`、`name`、`provider`、`version`、`architecture`、
`executionContext`、`source`、`wingetId`、`wingetSource`、`install`。

- `version` 只能是 `winget-latest-stable`。
- `architecture` 只能是 `x64` 或 `all`。
- `wingetSource` 只能是 `winget` 或 `msstore`；`source` 必须精确等于
  `<wingetSource>:<wingetId>`。
- `executionContext: elevated` 必须配 `install.scope: machine`。
- `executionContext: user` 必须配 `install.scope: user`，且只能在既有的同 SID、
  interactive、Medium-integrity user phase 执行。
- `install.silent` 必须为 `true`；`timeoutSeconds` 必须是 1 到 900 的整数。

扩展不能自定义 WinGet flags。Bootstrap 固定生成：

```text
--silent --accept-source-agreements --accept-package-agreements
--disable-interactivity --scope <machine|user>
```

清理与验证固定为仓库管理的 `winget uninstall`、`winget list` 契约。已存在的软件绝不
升级或卸载。

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

允许字段严格为 `id`、`name`、`provider`、`version`、`architecture`、
`executionContext`、`source`、`checksum`、`reason`。

`manual` 是显式边界，不是安装器：

- 只允许 `elevated` context。
- `version` 与 `checksum` 必须精确为 `manual-review`。
- `source` 必须匹配 `manual:<lowercase-safe-reference>`。
- `reason` 必填。
- 结果为 `manual_required`；不运行安装器、下载器、验证器或清理器。

## 计划、批准与执行

先生成只读计划：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-bootstrap\install.ps1 `
  -Profile Extension `
  -ExtensionManifest C:\path\tools.json `
  -PlanOnly
```

JSON 结果里的 `hash` 是待批准的 package plan。人工检查所有软件后，在独立命令中精确
传入该 hash：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows-bootstrap\install.ps1 `
  -Profile Extension `
  -ExtensionManifest C:\path\tools.json `
  -ApprovePlan <64-lowercase-hex-hash>
```

该 hash 是 normalized item 与 manifest provenance 的 canonical UTF-8 SHA-256 投影。
它绑定 manifest ID、manifest 绝对本地路径和文件 SHA-256。因此同字节文件移动到另一
路径后会产生不同 hash。

变更型 extension 运行必须提供匹配的 `-ApprovePlan`。未批准或不合法的 extension 会在
machine state、log、lock、cache、backup、UAC、WinGet discovery 和 package action 之前
被拒绝。

`-PlanOnly` 只读并输出 JSON。`-DryRun` 解析计划并记录 skipped，但不创建
state/report/log/lock/cache，不提权，也不调用 installer、WinGet、主机策略、Registry、
WSL、profile 或输入法 discovery。

## UAC、Resume 与 provenance

normal-user extension run 只解析一次原始 manifest，然后写入：

```text
%LOCALAPPDATA%\WindowsBootstrap\UserPhase\<runId>\package-plan.json
```

normal-user phase、UAC child 与 Resume 都只读取该 protected snapshot。snapshot root 和
文件必须为普通 path，并使用 protected DACL：仅 owner SID 与 `SYSTEM` 有 FullControl。

snapshot 绑定 run ID、owner SID、profile、approval hash、创建时间窗、normalized plan、
manifest SHA-256 record 和重建后的 plan hash。每次读取都会全量验证，失败即停止。UAC child
会移除 `-ExtensionManifest`，只接收 protected snapshot 与 approved hash。

`Resume`、`Verify`、`CleanupFailed` 只使用 machine state 记录的 protected
snapshot/hash pair；拒绝 raw manifest，拒绝调用方替换 snapshot 或 approval，也拒绝
persisted state 不是 Extension run 的情况。陈旧、foreign、malformed、reparse、
ACL-invalid 或 tampered snapshot 都会阻止 package work。

user-context extension WinGet 包继续沿用已有 normal-user handoff 合约，handoff 增加
`packagePlanHash`；elevated phase 要求它与 protected plan 相同，才接受 user result。

## 验证

portable coverage 位于
[`windows-bootstrap/tests/run.ps1`](../windows-bootstrap/tests/run.ps1)，覆盖 parser/schema
拒绝、重复 JSON 字段拒绝、Windows PowerShell 5.1 singleton JSON array、UTF-8 BOM、
canonical hash、provider/context 限制、重复 ID、manifest 上限、snapshot 保护/篡改拒绝、
UAC/Resume provenance helper，以及真实入口的 `PlanOnly` / `DryRun`、非法 schema 和
persisted `Verify`/`CleanupFailed` provenance 只读回归。

portable test 不证明真实 package installation、UAC prompt、ACL 行为或 WinGet 结果。会改动
Windows host 的 provider 改动仍需要单独的 Windows 11 x64 guest 原生验收证据。

已完成的只读原生验收：宿主 Windows PowerShell 5.1 与 PowerShell 7 便携 suite 通过；
disposable Windows 11 guest（build 26200、PS 5.1.26100.7920、pwsh 7.6.6）在
Medium-integrity Limited token 下同样 58/58，并复现真实入口行为：`-PlanOnly` 输出
approval hash、`-DryRun` 不创建 state、未知字段 manifest 在创建 state 之前被拒绝、
`Resume` 携带 raw `-ExtensionManifest` 被拒绝。

该原生验收同时覆盖了可变路径：guest 中 Limited（Medium integrity）计划任务创建受保护
snapshot、触发真实 UAC child，elevated child 按已批准计划安装并实时验证
`zufuliu.notepad4`；state 达到 `completed`，记录的 plan hash 与 approval、snapshot 一致，
snapshot ACL 只包含 owner SID 与 `SYSTEM`。

该原生验收也覆盖了 user-context 路径：Limited（Medium integrity）父进程安装
`executionContext: user` 的 WinGet 项，写入 protected snapshot 与 `handoff.json`，
elevated child 导入并实时验证。handoff 记录 `IsAdministrator: false`、
`S-1-16-8192`，plan hash 与 approval 一致，snapshot/handoff DACL 仅 owner/SYSTEM。

仍未验证：真实运行中的 `manual` 项，以及 `winget`/`manual` 之外的 provider。不得在没有新
guest evidence bundle 的情况下宣称通过。
