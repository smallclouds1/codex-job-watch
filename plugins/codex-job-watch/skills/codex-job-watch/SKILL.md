---
name: codex-job-watch
description: Run long-lived Windows commands as durable jobs with logs, cancellation, resumable state, silent foreground waiting, or a one-shot completion message back to the originating Codex task. Use for commands that may outlive one tool call, need reliable waiting without narration, or should finish in a separate background Codex task without heartbeat polling.
---

# Codex Job Watch

Use the bundled `scripts/codex-job.ps1`. Keep each invocation scoped to the user's current project root or an explicitly chosen root. Never scan or operate on unrelated job roots.

## Choose a mode

- `foreground-wait`: use when the user wants the current Codex task visibly busy until the command finishes. Run the `run` action in one blocking tool call. While it is running, do not narrate, inspect other files, or switch tasks. Return only after terminal state.
- `background-notify`: use when the user wants the current Codex task released immediately and a completion message later. Start the job, create one dedicated background Codex task to wait, then return. Do not use heartbeat or recurring automation.
- Plain `start`: use only when the user wants a detached job and will check it manually.

## Foreground wait

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill>/scripts/codex-job.ps1 run -Root <project-root> -Cwd <working-directory> -Name <name> -Command <command>
```

The tool call itself is the wait. Do not issue commentary while blocked. A successful terminal result exits 0; failed, cancelled, and timed-out waits use nonzero exit codes and emit JSON.

## Background notify

1. Start with action `start` and retain `job_dir` from its JSON.
2. Identify the originating Codex task ID and its project.
3. Create exactly one background Codex task in that project. Do not override the user's model unless requested. Use low reasoning for this mechanical waiter when supported.
4. Give the waiter the absolute script path, `job_dir`, and originating task ID. Its instructions must be limited to:
   - call `notification-status`; if already notified, archive itself without sending;
   - call `wait -Job <job_dir>` in one blocking tool call;
   - send one concise completion message to the originating task with status, job id, and log/result paths;
   - after a successful send, call `mark-notified -Job <job_dir> -ThreadId <origin-id>`;
   - archive its own task;
   - perform no other work and provide no progress narration.
5. Tell the user the job was detached and notification is armed. Do not wait in the originating task.

If task-creation or task-messaging tools are unavailable, say that automatic in-chat notification is unavailable and fall back to plain `start`; do not fake it with heartbeat polling.

## Operations

Use `status`, `wait`, `list`, or `cancel` only against the job root or exact `job_dir` already in scope. Use `wait-path` when completion is defined by stable output files rather than a process exit.

Read [references/contract.md](references/contract.md) for state files, exit codes, restart behavior, and limitations when implementing integrations or debugging the runner.

## Safety

- Treat `-Command` as trusted local code supplied or approved by the user.
- Prefer absolute `-Root`, `-Cwd`, and `-Job` paths.
- Never cancel, delete, or migrate jobs outside the current task's exact root.
- Do not claim notification is durable across a full Codex app shutdown: the OS job remains durable, but the background Codex waiter may need to be resumed after the app restarts.
