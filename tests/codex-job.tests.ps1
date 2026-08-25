param(
    [string]$TestBase = (Join-Path $env:TEMP "codex-job-watch-regression")
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$tool = Join-Path (Split-Path -Parent $PSScriptRoot) "plugins\codex-job-watch\skills\codex-job-watch\scripts\codex-job.ps1"
$base = [System.IO.Path]::GetFullPath($TestBase).TrimEnd('\')
$runRoot = Join-Path $base ("run-{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), [guid]::NewGuid().ToString("N"))
$passed = $false

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (!$Condition) { throw $Message }
}

function Invoke-CodexJobProcess {
    param([string[]]$ToolArgs, [int[]]$ExpectedExitCodes = @(0))
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool @ToolArgs 2>&1
    $exitCode = $LASTEXITCODE
    if ($ExpectedExitCodes -notcontains $exitCode) {
        throw "codex-job exited with ${exitCode}: $($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = ($output -join [Environment]::NewLine)
    }
}

function Read-TestState {
    param([string]$JobDir)
    $statusRaw = Invoke-CodexJobProcess -ToolArgs @(
        "status", "-Root", $runRoot, "-Job", $JobDir
    )
    return ($statusRaw.Text | ConvertFrom-Json)
}

try {
    New-Item -ItemType Directory -Force -Path $runRoot | Out-Null

    $successStartRaw = Invoke-CodexJobProcess -ToolArgs @(
        "start", "-Root", $runRoot, "-Name", "regression-success",
        "-Command", "Start-Sleep -Seconds 3; Write-Output 'ok'"
    )
    $successStart = $successStartRaw.Text | ConvertFrom-Json
    $parseFailures = 0
    for ($i = 0; $i -lt 8; $i++) {
        try {
            $statusRaw = Invoke-CodexJobProcess -ToolArgs @(
                "status", "-Root", $runRoot, "-Job", $successStart.job_dir
            )
            $null = $statusRaw.Text | ConvertFrom-Json
        } catch {
            $parseFailures++
        }
        Start-Sleep -Milliseconds 150
    }
    $successWaitRaw = Invoke-CodexJobProcess -ToolArgs @(
        "wait", "-Root", $runRoot, "-Job", $successStart.job_dir, "-TimeoutSec", "20"
    )
    $successResult = $successWaitRaw.Text | ConvertFrom-Json
    Assert-True ($successResult.status -eq "succeeded") "success job did not reach succeeded"
    Assert-True ($parseFailures -eq 0) "STATE.json became unreadable during concurrent updates"

    $ownershipStartRaw = Invoke-CodexJobProcess -ToolArgs @(
        "start", "-Root", $runRoot, "-Name", "regression-waiter-ownership",
        "-Command", "Start-Sleep -Seconds 8; Write-Output 'owned'"
    )
    $ownershipStart = $ownershipStartRaw.Text | ConvertFrom-Json
    Assert-True ($ownershipStart.finalization_gate_required -eq $true) "start did not advertise the finalization gate"
    $unownedGateRaw = Invoke-CodexJobProcess -ToolArgs @(
        "finalization-status", "-Root", $runRoot, "-Job", $ownershipStart.job_dir,
        "-ThreadId", "origin-regression-thread"
    ) -ExpectedExitCodes @(23)
    $unownedGate = $unownedGateRaw.Text | ConvertFrom-Json
    Assert-True ($unownedGate.status -eq "unowned_running_job") "unowned running job was not rejected"
    Assert-True ($unownedGate.finalizable -eq $false) "unowned running job was incorrectly finalizable"

    $armRaw = Invoke-CodexJobProcess -ToolArgs @(
        "arm-waiter", "-Root", $runRoot, "-Job", $ownershipStart.job_dir,
        "-ThreadId", "origin-regression-thread", "-WaiterThreadId", "waiter-regression-thread"
    )
    $arm = $armRaw.Text | ConvertFrom-Json
    Assert-True ($arm.status -eq "armed") "background waiter could not be armed"
    $armedGateRaw = Invoke-CodexJobProcess -ToolArgs @(
        "finalization-status", "-Root", $runRoot, "-Job", $ownershipStart.job_dir,
        "-ThreadId", "origin-regression-thread"
    )
    $armedGate = $armedGateRaw.Text | ConvertFrom-Json
    Assert-True ($armedGate.status -eq "background_waiter_armed") "armed waiter did not satisfy finalization gate"
    Assert-True ($armedGate.waiter_thread_id -eq "waiter-regression-thread") "wrong waiter owned the job"
    $wrongOriginGateRaw = Invoke-CodexJobProcess -ToolArgs @(
        "finalization-status", "-Root", $runRoot, "-Job", $ownershipStart.job_dir,
        "-ThreadId", "different-origin-thread"
    ) -ExpectedExitCodes @(23)
    $wrongOriginGate = $wrongOriginGateRaw.Text | ConvertFrom-Json
    Assert-True ($wrongOriginGate.status -eq "unowned_running_job") "a different origin task could reuse the waiter arm"
    $conflictingArmFailed = $false
    try {
        $null = Invoke-CodexJobProcess -ToolArgs @(
            "arm-waiter", "-Root", $runRoot, "-Job", $ownershipStart.job_dir,
            "-ThreadId", "origin-regression-thread", "-WaiterThreadId", "different-waiter-thread"
        )
    } catch {
        $conflictingArmFailed = $true
    }
    Assert-True $conflictingArmFailed "a second waiter replaced the registered owner"
    $ownershipWaitRaw = Invoke-CodexJobProcess -ToolArgs @(
        "wait", "-Root", $runRoot, "-Job", $ownershipStart.job_dir, "-TimeoutSec", "20"
    )
    $ownershipResult = $ownershipWaitRaw.Text | ConvertFrom-Json
    Assert-True ($ownershipResult.status -eq "succeeded") "waiter ownership job did not finish"
    $terminalGateRaw = Invoke-CodexJobProcess -ToolArgs @(
        "finalization-status", "-Root", $runRoot, "-Job", $ownershipStart.job_dir,
        "-ThreadId", "different-origin-thread"
    )
    $terminalGate = $terminalGateRaw.Text | ConvertFrom-Json
    Assert-True ($terminalGate.status -eq "terminal") "terminal job did not pass finalization gate"

    $failureStartRaw = Invoke-CodexJobProcess -ToolArgs @(
        "start", "-Root", $runRoot, "-Name", "regression-external-exit-code",
        "-Command", "cmd.exe /d /c exit 7"
    )
    $failureStart = $failureStartRaw.Text | ConvertFrom-Json
    $failureWaitRaw = Invoke-CodexJobProcess -ToolArgs @(
        "wait", "-Root", $runRoot, "-Job", $failureStart.job_dir, "-TimeoutSec", "20"
    ) -ExpectedExitCodes @(1)
    $failureResult = $failureWaitRaw.Text | ConvertFrom-Json
    Assert-True ($failureResult.status -eq "failed") "external nonzero exit was reported as succeeded"
    Assert-True ([int]$failureResult.exit_code -eq 7) "external exit code was not preserved"

    $parserFailureStartRaw = Invoke-CodexJobProcess -ToolArgs @(
        "start", "-Root", $runRoot, "-Name", "regression-parser-failure",
        "-Command", "if ("
    )
    $parserFailureStart = $parserFailureStartRaw.Text | ConvertFrom-Json
    $parserFailureWaitRaw = Invoke-CodexJobProcess -ToolArgs @(
        "wait", "-Root", $runRoot, "-Job", $parserFailureStart.job_dir, "-TimeoutSec", "20"
    ) -ExpectedExitCodes @(1)
    $parserFailureResult = $parserFailureWaitRaw.Text | ConvertFrom-Json
    Assert-True ($parserFailureResult.status -eq "failed") "PowerShell parser failure was reported as succeeded"
    Assert-True ([int]$parserFailureResult.exit_code -eq 1) "PowerShell parser failure did not fail closed"
    Assert-True ($parserFailureResult.error -like "command did not write its authoritative exit-code file*") "PowerShell parser failure did not expose the missing exit-code error"
    Assert-True (!(Test-Path -LiteralPath (Join-Path $parserFailureStart.job_dir "command.exitcode"))) "parser failure unexpectedly wrote command.exitcode"

    $notificationStatusRaw = Invoke-CodexJobProcess -ToolArgs @(
        "notification-status", "-Root", $runRoot, "-Job", $successStart.job_dir
    )
    $notificationStatus = $notificationStatusRaw.Text | ConvertFrom-Json
    Assert-True ($notificationStatus.status -eq "pending") "new job notification was not pending"
    $markRaw = Invoke-CodexJobProcess -ToolArgs @(
        "mark-notified", "-Root", $runRoot, "-Job", $successStart.job_dir,
        "-ThreadId", "regression-thread", "-MessageId", "regression-message"
    )
    $mark = $markRaw.Text | ConvertFrom-Json
    Assert-True ($mark.status -eq "notified") "terminal job could not be marked notified"
    $markAgainRaw = Invoke-CodexJobProcess -ToolArgs @(
        "mark-notified", "-Root", $runRoot, "-Job", $successStart.job_dir,
        "-ThreadId", "regression-thread", "-MessageId", "different-message"
    )
    $markAgain = $markAgainRaw.Text | ConvertFrom-Json
    Assert-True ($markAgain.status -eq "already_notified") "notification marker was not idempotent"

    $cancelStartRaw = Invoke-CodexJobProcess -ToolArgs @(
        "start", "-Root", $runRoot, "-Name", "regression-cancel",
        "-Command", "Start-Sleep -Seconds 60"
    )
    $cancelStart = $cancelStartRaw.Text | ConvertFrom-Json
    $deadline = (Get-Date).AddSeconds(15)
    $cancelState = $null
    while ((Get-Date) -lt $deadline) {
        $cancelState = Read-TestState -JobDir $cancelStart.job_dir
        if ($cancelState.status -eq "running" -and $cancelState.child_pid -ne $null) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True ($cancelState.child_pid -ne $null) "running child_pid was not recorded"
    $childPid = [int]$cancelState.child_pid
    Assert-True ($null -ne (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) "child process was not alive before cancel"

    $null = Invoke-CodexJobProcess -ToolArgs @(
        "cancel", "-Root", $runRoot, "-Job", $cancelStart.job_dir
    )
    Start-Sleep -Milliseconds 500
    $cancelState = Read-TestState -JobDir $cancelStart.job_dir
    $cancelResult = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $cancelStart.job_dir "result.json") | ConvertFrom-Json
    Assert-True ($cancelState.status -eq "cancelled") "cancelled state was not persisted"
    Assert-True ($cancelResult.status -eq "cancelled") "cancelled result was not persisted"
    Assert-True ($null -eq (Get-Process -Id $childPid -ErrorAction SilentlyContinue)) "child process survived cancellation"

    $waitPathArgs = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $tool,
        "wait-path", "-Root", $runRoot, "-Name", "regression-cancel-wait-path",
        "-WatchPath", "never-created.marker", "-IntervalSec", "1", "-TimeoutSec", "60"
    )
    $waitPathProcess = Start-Process -FilePath "powershell.exe" -ArgumentList $waitPathArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(15)
    $waitPathJob = $null
    while ((Get-Date) -lt $deadline) {
        $waitPathJob = Get-ChildItem -LiteralPath (Join-Path $runRoot "_task\jobs") -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*-regression-cancel-wait-path*" } |
            Select-Object -First 1
        if ($waitPathJob) { break }
        Start-Sleep -Milliseconds 200
    }
    Assert-True ($null -ne $waitPathJob) "wait-path job was not created"
    $null = Invoke-CodexJobProcess -ToolArgs @(
        "cancel", "-Root", $runRoot, "-Job", $waitPathJob.FullName
    )
    $waitPathProcess.WaitForExit(10000) | Out-Null
    $waitPathState = Read-TestState -JobDir $waitPathJob.FullName
    $waitPathResult = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $waitPathJob.FullName "result.json") | ConvertFrom-Json
    Assert-True ($waitPathState.status -eq "cancelled") "wait-path cancellation state was not persisted"
    Assert-True ($waitPathResult.status -eq "cancelled") "wait-path cancellation result was not persisted"
    Assert-True ($null -eq (Get-Process -Id $waitPathProcess.Id -ErrorAction SilentlyContinue)) "wait-path process survived cancellation"

    $passed = $true
    [ordered]@{
        status = "passed"
        success_job = $successStart.job_id
        failed_job = $failureStart.job_id
        failed_exit_code = [int]$failureResult.exit_code
        parser_failure_job = $parserFailureStart.job_id
        parser_failure_exit_code = [int]$parserFailureResult.exit_code
        cancel_job = $cancelStart.job_id
        wait_path_cancel_job = $waitPathJob.Name
        ownership_job = $ownershipStart.job_id
        unowned_gate_exit_code = $unownedGateRaw.ExitCode
        state_parse_failures = $parseFailures
        cancelled_child_pid = $childPid
        test_root = $runRoot
    } | ConvertTo-Json -Compress
} finally {
    if ($passed -and (Test-Path -LiteralPath $runRoot -PathType Container)) {
        $resolvedRun = (Resolve-Path -LiteralPath $runRoot).Path
        if (!$resolvedRun.StartsWith($base + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove test directory outside base: $resolvedRun"
        }
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force
        if ((Test-Path -LiteralPath $base -PathType Container) -and @(Get-ChildItem -LiteralPath $base -Force).Count -eq 0) {
            Remove-Item -LiteralPath $base -Force
        }
    }
}
