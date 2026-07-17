# Codex Job Watch

[![Windows 테스트](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml/badge.svg)](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml)

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md) | 한국어

Codex에서 Windows의 장시간 명령을 안정적으로 실행하기 위한 플러그인입니다. 지속 가능한 상태와 로그를 보존하며 두 가지 상호작용 모드를 제공합니다.

- **포그라운드 대기(foreground-wait):** 현재 Codex 작업을 실행 중 상태로 유지하고, 중간 설명 없이 명령이 최종 상태가 될 때까지 기다립니다.
- **백그라운드 알림(background-notify):** 현재 작업을 즉시 반환합니다. 별도의 백그라운드 Codex 작업이 하트비트 폴링 없이 기다린 뒤, 완료 시 원래 작업에 메시지 한 건을 보냅니다.

## 왜 필요한가요?

전역 프롬프트에 “장시간 작업은 기다려라”라고 적는 것만으로는 프로세스 상태의 지속성, 로그, 취소, 종료 코드 보존, 원래 작업으로의 후속 알림을 제공할 수 없습니다. Codex Job Watch는 특정 프로젝트에 종속되지 않으면서 이러한 실행 메커니즘을 추가합니다.

## 요구 사항

- Windows 10 또는 Windows 11
- Windows PowerShell 5.1 이상
- 플러그인을 지원하는 Codex
- 백그라운드 알림에는 Codex 작업 생성 및 작업 메시지 전송 도구도 필요합니다. PowerShell runner 자체는 이 도구 없이도 사용할 수 있습니다.

## 설치

GitHub에서 직접 설치합니다.

```powershell
codex plugin marketplace add smallclouds1/codex-job-watch
codex plugin add codex-job-watch@smallclouds1-tools
```

로컬 개발 시에는 저장소를 복제한 뒤 로컬 경로를 추가할 수 있습니다.

```powershell
codex plugin marketplace add <로컬-저장소-경로>
codex plugin add codex-job-watch@smallclouds1-tools
```

## Codex에서 사용

원하는 모드를 자연어로 설명하면 됩니다.

포그라운드 대기 예시:

```text
$codex-job-watch를 사용해 `npm run build`를 foreground-wait 모드로 실행하세요.
완료될 때까지 중간 설명 없이 기다린 후 최종 결과만 보고하세요.
```

백그라운드 알림 예시:

```text
$codex-job-watch를 사용해 이 내보내기를 background-notify 모드로 실행하세요.
현재 턴은 종료하고, 작업이 끝나면 이 작업에 메시지 한 건을 보내세요.
```

모드를 지정하지 않으면 다음 단계가 결과에 의존할 때는 포그라운드 대기, 작업이 독립적으로 안전하게 끝날 수 있을 때는 백그라운드 알림을 선택합니다.

## PowerShell runner 직접 사용

```powershell
$tool = ".\plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
```

현재 터미널에서 시작하고 대기:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool run `
  -Root (Get-Location).Path `
  -Cwd (Get-Location).Path `
  -Name "build" `
  -Command "npm run build"
```

분리된 작업을 시작한 뒤 대기:

```powershell
$started = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool start `
  -Root (Get-Location).Path `
  -Name "export" `
  -Command ".\export.ps1" | ConvertFrom-Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool wait `
  -Job $started.job_dir
```

## Runner 동작

| 동작 | 용도 |
| --- | --- |
| `run` | 작업을 시작하고 최종 결과까지 기다립니다. |
| `start` | 분리된 작업을 시작하고 JSON 메타데이터를 반환합니다. |
| `wait` | 기존 작업을 기다립니다. |
| `status` | 현재 `STATE.json`을 출력합니다. |
| `list` | 선택한 루트 아래의 작업을 나열합니다. |
| `cancel` | 취소를 요청하고 기록된 프로세스 트리를 중지합니다. |
| `wait-path` | 일치하는 파일이 생성되어 안정될 때까지 기다립니다. |
| `notification-status` | 완료 알림이 이미 전송되었는지 확인합니다. |
| `mark-notified` | 일회성 알림 마커를 저장합니다. |

대기 종료 코드: `0` 성공, `1` 실패, `124` 시간 초과, `130` 취소됨.

## 파일과 복구

각 작업은 `<root>/_task/jobs/<타임스탬프-이름>/`에 저장됩니다.

- `STATE.json` — 원자적으로 저장되는 상태 스냅샷
- `result.json` — 최종 결과
- `worker.log` / `worker.err.log` — 표준 출력과 표준 오류
- `command.ps1` 또는 `command.cmd` — 실행할 명령 내용
- `notification.sent.json` — 완료 메시지 전송 마커

Windows worker와 로그는 원래 도구 호출이 끝난 뒤에도 유지됩니다. Codex를 완전히 종료해도 OS 작업은 계속될 수 있지만, 백그라운드 알림 작업은 Codex를 다시 시작한 후 재개해야 할 수 있습니다.

## 안전 및 제한 사항

- `-Command`는 현재 Windows 사용자 권한으로 신뢰할 수 있는 로컬 코드를 실행합니다.
- 명령 내용이 작업 디렉터리에 저장되므로 비밀 정보를 명령문에 직접 넣지 마세요.
- 관리 작업은 정확한 프로젝트 루트 또는 job 디렉터리로 제한하세요. 이 스킬은 관련 없는 작업을 검색하거나 취소하지 않습니다.
- 작업 메시지 전송과 알림 마커 기록은 하나의 원자적 트랜잭션이 될 수 없습니다. 그 사이에 충돌이 발생하면 복구 후 알림이 한 번 중복될 수 있으므로 메시지에는 안정적인 job ID가 포함됩니다.
- 현재 버전은 Windows 전용이며 Unix runner는 아직 구현되지 않았습니다.

## 테스트

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-job.tests.ps1
```

테스트는 `%TEMP%` 아래의 고유 디렉터리만 사용하며 기존 프로젝트의 job을 읽지 않습니다.

## 제거

```powershell
codex plugin remove codex-job-watch@smallclouds1-tools
codex plugin marketplace remove smallclouds1-tools
```

## 라이선스

[MIT](LICENSE)
