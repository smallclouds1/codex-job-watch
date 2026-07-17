# Codex Job Watch

[![Windows tests](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml/badge.svg)](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml)

English | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

A Codex plugin for reliable long-running Windows commands. It keeps durable state and logs while giving you two clear interaction modes:

- **Foreground wait:** the current Codex task stays visibly running and waits silently until the command reaches a terminal state.
- **Background notify:** the current task is released immediately; a dedicated background Codex task waits without heartbeat polling and posts one completion message back.

## Why use it?

A global prompt such as “remember to wait” only changes model behavior. It does not provide durable process state, logs, cancellation, exit-code preservation, or a later message to the originating task. Codex Job Watch supplies those mechanics while keeping the workflow generic.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 or later
- Codex with plugin support
- Background notification additionally requires Codex task creation and task messaging tools. The PowerShell runner works independently without them.

## Install

Install directly from GitHub:

```powershell
codex plugin marketplace add smallclouds1/codex-job-watch
codex plugin add codex-job-watch@smallclouds1-tools
```

For local development, clone the repository and add the checkout instead:

```powershell
codex plugin marketplace add <path-to-this-repository>
codex plugin add codex-job-watch@smallclouds1-tools
```

## Use from Codex

You can describe the desired mode in normal language.

Foreground example:

```text
Use $codex-job-watch to run `npm run build` in foreground-wait mode.
Wait silently until it finishes and then report the terminal result.
```

Background example:

```text
Use $codex-job-watch to run this export in background-notify mode.
Return this task now and post one message here when the job finishes.
```

If you do not specify a mode, Codex should choose foreground wait when your next step depends on the result, and background notify when the work can safely continue independently.

## Direct PowerShell runner

```powershell
$tool = ".\plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
```

Start and wait in the current terminal:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool run `
  -Root (Get-Location).Path `
  -Cwd (Get-Location).Path `
  -Name "build" `
  -Command "npm run build"
```

Start a detached job:

```powershell
$started = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool start `
  -Root (Get-Location).Path `
  -Name "export" `
  -Command ".\export.ps1" | ConvertFrom-Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool wait `
  -Job $started.job_dir
```

## Runner actions

| Action | Purpose |
| --- | --- |
| `run` | Start a job and wait for its terminal result. |
| `start` | Start a detached job and return JSON metadata. |
| `wait` | Wait for an existing job. |
| `status` | Print the current `STATE.json`. |
| `list` | List jobs under the selected root. |
| `cancel` | Request cancellation and stop the recorded process tree. |
| `wait-path` | Wait for matching files to exist and remain stable. |
| `notification-status` | Check whether completion was already reported. |
| `mark-notified` | Persist the one-shot notification marker. |

Wait exit codes: `0` succeeded, `1` failed, `124` timed out, `130` cancelled.

## Files and recovery

Each job is stored under `<root>/_task/jobs/<timestamp-name>/` with:

- `STATE.json` — atomic state snapshot
- `result.json` — terminal result
- `worker.log` / `worker.err.log` — stdout and stderr
- `command.ps1` or `command.cmd` — command material
- `notification.sent.json` — completion-message marker, when used

The Windows worker and its logs survive the originating tool call. If Codex itself is fully closed, the OS job can continue, but a background notification task may need to be resumed after Codex starts again.

## Safety and limitations

- `-Command` executes trusted local code with the permissions of the current Windows user.
- Do not place secrets directly in command text; command material is stored in the job directory.
- Always scope management actions to the exact project root or job directory. The skill is designed not to scan or cancel unrelated jobs.
- Sending a task message and writing its marker cannot be one atomic transaction. A crash between them can produce one duplicate message; completion messages include a stable job ID for this reason.
- This plugin is Windows-focused. It does not currently implement a Unix runner.

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-job.tests.ps1
```

Tests use a unique directory under `%TEMP%` and never inspect existing project jobs.

## Uninstall

```powershell
codex plugin remove codex-job-watch@smallclouds1-tools
codex plugin marketplace remove smallclouds1-tools
```

## License

[MIT](LICENSE)
