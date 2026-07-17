# Codex Job Watch

[![Windows テスト](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml/badge.svg)](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml)

[English](README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | 日本語 | [한국어](README.ko.md)

Codex で Windows の長時間コマンドを確実に実行するためのプラグインです。永続的な状態とログを保存し、次の 2 つの対話モードを提供します。

- **フォアグラウンド待機（foreground-wait）：** 現在の Codex タスクを実行中のまま維持し、途中経過を話さず、コマンドが最終状態になるまで待機します。
- **バックグラウンド通知（background-notify）：** 現在のタスクをすぐに解放します。専用のバックグラウンド Codex タスクがハートビートを使わずに待機し、完了後に元のタスクへ 1 件のメッセージを送ります。

## なぜ必要ですか？

グローバルプロンプトに「長時間タスクでは待機する」と書くだけでは、プロセス状態の永続化、ログ、キャンセル、終了コードの保持、元のタスクへの後続通知は実現できません。Codex Job Watch は、特定のプロジェクトに依存せず、これらの実行機構を追加します。

## 必要環境

- Windows 10 または Windows 11
- Windows PowerShell 5.1 以降
- プラグインをサポートする Codex
- バックグラウンド通知には、Codex のタスク作成・タスクメッセージ送信ツールも必要です。PowerShell runner 単体はそれらなしでも動作します。

## インストール

GitHub から直接インストールします。

```powershell
codex plugin marketplace add smallclouds1/codex-job-watch
codex plugin add codex-job-watch@smallclouds1-tools
```

ローカル開発では、リポジトリをクローンしてチェックアウトを追加できます。

```powershell
codex plugin marketplace add <ローカルのリポジトリパス>
codex plugin add codex-job-watch@smallclouds1-tools
```

## Codex から使う

希望するモードを自然言語で指定できます。

フォアグラウンド待機の例：

```text
$codex-job-watch を使用して `npm run build` を foreground-wait モードで実行してください。
完了するまで途中経過を話さず、最後に最終結果だけを報告してください。
```

バックグラウンド通知の例：

```text
$codex-job-watch を使用して、このエクスポートを background-notify モードで実行してください。
現在のターンは終了し、ジョブ完了後にこのタスクへ 1 件のメッセージを送ってください。
```

モードを指定しない場合、次の作業が結果に依存するならフォアグラウンド待機、独立して安全に完了できるならバックグラウンド通知を選択します。

## PowerShell runner を直接使う

```powershell
$tool = ".\plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
```

開始して現在のターミナルで待機：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool run `
  -Root (Get-Location).Path `
  -Cwd (Get-Location).Path `
  -Name "build" `
  -Command "npm run build"
```

デタッチしたジョブを開始してから待機：

```powershell
$started = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool start `
  -Root (Get-Location).Path `
  -Name "export" `
  -Command ".\export.ps1" | ConvertFrom-Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool wait `
  -Job $started.job_dir
```

## Runner のアクション

| アクション | 用途 |
| --- | --- |
| `run` | ジョブを開始し、最終結果まで待機します。 |
| `start` | デタッチしたジョブを開始し、JSON メタデータを返します。 |
| `wait` | 既存のジョブを待機します。 |
| `status` | 現在の `STATE.json` を表示します。 |
| `list` | 指定ルート配下のジョブを一覧表示します。 |
| `cancel` | キャンセルを要求し、記録されたプロセスツリーを停止します。 |
| `wait-path` | 一致するファイルが生成され、安定するまで待機します。 |
| `notification-status` | 完了通知が送信済みか確認します。 |
| `mark-notified` | 1 回限りの通知マーカーを保存します。 |

待機の終了コード：`0` 成功、`1` 失敗、`124` タイムアウト、`130` キャンセル。

## ファイルと復旧

各ジョブは `<root>/_task/jobs/<タイムスタンプ-名前>/` に保存されます。

- `STATE.json` — アトミックに保存される状態
- `result.json` — 最終結果
- `worker.log` / `worker.err.log` — 標準出力と標準エラー
- `command.ps1` または `command.cmd` — 実行するコマンド
- `notification.sent.json` — 完了メッセージ送信済みマーカー

Windows worker とログは、元のツール呼び出しが終わっても残ります。Codex を完全に終了しても OS ジョブは継続できますが、バックグラウンド通知タスクは Codex の再起動後に再開が必要になる場合があります。

## 安全性と制限

- `-Command` は現在の Windows ユーザー権限で信頼済みのローカルコードを実行します。
- コマンド内容はジョブディレクトリに保存されるため、秘密情報を直接含めないでください。
- 管理操作は正確なプロジェクトルートまたは job ディレクトリに限定してください。スキルは無関係なジョブをスキャンまたはキャンセルしません。
- タスクメッセージの送信と通知マーカーの書き込みは 1 つのアトミック処理にはできません。その間にクラッシュすると、復旧後に通知が 1 回重複する可能性があります。そのため通知には安定した job ID が含まれます。
- 現在は Windows 専用で、Unix runner は未実装です。

## テスト

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-job.tests.ps1
```

テストは `%TEMP%` 内の固有ディレクトリのみを使用し、既存プロジェクトの job を読みません。

## アンインストール

```powershell
codex plugin remove codex-job-watch@smallclouds1-tools
codex plugin marketplace remove smallclouds1-tools
```

## ライセンス

[MIT](LICENSE)
