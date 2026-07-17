# Codex Job Watch

[![Windows 测试](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml/badge.svg)](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml)

[English](README.md) | 简体中文 | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

这是一个让 Codex 在 Windows 上可靠执行长时间命令的插件。它会保留持久状态和日志，并提供两种清晰的交互模式：

- **前台等待（foreground-wait）：** 当前 Codex 任务保持“正在运行”，期间不口播，直到命令进入最终状态。
- **后台通知（background-notify）：** 当前任务立即释放；一个独立的后台 Codex 任务负责等待，不使用心跳轮询，完成后向原任务发送一条消息。

## 为什么需要它？

在全局提示词中写“长任务必须等待”只能约束模型行为，不能提供持久进程状态、日志、取消、退出码保存，也不能在原任务结束当前回合后主动回信。Codex Job Watch 补齐的是这些执行机制，而且不绑定任何具体项目。

## 环境要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更高版本
- 支持插件的 Codex
- 后台通知还需要 Codex 提供创建任务和向任务发送消息的工具；PowerShell runner 本身可以独立使用。

## 安装

直接从 GitHub 安装：

```powershell
codex plugin marketplace add smallclouds1/codex-job-watch
codex plugin add codex-job-watch@smallclouds1-tools
```

本地开发时，也可以克隆仓库后添加本地目录：

```powershell
codex plugin marketplace add <仓库本地路径>
codex plugin add codex-job-watch@smallclouds1-tools
```

## 在 Codex 中使用

直接用自然语言说明模式即可。

前台等待示例：

```text
使用 $codex-job-watch 以前台等待模式运行 `npm run build`。
等待期间不要口播，直到结束后再报告最终结果。
```

后台通知示例：

```text
使用 $codex-job-watch 以后台通知模式执行这次导出。
现在结束当前回合，任务完成后在这里发一条消息通知我。
```

如果没有指定模式，后续步骤依赖结果时应选择前台等待；任务可以安全独立完成时应选择后台通知。

## 直接使用 PowerShell runner

```powershell
$tool = ".\plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
```

启动并在当前终端等待：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool run `
  -Root (Get-Location).Path `
  -Cwd (Get-Location).Path `
  -Name "build" `
  -Command "npm run build"
```

启动分离任务，然后等待：

```powershell
$started = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool start `
  -Root (Get-Location).Path `
  -Name "export" `
  -Command ".\export.ps1" | ConvertFrom-Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool wait `
  -Job $started.job_dir
```

## Runner 操作

| 操作 | 用途 |
| --- | --- |
| `run` | 启动任务并等待最终结果。 |
| `start` | 启动分离任务并返回 JSON 元数据。 |
| `wait` | 等待已有任务。 |
| `status` | 输出当前 `STATE.json`。 |
| `list` | 列出指定根目录下的任务。 |
| `cancel` | 请求取消并终止记录的进程树。 |
| `wait-path` | 等待匹配文件出现并保持稳定。 |
| `notification-status` | 检查完成通知是否已经发送。 |
| `mark-notified` | 写入一次性通知标记。 |

等待退出码：`0` 成功、`1` 失败、`124` 等待超时、`130` 已取消。

## 文件与恢复

每个任务保存在 `<root>/_task/jobs/<时间戳-名称>/`：

- `STATE.json`：原子写入的状态快照
- `result.json`：最终结果
- `worker.log` / `worker.err.log`：标准输出和错误输出
- `command.ps1` 或 `command.cmd`：实际命令内容
- `notification.sent.json`：已发送完成消息时的标记

Windows worker 和日志不会因为原工具调用结束而消失。如果完全关闭 Codex，系统任务仍可继续运行，但后台通知任务可能需要在 Codex 再次启动后恢复。

## 安全与限制

- `-Command` 会以当前 Windows 用户权限执行可信的本地代码。
- 不要把密钥直接写进命令文本，因为命令内容会保存在任务目录中。
- 管理任务时必须指定准确的项目根目录或 job 目录；技能不会主动扫描或取消无关任务。
- 发送会话消息和写入通知标记无法形成同一个原子事务；如果恰好在两者之间崩溃，恢复后可能重复通知一次，因此消息会包含稳定的 job ID。
- 当前版本只面向 Windows，尚未实现 Unix runner。

## 测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-job.tests.ps1
```

测试只使用 `%TEMP%` 下的唯一目录，不会读取现有项目的 job。

## 卸载

```powershell
codex plugin remove codex-job-watch@smallclouds1-tools
codex plugin marketplace remove smallclouds1-tools
```

## 许可证

[MIT](LICENSE)
