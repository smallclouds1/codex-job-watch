---
name: codex-job-watch
description: Run long-lived Windows commands as durable jobs with logs, cancellation, resumable state, silent foreground waiting, or a one-shot completion message back to the originating Codex task. Use whenever the user says job, Job, 后台任务, 占用会话, 静默等待, 监控, 完成通知, 稍后汇报, or when a command may outlive one tool call. Every running job must either block the current task or have one proven separate waiter task; never final while an unowned job is still running.
---

# Codex Job Watch

Use the bundled `scripts/codex-job.ps1`. Keep each invocation scoped to the user's current project root or an explicitly chosen root. Never scan or operate on unrelated job roots.

## Non-negotiable ownership invariant

Starting a Job is not a handoff. While a Job is non-terminal, the originating Codex task may send `final` only after exactly one of these states is true:

1. **Foreground owner:** the originating task is blocked in the same `run`, `wait`, or `wait-path` tool call until terminal state. It does no other work and sends no waiting updates.
2. **Background owner:** one separate visible Codex waiter task was successfully created, received the exact `job_dir` and origin task ID, and an immediate task snapshot proved that waiter active. Only then call `arm-waiter` with both task IDs.

Plain `start`, a promised future check, a subagent that is merely running, a heartbeat, an automation, a resumable tool handle, or text saying “notification is armed” does not satisfy ownership. Before any `final` after `start`, the originating task must call `finalization-status -Job <job_dir> -ThreadId <origin-id>`. Exit code `23` means **stop: do not final**. Fall back to one blocking foreground `wait`, or successfully create and arm the waiter. Never invent task IDs or write `waiter.armed.json` manually.

If waiter creation, waiter messaging, or the immediate active snapshot fails, do not claim detachment and do not final. Use foreground wait. Do not substitute heartbeat except for a user-requested exact future-time wakeup.

## Waiting on built-in subagents

Allow at most one short `wait_agent` attempt when waiting on an in-process subagent. If the runtime is unknown or that wait does not reach terminal state, do not repeatedly wake or poll the subagent from the originating task. Before starting, give the subagent an absolute stable terminal marker or result path under the current project root and require it to write that artifact only after terminal state. Then make exactly one blocking `codex-job-watch` `foreground-wait` or `wait-path` call against that artifact; while blocked, do not do other work or send progress narration. If a dedicated background waiter is used instead, create exactly one and send exactly one terminal completion message.

## Choose a mode

- `background-notify` is the default when runtime may exceed 60 seconds or is unknown. Start the job, create one dedicated background Codex task to wait, then return. Do not use heartbeat or recurring automation.
- `foreground-wait` is only for commands expected to finish inside one uninterrupted tool call, normally within 60 seconds, or when the user explicitly requests this mode. Run the `run` action in one blocking tool call. While it is running, do not narrate, inspect other files, or switch tasks. Return only after terminal state.
- Plain `start` is only a primitive. It must immediately transition to `background-notify` and `arm-waiter`, or to a blocking foreground `wait`. It is never by itself a valid reason for the originating task to end.

The only user-visible messages for a long job are one launch acknowledgement and one terminal completion message. Never send elapsed-time or no-result updates such as “still running”, “waiting for several minutes”, “continuing to wait”, or “no response yet”. A tool yield, resumable cell ID, empty output, or unchanged state is not a reportable event.

## Foreground wait

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill>/scripts/codex-job.ps1 run -Root <project-root> -Cwd <working-directory> -Name <name> -Command <command>
```

The tool call itself is the wait. Do not issue commentary while blocked. If the host returns a resumable wait handle before terminal state, resume that handle without commentary; do not turn each yield into a progress update. If repeated yielding is likely, use `background-notify` instead. A successful terminal result exits 0; failed, cancelled, and timed-out waits use nonzero exit codes and emit JSON.

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
5. Take one immediate task snapshot. It must show the created waiter active and must match the task ID just created.
6. Call `arm-waiter -Job <job_dir> -ThreadId <origin-id> -WaiterThreadId <waiter-id>`. Do not write the marker yourself.
7. Call `finalization-status -Job <job_dir> -ThreadId <origin-id>`. Only exit code `0` permits the originating task to end.
8. Tell the user once that the job was detached and notification is armed. Do not wait or post progress updates in the originating task.

If task-creation or task-messaging tools are unavailable, automatic detachment is unavailable. Fall back to a blocking foreground `wait`; do not fake it with heartbeat polling and do not leave a bare `start` behind.

## Operations

Use `status`, `wait`, `list`, or `cancel` only against the job root or exact `job_dir` already in scope. Use `wait-path` when completion is defined by stable output files rather than a process exit.

Read [references/contract.md](references/contract.md) for state files, exit codes, restart behavior, and limitations when implementing integrations or debugging the runner.

## Safety

- Treat `-Command` as trusted local code supplied or approved by the user.
- Prefer absolute `-Root`, `-Cwd`, and `-Job` paths.
- Never cancel, delete, or migrate jobs outside the current task's exact root.
- Do not claim notification is durable across a full Codex app shutdown: the OS job remains durable, but the background Codex waiter may need to be resumed after the app restarts.
