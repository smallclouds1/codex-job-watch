# Runner contract

## Storage

Each run lives under `<root>/_task/jobs/<timestamp-name>/`. Important files:

- `STATE.json`: atomic, mutex-protected state snapshot.
- `result.json`: terminal result.
- `worker.log` and `worker.err.log`: redirected command output.
- `command.ps1` or `command.cmd`: executable command material. The raw command is deliberately not duplicated in `STATE.json`.
- `cancel.flag`: cooperative cancellation request.
- `notification.sent.json`: one-shot notification marker written only after a message is sent.
- `waiter.armed.json`: ownership marker written only by `arm-waiter` after a separate Codex waiter task has been created and proved active.

## Actions and exit codes

- `run`: start and wait.
- `start`: detach and print job metadata.
- `wait`: wait for a known job.
- `status`, `list`, `cancel`: management operations scoped by `-Root` or exact `-Job`.
- `wait-path`: wait until matching artifacts reach the requested count and remain stable.
- `notification-status`, `mark-notified`: support idempotent completion messaging.
- `arm-waiter`: bind one non-terminal Job to its originating task and one distinct background waiter task.
- `finalization-status`: fail-closed gate for the originating task. It exits `0` only when the Job is terminal or the caller's origin task ID matches a valid waiter arm; an unowned running Job exits `23`.

Wait exits: `0` succeeded, `1` failed, `124` wait timeout, `130` cancelled. Finalization gate exit `23` means the originating task must not send `final` because the Job is still running without a registered waiter owner.

PowerShell jobs fail closed when the generated command script does not write its authoritative `command.exitcode` file. This covers parser/startup failures that occur before the script trap can run and prevents redirected `Start-Process` from reporting a stale zero as success.

## Durability boundary

The Windows worker and its logs survive the originating Codex tool call. In `background-notify`, notification depends on a separate Codex task remaining runnable. A full app shutdown does not stop the OS job, but the waiter may need to be resumed after the app returns.

## Notification delivery

`notification.sent.json` prevents normal repeated delivery after the first successful send. Sending a task message and writing the marker cannot be one atomic transaction; a crash between those operations can produce one duplicate after recovery. Completion messages should therefore include the stable job id and remain safe to receive twice.
