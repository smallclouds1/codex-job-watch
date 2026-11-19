---
name: codex-job-watch
description: Run or monitor a durable Windows Job. By default, keep the current Codex chat in one foreground tool call until the result is ready. Supports logs, cancellation, stable-artifact waits, and explicitly requested background notifications. Use for 后台任务、占用会话、静默等待、监控 or 完成通知.
---

# Codex Job Watch

Use the bundled `scripts/codex-job.ps1`. Keep each invocation scoped to the user's current project root or an explicitly chosen root. Never scan or operate on unrelated job roots.

## Job ownership

The originating chat owns a running job. For foreground work, keep the same `run`, `wait`, or `wait-path` invocation pending until completion. Before ending the turn early in explicitly requested background-notify mode, establish one visible waiter task and arm it as described below.

Plain `start`, a promised future check, a subagent that is merely running, a heartbeat, an automation, a resumable tool handle, or text saying “notification is armed” does not satisfy ownership. Before any `final` after `start`, the originating task must call `finalization-status -Job <job_dir> -ThreadId <origin-id>`. Exit code `23` means **stop: do not final**. Fall back to one blocking foreground `wait`, or successfully create and arm the waiter. Never invent task IDs or write `waiter.armed.json` manually.

If waiter creation, waiter messaging, or the immediate active snapshot fails, do not claim detachment and do not final. Use foreground wait. Do not substitute heartbeat except for a user-requested exact future-time wakeup.

## Waiting on built-in subagents

Allow at most one short `wait_agent` attempt when waiting on an in-process subagent. If the runtime is unknown or that wait does not reach terminal state, do not repeatedly wake or poll the subagent from the originating task. Before starting, give the subagent an absolute stable terminal marker or result path under the current project root and require it to write that artifact only after terminal state. Then make exactly one blocking `codex-job-watch` `foreground-wait` or `wait-path` call against that artifact; while blocked, do not do other work or send progress narration. If a dedicated background waiter is used instead, create exactly one and send exactly one terminal completion message.

## Choose a mode

- Default to `foreground-wait` for short, long and unknown durations. Hold the originating chat until the runner returns. On Codex Code Mode use the single-call recipe below.
- Choose `background-notify` when the user explicitly wants to release the current chat and receive a later completion message. Use the separate-waiter protocol below.
- Plain `start` is only a primitive. It must immediately transition to `background-notify` and `arm-waiter`, or to a blocking foreground `wait`. It is never by itself a valid reason for the originating task to end.

The only user-visible messages for a long job are one launch acknowledgement and one terminal completion message. Never send elapsed-time or no-result updates such as “still running”, “waiting for several minutes”, “continuing to wait”, or “no response yet”. A tool yield, resumable cell ID, empty output, or unchanged state is not a reportable event.

## Foreground wait

For a new command use `run`. For an existing job use `wait -Job <absolute-job-dir>`. For an artifact use `wait-path`. The runner waits without a deadline by default. Keep the outer tool call pending for the same wait.

**Codex Code Mode** (`functions.exec` with `tools.exec_command` and `tools.write_stdin`). Use this JavaScript as one tool call. Keep the pragma on its **first line**. Fill in the installed runner path, working directory and command. Use a PowerShell shell for the invocation. For an existing Job or artifact, change only the PowerShell invocation to the corresponding action.

```javascript
// @exec: {"yield_time_ms": 2147483647}
const runner = "C:/path/to/codex-job.ps1";
const cwd = "C:/work/example";
const name = "build";
const command = "npm run build";
const ps = value => "'" + value.replace(/['\u2018-\u201b]/g, ch => ch + ch) + "'";
const cmd = `& ${ps(runner)} run -Root ${ps(cwd)} -Cwd ${ps(cwd)} -Name ${ps(name)} -Command ${ps(command)}\nexit $LASTEXITCODE`;

let part = await tools.exec_command({cmd, workdir: cwd, yield_time_ms: 1000});
let output = part.output ?? "";
while (part.exit_code == null) {
    if (part.session_id == null) {
        throw new Error("Lost the shell handle. Recover the existing Job before continuing.");
    }
    part = await tools.write_stdin({session_id: part.session_id, chars: "", yield_time_ms: 30000});
    output += part.output ?? "";
}
text({exit_code: part.exit_code, output});
```

The outer pragma requests a long foreground window (about 24.9 days). Shorter shell waits are renewed **inside this JavaScript**. Emit the result once, after the shell exits. A model-issued one-minute `functions.wait` loop would generate another model response on every yield. `-IntervalSec` controls the PowerShell runner's local state checks.

If the host nevertheless returns a Code Mode cell ID, resume that **same cell** with the longest supported `functions.wait` window (on this surface, request `yield_time_ms: 2147483647`). A forced host return can require another model response. Keep the existing Job and cell handles.

**Direct blocking shell.** When the host can keep a shell invocation pending, run the action directly:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File <skill>/scripts/codex-job.ps1 run -Root <project-root> -Cwd <working-directory> -Name <name> -Command <command>
```

The terminal JSON carries the Job state and log paths. A successful job exits 0. A failed or cancelled job returns its terminal result with a nonzero tool exit. An explicitly bounded wait can return `wait_timeout` while the worker is still running. Continue using that same Job if completion is still requested. A yield-only host without a blocking bridge can require model-side resumptions. Report that host limitation when zero intermediate responses are required.

## Background notify

1. Start with action `start` and retain `job_dir` from its JSON.
2. Identify the originating Codex task ID and its project.
3. Create exactly one background Codex task in that project. Do not override the user's model unless requested. Use low reasoning for this mechanical waiter when supported.
4. Give the waiter the absolute script path, `job_dir`, and originating task ID. Its instructions must be limited to:
   - call `notification-status`; if already notified, archive itself without sending;
   - call `wait -Job <job_dir>` using the same foreground transport described above;
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
