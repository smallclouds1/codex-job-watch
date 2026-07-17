# Runner contract

## Storage

Each run lives under `<root>/_task/jobs/<timestamp-name>/`. Important files:

- `STATE.json`: atomic, mutex-protected state snapshot.
- `result.json`: terminal result.
- `worker.log` and `worker.err.log`: redirected command output.
- `command.ps1` or `command.cmd`: executable command material. The raw command is deliberately not duplicated in `STATE.json`.
- `cancel.flag`: cooperative cancellation request.
- `notification.sent.json`: one-shot notification marker written only after a message is sent.

## Actions and exit codes

- `run`: start and wait.
- `start`: detach and print job metadata.
- `wait`: wait for a known job.
- `status`, `list`, `cancel`: management operations scoped by `-Root` or exact `-Job`.
- `wait-path`: wait until matching artifacts reach the requested count and remain stable.
- `notification-status`, `mark-notified`: support idempotent completion messaging.

Wait exits: `0` succeeded, `1` failed, `124` wait timeout, `130` cancelled.

## Durability boundary

The Windows worker and its logs survive the originating Codex tool call. In `background-notify`, notification depends on a separate Codex task remaining runnable. A full app shutdown does not stop the OS job, but the waiter may need to be resumed after the app returns.

## Notification delivery

`notification.sent.json` prevents normal repeated delivery after the first successful send. Sending a task message and writing the marker cannot be one atomic transaction; a crash between those operations can produce one duplicate after recovery. Completion messages should therefore include the stable job id and remain safe to receive twice.
