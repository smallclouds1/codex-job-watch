# Codex Job Watch

[![Windows 測試](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml/badge.svg)](https://github.com/smallclouds1/codex-job-watch/actions/workflows/test.yml)

[English](README.md) | [简体中文](README.zh-CN.md) | 繁體中文 | [日本語](README.ja.md) | [한국어](README.ko.md)

這是一個讓 Codex 在 Windows 上可靠執行長時間命令的外掛。它會保留持久狀態與日誌，並提供兩種清楚的互動模式：

- **前景等待（foreground-wait）：** 目前的 Codex 任務維持執行狀態，等待期間不持續發言，直到命令進入最終狀態。
- **背景通知（background-notify）：** 目前任務立即釋放；獨立的背景 Codex 任務負責等待，不使用心跳輪詢，完成後向原任務傳送一則訊息。

## 為什麼需要它？

在全域提示詞中寫「長任務必須等待」只能約束模型行為，無法提供持久程序狀態、日誌、取消、結束碼保存，也無法在原任務結束目前回合後主動回信。Codex Job Watch 補齊這些執行機制，而且不綁定特定專案。

## 系統需求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1 或更新版本
- 支援外掛的 Codex
- 背景通知還需要 Codex 提供建立任務及向任務傳送訊息的工具；PowerShell runner 本身可獨立使用。

## 安裝

直接從 GitHub 安裝：

```powershell
codex plugin marketplace add smallclouds1/codex-job-watch
codex plugin add codex-job-watch@smallclouds1-tools
```

本機開發時，也可以複製儲存庫後加入本機路徑：

```powershell
codex plugin marketplace add <儲存庫本機路徑>
codex plugin add codex-job-watch@smallclouds1-tools
```

## 在 Codex 中使用

直接用自然語言說明模式即可。

前景等待範例：

```text
使用 $codex-job-watch 以前景等待模式執行 `npm run build`。
等待期間不要持續發言，結束後再回報最終結果。
```

背景通知範例：

```text
使用 $codex-job-watch 以背景通知模式執行這次匯出。
現在結束目前回合，任務完成後在這裡傳送一則通知。
```

若未指定模式，後續步驟依賴結果時應選擇前景等待；任務可安全獨立完成時應選擇背景通知。

## 直接使用 PowerShell runner

```powershell
$tool = ".\plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
```

啟動並在目前終端機等待：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool run `
  -Root (Get-Location).Path `
  -Cwd (Get-Location).Path `
  -Name "build" `
  -Command "npm run build"
```

啟動分離任務後再等待：

```powershell
$started = powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool start `
  -Root (Get-Location).Path `
  -Name "export" `
  -Command ".\export.ps1" | ConvertFrom-Json

powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool wait `
  -Job $started.job_dir
```

## Runner 操作

| 操作 | 用途 |
| --- | --- |
| `run` | 啟動任務並等待最終結果。 |
| `start` | 啟動分離任務並回傳 JSON 中繼資料。 |
| `wait` | 等待既有任務。 |
| `status` | 輸出目前的 `STATE.json`。 |
| `list` | 列出指定根目錄下的任務。 |
| `cancel` | 要求取消並終止記錄的程序樹。 |
| `wait-path` | 等待符合條件的檔案出現並維持穩定。 |
| `notification-status` | 檢查完成通知是否已送出。 |
| `mark-notified` | 寫入一次性通知標記。 |

等待結束碼：`0` 成功、`1` 失敗、`124` 等待逾時、`130` 已取消。

## 檔案與復原

每個任務保存在 `<root>/_task/jobs/<時間戳記-名稱>/`：

- `STATE.json`：原子寫入的狀態快照
- `result.json`：最終結果
- `worker.log` / `worker.err.log`：標準輸出與錯誤輸出
- `command.ps1` 或 `command.cmd`：實際命令內容
- `notification.sent.json`：已送出完成訊息時的標記

Windows worker 與日誌不會因原工具呼叫結束而消失。若完全關閉 Codex，系統任務仍可繼續執行，但背景通知任務可能需要在 Codex 再次啟動後恢復。

## 安全與限制

- `-Command` 會以目前 Windows 使用者權限執行可信的本機程式碼。
- 不要把密鑰直接寫入命令文字，因為命令內容會保存在任務目錄中。
- 管理任務時必須指定正確的專案根目錄或 job 目錄；技能不會主動掃描或取消無關任務。
- 傳送任務訊息與寫入通知標記無法成為同一個原子交易；若恰好在兩者之間當機，恢復後可能重複通知一次，因此訊息包含穩定的 job ID。
- 目前版本只支援 Windows，尚未實作 Unix runner。

## 測試

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\codex-job.tests.ps1
```

測試只使用 `%TEMP%` 下的唯一目錄，不會讀取既有專案的 job。

## 解除安裝

```powershell
codex plugin remove codex-job-watch@smallclouds1-tools
codex plugin marketplace remove smallclouds1-tools
```

## 授權條款

[MIT](LICENSE)
