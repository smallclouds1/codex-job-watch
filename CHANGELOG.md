# Changelog

## 0.1.2 - 2026-08-02

- Fail closed when a generated PowerShell command exits before writing its authoritative `command.exitcode` file.
- Report the missing exit-code condition in both persisted state and terminal results.
- Add a regression test for PowerShell parser failures that previously risked a false-success result.

## 0.1.1 - 2026-07-17

- Add complete English, Simplified Chinese, Traditional Chinese, Japanese, and Korean usage guides.
- Document direct GitHub installation, foreground waiting, background completion notification, recovery, safety, testing, and removal.
- Prevent a harmless `taskkill` race from surfacing as a PowerShell `NativeCommandError` during cancellation.

## 0.1.0 - 2026-07-17

- Initial public release.
- Add durable Windows job state, logs, cancellation, exit-code preservation, and stable-artifact waiting.
- Add silent foreground waiting and one-shot background notification workflows for Codex.
