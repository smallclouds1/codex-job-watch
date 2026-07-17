# Codex Job Watch

A Codex plugin for reliable long-running Windows commands.

It offers two interaction modes:

- **Foreground wait:** the current Codex task stays visibly running and waits silently for the command's terminal state.
- **Background notify:** the current task is released immediately; a dedicated background Codex task waits without heartbeat polling and posts one completion message back.

The PowerShell runner keeps atomic state, stdout/stderr logs, terminal results, cancellation, and stable-artifact waiting under the selected project root.

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

No Codex restart is required for the repository tests. Plugin discovery behavior can vary by app version.

## Direct runner usage

```powershell
$tool = ".\plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool run `
  -Root (Get-Location).Path `
  -Name "build" `
  -Command "npm run build"
```

Detached mode uses `start`, followed by `wait -Job <job_dir>` from the returned JSON.

## Test

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-job.tests.ps1
```

Tests use a unique directory under `%TEMP%` and never inspect existing project jobs.

## Limitation

The Windows job survives the originating tool call. Background in-chat notification depends on a Codex background task; after a full Codex app shutdown, that waiter may need to be resumed even though the OS job continues.
