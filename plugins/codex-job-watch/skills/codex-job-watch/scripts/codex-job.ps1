param(
    [Parameter(Position = 0)]
    [ValidateSet("run", "start", "wait", "status", "list", "cancel", "wait-path", "notification-status", "mark-notified", "run-worker")]
    [string]$Action = "status",

    [string]$Name,
    [string]$Command,
    [string]$Root,
    [string]$Cwd,
    [string]$Job,
    [string]$WatchPath,
    [string]$Pattern = "*",
    [string]$ThreadId,
    [string]$MessageId,

    [ValidateSet("powershell", "cmd")]
    [string]$Shell = "powershell",

    [int]$IntervalSec = 5,
    [int]$TimeoutSec = 0,
    [int]$MinCount = 1,
    [int]$StableSec = 5,
    [switch]$Recurse,
    [switch]$VerboseProgress
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Get-UtcIso {
    return (Get-Date).ToUniversalTime().ToString("o")
}

function New-Utf8NoBomEncoding {
    return [System.Text.UTF8Encoding]::new($false)
}

function New-Utf8BomEncoding {
    return [System.Text.UTF8Encoding]::new($true)
}

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $directory = Split-Path -Parent $Path
    if (![string]::IsNullOrWhiteSpace($directory)) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }
    $tempPath = "$Path.tmp.$PID.$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$Path.bak.$PID.$([guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.File]::WriteAllText($tempPath, $Text, (New-Utf8NoBomEncoding))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($tempPath, $Path, $backupPath, $true)
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::Move($tempPath, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
            Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-PowerShellScriptFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Utf8BomEncoding))
}

function Write-CmdScriptFile {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.Encoding]::Default)
}

function Write-JsonFile {
    param([string]$Path, [object]$Object)
    $json = $Object | ConvertTo-Json -Depth 20
    Write-TextFile -Path $Path -Text $json
}

function Read-JsonFile {
    param([string]$Path)
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function ConvertTo-Slug {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        $Text = "job"
    }
    $slug = $Text -replace '[^\p{L}\p{Nd}_-]+', '-'
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        $slug = "job"
    }
    if ($slug.Length -gt 48) {
        $slug = $slug.Substring(0, 48).Trim('-')
    }
    return $slug
}

function Get-DefaultRoot {
    if ([string]::IsNullOrWhiteSpace($script:Root)) {
        return (Get-Location).Path
    }
    return $script:Root
}

function Get-JobsRoot {
    param([string]$ProjectRoot)
    $resolvedRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    return (Join-Path $resolvedRoot "_task\jobs")
}

function Resolve-JobDir {
    param([string]$ProjectRoot, [string]$JobValue)
    if ([string]::IsNullOrWhiteSpace($JobValue)) {
        throw "Missing -Job."
    }
    if (Test-Path -LiteralPath $JobValue -PathType Container) {
        return (Resolve-Path -LiteralPath $JobValue).Path
    }
    $candidate = Join-Path (Get-JobsRoot -ProjectRoot $ProjectRoot) $JobValue
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return (Resolve-Path -LiteralPath $candidate).Path
    }
    throw "Job not found: $JobValue"
}

function Get-StatePath {
    param([string]$JobDir)
    return (Join-Path $JobDir "STATE.json")
}

function Get-StateMutexName {
    param([string]$JobDir)
    $normalized = [System.IO.Path]::GetFullPath($JobDir).ToLowerInvariant()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
        $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
        return "Local\CodexJobState_$hash"
    } finally {
        $sha.Dispose()
    }
}

function Enter-StateMutex {
    param([string]$JobDir, [int]$TimeoutMilliseconds = 30000)
    $mutex = [System.Threading.Mutex]::new($false, (Get-StateMutexName -JobDir $JobDir))
    try {
        $acquired = $mutex.WaitOne($TimeoutMilliseconds)
    } catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
    }
    if (!$acquired) {
        $mutex.Dispose()
        throw "Timed out waiting for state lock: $JobDir"
    }
    return $mutex
}

function Exit-StateMutex {
    param([System.Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}

function Read-State {
    param([string]$JobDir)
    $mutex = Enter-StateMutex -JobDir $JobDir
    try {
        $statePath = Get-StatePath -JobDir $JobDir
        if (!(Test-Path -LiteralPath $statePath -PathType Leaf)) {
            throw "Missing STATE.json in $JobDir"
        }
        return (Read-JsonFile -Path $statePath)
    } finally {
        Exit-StateMutex -Mutex $mutex
    }
}

function Save-State {
    param([string]$JobDir, [object]$State)
    $mutex = Enter-StateMutex -JobDir $JobDir
    try {
        Set-ObjectProperty -Object $State -Name "updated_at" -Value (Get-UtcIso)
        Write-JsonFile -Path (Get-StatePath -JobDir $JobDir) -Object $State
    } finally {
        Exit-StateMutex -Mutex $mutex
    }
}

function Wait-StartReady {
    param([string]$JobDir, [int]$TimeoutSeconds = 30)
    $readyPath = Join-Path $JobDir "start.ready"
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (!(Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ((Get-Date) -ge $deadline) {
            throw "Worker start handshake timed out: $readyPath"
        }
        Start-Sleep -Milliseconds 100
    }
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    if ($ProcessId -le 0) { return }
    if ($env:OS -eq "Windows_NT") {
        $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
        if (Test-Path -LiteralPath $taskkill -PathType Leaf) {
            # Cancellation can race with the worker's own exit path. Invoke
            # taskkill with redirected native streams so an already-exited PID
            # cannot surface as a PowerShell NativeCommandError to callers.
            $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $taskkill
            $startInfo.Arguments = "/PID $ProcessId /T /F"
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $killer = [System.Diagnostics.Process]::Start($startInfo)
            try {
                $null = $killer.StandardOutput.ReadToEnd()
                $null = $killer.StandardError.ReadToEnd()
                $killer.WaitForExit()
            } finally {
                $killer.Dispose()
            }
            if (!(Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
                return
            }
        }
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function Quote-PowerShellLiteral {
    param([string]$Value)
    return "'" + ($Value -replace "'", "''") + "'"
}

function New-CodexJob {
    param(
        [string]$JobName,
        [string]$JobCommand,
        [string]$ProjectRoot,
        [string]$WorkingDirectory,
        [string]$CommandShell
    )

    if ([string]::IsNullOrWhiteSpace($JobCommand)) {
        throw "Missing -Command."
    }

    $projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = $projectRoot
    }
    $workingDirectory = [System.IO.Path]::GetFullPath($WorkingDirectory)

    New-Item -ItemType Directory -Force -Path (Get-JobsRoot -ProjectRoot $projectRoot) | Out-Null
    $jobId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), (ConvertTo-Slug -Text $JobName)
    $jobDir = Join-Path (Get-JobsRoot -ProjectRoot $projectRoot) $jobId
    $suffix = 0
    while (Test-Path -LiteralPath $jobDir) {
        $suffix += 1
        $jobDir = Join-Path (Get-JobsRoot -ProjectRoot $projectRoot) ("$jobId-$suffix")
    }
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
    $commandExitCodeFile = Join-Path $jobDir "command.exitcode"

    $commandFile = if ($CommandShell -eq "cmd") {
        Join-Path $jobDir "command.cmd"
    } else {
        Join-Path $jobDir "command.ps1"
    }

    if ($CommandShell -eq "cmd") {
        $cmd = "@echo off`r`ncd /d `"$workingDirectory`"`r`n$JobCommand`r`nset `"_CODEX_JOB_EXIT=%ERRORLEVEL%`"`r`n> `"$commandExitCodeFile`" echo %_CODEX_JOB_EXIT%`r`nexit /b %_CODEX_JOB_EXIT%`r`n"
        Write-CmdScriptFile -Path $commandFile -Text $cmd
    } else {
        $ps = @"
trap {
    Write-Error `$_
    [System.IO.File]::WriteAllText($(Quote-PowerShellLiteral -Value $commandExitCodeFile), "1")
    exit 1
}
`$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $(Quote-PowerShellLiteral -Value $workingDirectory)
$JobCommand
# Start-Process without -Wait can report a stale zero ExitCode on Windows when
# stdout/stderr are redirected. Persist the command's own code before exiting;
# the worker treats this file as authoritative.
`$__codexJobExitCode = 0
if (`$LASTEXITCODE -ne `$null) { `$__codexJobExitCode = [int]`$LASTEXITCODE }
[System.IO.File]::WriteAllText($(Quote-PowerShellLiteral -Value $commandExitCodeFile), [string]`$__codexJobExitCode)
exit `$__codexJobExitCode
"@
        Write-PowerShellScriptFile -Path $commandFile -Text $ps
    }

    $state = [ordered]@{
        schema = 1
        job_id = Split-Path -Leaf $jobDir
        name = $JobName
        status = "queued"
        progress = $null
        step = "queued"
        shell = $CommandShell
        command_file = $commandFile
        root = $projectRoot
        cwd = $workingDirectory
        job_dir = $jobDir
        state_path = (Join-Path $jobDir "STATE.json")
        log_path = (Join-Path $jobDir "worker.log")
        stderr_path = (Join-Path $jobDir "worker.err.log")
        result_path = (Join-Path $jobDir "result.json")
        cancel_path = (Join-Path $jobDir "cancel.flag")
        start_ready_path = (Join-Path $jobDir "start.ready")
        worker_pid = $null
        worker_launcher_pid = $null
        child_pid = $null
        exit_code = $null
        error = $null
        started_at = $null
        finished_at = $null
        updated_at = Get-UtcIso
        created_at = Get-UtcIso
    }
    Write-JsonFile -Path (Join-Path $jobDir "STATE.json") -Object $state

    $argList = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "run-worker",
        "-Job", "`"$jobDir`""
    ) -join " "
    $proc = Start-Process -FilePath "powershell.exe" -ArgumentList $argList -PassThru -WindowStyle Hidden
    $state = Read-State -JobDir $jobDir
    Set-ObjectProperty -Object $state -Name "worker_launcher_pid" -Value $proc.Id
    Set-ObjectProperty -Object $state -Name "worker_pid" -Value $proc.Id
    Save-State -JobDir $jobDir -State $state
    Write-TextFile -Path $state.start_ready_path -Text ("ready " + (Get-UtcIso))

    return [ordered]@{
        status = "started"
        job_id = (Split-Path -Leaf $jobDir)
        job_dir = $jobDir
        state_path = (Join-Path $jobDir "STATE.json")
        wait_command = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" wait -Job `"$jobDir`""
    }
}

function Start-Worker {
    param([string]$JobDir)
    $state = $null
    $wasCancelled = $false
    try {
        Wait-StartReady -JobDir $JobDir
        $state = Read-State -JobDir $JobDir
        if (Test-Path -LiteralPath $state.cancel_path -PathType Leaf) {
            throw "cancel requested before worker start"
        }
        Set-ObjectProperty -Object $state -Name "status" -Value "running"
        Set-ObjectProperty -Object $state -Name "step" -Value "running"
        Set-ObjectProperty -Object $state -Name "worker_pid" -Value $PID
        Set-ObjectProperty -Object $state -Name "started_at" -Value (Get-UtcIso)
        Save-State -JobDir $JobDir -State $state

        $stdout = $state.log_path
        $stderr = $state.stderr_path
        if (Test-Path -LiteralPath $stdout) { Remove-Item -LiteralPath $stdout -Force }
        if (Test-Path -LiteralPath $stderr) { Remove-Item -LiteralPath $stderr -Force }

        if ($state.shell -eq "cmd") {
            $exe = "cmd.exe"
            $args = "/d /c `"$($state.command_file)`""
        } else {
            $exe = "powershell.exe"
            $args = "-NoProfile -ExecutionPolicy Bypass -File `"$($state.command_file)`""
        }

        Set-ObjectProperty -Object $state -Name "step" -Value "child_waiting"
        Save-State -JobDir $JobDir -State $state

        $child = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $state.cwd -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        $state = Read-State -JobDir $JobDir
        Set-ObjectProperty -Object $state -Name "child_pid" -Value $child.Id
        Save-State -JobDir $JobDir -State $state

        while (!$child.HasExited) {
            if (Test-Path -LiteralPath $state.cancel_path -PathType Leaf) {
                Stop-ProcessTree -ProcessId $child.Id
                $child.WaitForExit(5000) | Out-Null
                break
            }
            Start-Sleep -Milliseconds 500
            $child.Refresh()
        }
        if (!$child.HasExited) {
            Stop-ProcessTree -ProcessId $child.Id
            $child.WaitForExit(5000) | Out-Null
        }
        $child.Refresh()
        $exitCode = [int]$child.ExitCode
        $commandExitCodeFile = Join-Path $JobDir "command.exitcode"
        if (Test-Path -LiteralPath $commandExitCodeFile -PathType Leaf) {
            $commandExitCodeText = (Get-Content -Raw -Encoding UTF8 -LiteralPath $commandExitCodeFile).Trim()
            $parsedCommandExitCode = 0
            if ([int]::TryParse($commandExitCodeText, [ref]$parsedCommandExitCode)) {
                $exitCode = $parsedCommandExitCode
            } else {
                throw "Command exit-code file is invalid: $commandExitCodeFile"
            }
        }
        $wasCancelled = Test-Path -LiteralPath $state.cancel_path -PathType Leaf
        $finalStatus = if ($wasCancelled) { "cancelled" } elseif ($exitCode -eq 0) { "succeeded" } else { "failed" }
        $state = Read-State -JobDir $JobDir
        Set-ObjectProperty -Object $state -Name "status" -Value $finalStatus
        Set-ObjectProperty -Object $state -Name "step" -Value $finalStatus
        Set-ObjectProperty -Object $state -Name "exit_code" -Value $exitCode
        Set-ObjectProperty -Object $state -Name "finished_at" -Value (Get-UtcIso)
        if ($wasCancelled) {
            Set-ObjectProperty -Object $state -Name "exit_code" -Value 130
            Set-ObjectProperty -Object $state -Name "error" -Value "cancel requested"
        } elseif ($exitCode -ne 0) {
            Set-ObjectProperty -Object $state -Name "error" -Value "command exited with code $exitCode"
        }
        Save-State -JobDir $JobDir -State $state
        Write-JsonFile -Path $state.result_path -Object ([ordered]@{
            status = $finalStatus
            job_id = $state.job_id
            exit_code = $(if ($wasCancelled) { 130 } else { $exitCode })
            log_path = $state.log_path
            stderr_path = $state.stderr_path
            state_path = $state.state_path
            finished_at = $state.finished_at
        })
        if ($wasCancelled) { exit 130 }
        exit $exitCode
    } catch {
        $message = $_.Exception.Message
        try {
            if ($null -eq $state) {
                $state = Read-State -JobDir $JobDir
            }
            $wasCancelled = Test-Path -LiteralPath $state.cancel_path -PathType Leaf
            $terminalStatus = if ($wasCancelled) { "cancelled" } else { "failed" }
            Set-ObjectProperty -Object $state -Name "status" -Value $terminalStatus
            Set-ObjectProperty -Object $state -Name "step" -Value $(if ($wasCancelled) { "cancelled" } else { "worker_failed" })
            Set-ObjectProperty -Object $state -Name "error" -Value $(if ($wasCancelled) { "cancel requested" } else { $message })
            Set-ObjectProperty -Object $state -Name "finished_at" -Value (Get-UtcIso)
            Set-ObjectProperty -Object $state -Name "exit_code" -Value $(if ($wasCancelled) { 130 } else { 1 })
            Save-State -JobDir $JobDir -State $state
            Write-JsonFile -Path $state.result_path -Object ([ordered]@{
                status = $terminalStatus
                job_id = $state.job_id
                exit_code = $(if ($wasCancelled) { 130 } else { 1 })
                error = $(if ($wasCancelled) { "cancel requested" } else { $message })
                state_path = $state.state_path
                log_path = $state.log_path
                stderr_path = $state.stderr_path
                finished_at = Get-UtcIso
            })
        } catch {
        }
        if ($wasCancelled) { exit 130 }
        exit 1
    }
}

function Wait-CodexJob {
    param([string]$JobDir, [int]$PollSeconds, [int]$MaxSeconds, [switch]$ShowProgress)
    if ($PollSeconds -lt 1) { $PollSeconds = 1 }
    $started = Get-Date
    while ($true) {
        $state = Read-State -JobDir $JobDir
        $terminal = @("succeeded", "failed", "cancelled")
        if ($terminal -contains $state.status) {
            $result = if (Test-Path -LiteralPath $state.result_path -PathType Leaf) {
                Read-JsonFile -Path $state.result_path
            } else {
                [ordered]@{
                    status = $state.status
                    job_id = $state.job_id
                    exit_code = $state.exit_code
                    error = $state.error
                    state_path = $state.state_path
                    log_path = $state.log_path
                    stderr_path = $state.stderr_path
                }
            }
            $result | ConvertTo-Json -Depth 20 -Compress
            if ($state.status -eq "succeeded") { exit 0 }
            if ($state.status -eq "cancelled") { exit 130 }
            exit 1
        }

        if (@("queued", "running") -contains $state.status -and $state.worker_pid -ne $null) {
            $workerAlive = Get-Process -Id ([int]$state.worker_pid) -ErrorAction SilentlyContinue
            if ($null -eq $workerAlive) {
                Set-ObjectProperty -Object $state -Name "status" -Value "failed"
                Set-ObjectProperty -Object $state -Name "step" -Value "worker_missing"
                Set-ObjectProperty -Object $state -Name "error" -Value "worker process disappeared before a terminal state"
                Set-ObjectProperty -Object $state -Name "finished_at" -Value (Get-UtcIso)
                Set-ObjectProperty -Object $state -Name "exit_code" -Value 1
                Save-State -JobDir $JobDir -State $state
                continue
            }
        }

        if ($MaxSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxSeconds) {
            ([ordered]@{
                status = "wait_timeout"
                job_id = $state.job_id
                state_status = $state.status
                state_path = $state.state_path
                log_path = $state.log_path
                stderr_path = $state.stderr_path
                elapsed_sec = [int]((Get-Date) - $started).TotalSeconds
            } | ConvertTo-Json -Depth 20 -Compress)
            exit 124
        }

        if ($ShowProgress) {
            Write-Host ("{0} {1} {2}" -f (Get-Date -Format "HH:mm:ss"), $state.status, $state.step)
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Show-Status {
    param([string]$JobDir)
    $state = Read-State -JobDir $JobDir
    $state | ConvertTo-Json -Depth 20
}

function List-Jobs {
    param([string]$ProjectRoot)
    $jobsRoot = Get-JobsRoot -ProjectRoot $ProjectRoot
    if (!(Test-Path -LiteralPath $jobsRoot -PathType Container)) {
        "[]"
        return
    }
    $items = @()
    foreach ($dir in Get-ChildItem -LiteralPath $jobsRoot -Directory | Sort-Object LastWriteTime -Descending) {
        $statePath = Join-Path $dir.FullName "STATE.json"
        if (Test-Path -LiteralPath $statePath -PathType Leaf) {
            try {
                $s = Read-JsonFile -Path $statePath
                $items += [ordered]@{
                    job_id = $s.job_id
                    name = $s.name
                    status = $s.status
                    step = $s.step
                    updated_at = $s.updated_at
                    job_dir = $s.job_dir
                }
            } catch {
            }
        }
    }
    $items | ConvertTo-Json -Depth 20
}

function Cancel-Job {
    param([string]$JobDir)
    $state = Read-State -JobDir $JobDir
    Write-TextFile -Path $state.cancel_path -Text ("cancel requested at " + (Get-UtcIso))
    if ($state.child_pid -ne $null) {
        Stop-ProcessTree -ProcessId ([int]$state.child_pid)
    }
    if ($state.worker_pid -ne $null) {
        $deadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $deadline -and (Get-Process -Id ([int]$state.worker_pid) -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 200
        }
        if (Get-Process -Id ([int]$state.worker_pid) -ErrorAction SilentlyContinue) {
            Stop-Process -Id ([int]$state.worker_pid) -Force -ErrorAction SilentlyContinue
        }
    }
    $state = Read-State -JobDir $JobDir
    if (@("succeeded", "failed", "cancelled") -notcontains $state.status) {
        Set-ObjectProperty -Object $state -Name "status" -Value "cancelled"
        Set-ObjectProperty -Object $state -Name "step" -Value "cancelled"
        Set-ObjectProperty -Object $state -Name "finished_at" -Value (Get-UtcIso)
        Set-ObjectProperty -Object $state -Name "exit_code" -Value 130
        Set-ObjectProperty -Object $state -Name "error" -Value "cancel requested"
        Save-State -JobDir $JobDir -State $state
        Write-JsonFile -Path $state.result_path -Object ([ordered]@{
            status = "cancelled"
            job_id = $state.job_id
            exit_code = 130
            error = "cancel requested"
            state_path = $state.state_path
            log_path = $state.log_path
            stderr_path = $state.stderr_path
            finished_at = $state.finished_at
        })
    }
    ([ordered]@{
        status = "cancel_requested"
        job_id = $state.job_id
        state_path = $state.state_path
    } | ConvertTo-Json -Depth 20 -Compress)
}

function Test-PathHasWildcard {
    param([string]$Value)
    return ($Value -match '[\*\?\[]')
}

function Resolve-WatchPath {
    param([string]$ProjectRoot, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Missing -WatchPath."
    }
    if ([System.IO.Path]::IsPathRooted($Value)) {
        return $Value
    }
    return (Join-Path ([System.IO.Path]::GetFullPath($ProjectRoot)) $Value)
}

function Get-WatchMatches {
    param([string]$PathValue, [string]$FilterPattern, [switch]$Deep)
    if (Test-Path -LiteralPath $PathValue -PathType Container) {
        return @(Get-ChildItem -LiteralPath $PathValue -File -Filter $FilterPattern -Recurse:$Deep -ErrorAction SilentlyContinue)
    }
    if (Test-Path -LiteralPath $PathValue -PathType Leaf) {
        return @((Get-Item -LiteralPath $PathValue -ErrorAction SilentlyContinue))
    }
    if (Test-PathHasWildcard -Value $PathValue) {
        return @(Get-ChildItem -Path $PathValue -File -ErrorAction SilentlyContinue)
    }
    return @()
}

function Get-WatchSignature {
    param([object[]]$Matches)
    $parts = @()
    foreach ($m in ($Matches | Sort-Object FullName)) {
        $parts += "{0}|{1}|{2}" -f $m.FullName, $m.Length, $m.LastWriteTimeUtc.Ticks
    }
    return ($parts -join "`n")
}

function New-WatchState {
    param([string]$ProjectRoot, [string]$WatchName, [string]$ResolvedWatchPath)
    $projectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)
    New-Item -ItemType Directory -Force -Path (Get-JobsRoot -ProjectRoot $projectRoot) | Out-Null
    $jobId = "{0}-{1}" -f (Get-Date -Format "yyyyMMdd-HHmmss"), (ConvertTo-Slug -Text $WatchName)
    $jobDir = Join-Path (Get-JobsRoot -ProjectRoot $projectRoot) $jobId
    $suffix = 0
    while (Test-Path -LiteralPath $jobDir) {
        $suffix += 1
        $jobDir = Join-Path (Get-JobsRoot -ProjectRoot $projectRoot) ("$jobId-$suffix")
    }
    New-Item -ItemType Directory -Force -Path $jobDir | Out-Null
    $state = [ordered]@{
        schema = 1
        job_id = Split-Path -Leaf $jobDir
        name = $WatchName
        status = "waiting"
        step = "waiting_for_path"
        action = "wait-path"
        root = $projectRoot
        job_dir = $jobDir
        state_path = (Join-Path $jobDir "STATE.json")
        result_path = (Join-Path $jobDir "result.json")
        watch_path = $ResolvedWatchPath
        pattern = $Pattern
        recurse = [bool]$Recurse
        min_count = $MinCount
        stable_sec = $StableSec
        matched_count = 0
        stable_since = $null
        error = $null
        started_at = Get-UtcIso
        finished_at = $null
        updated_at = Get-UtcIso
        created_at = Get-UtcIso
    }
    Write-JsonFile -Path (Join-Path $jobDir "STATE.json") -Object $state
    return (Read-State -JobDir $jobDir)
}

function Wait-PathArtifact {
    param(
        [string]$ProjectRoot,
        [string]$WaitName,
        [string]$PathValue,
        [string]$FilterPattern,
        [int]$PollSeconds,
        [int]$MaxSeconds,
        [int]$RequiredCount,
        [int]$RequiredStableSec,
        [switch]$Deep,
        [switch]$ShowProgress
    )
    if ($PollSeconds -lt 1) { $PollSeconds = 1 }
    if ($RequiredCount -lt 1) { $RequiredCount = 1 }
    if ($RequiredStableSec -lt 0) { $RequiredStableSec = 0 }
    if ([string]::IsNullOrWhiteSpace($WaitName)) { $WaitName = "wait-path" }

    $resolved = Resolve-WatchPath -ProjectRoot $ProjectRoot -Value $PathValue
    $state = New-WatchState -ProjectRoot $ProjectRoot -WatchName $WaitName -ResolvedWatchPath $resolved
    $started = Get-Date
    $lastSignature = $null
    $stableSince = $null
    $lastStateWrite = Get-Date

    while ($true) {
        $matches = @(Get-WatchMatches -PathValue $resolved -FilterPattern $FilterPattern -Deep:$Deep)
        $matchCount = $matches.Count
        $signature = Get-WatchSignature -Matches $matches

        if ($matchCount -ge $RequiredCount) {
            if ($signature -ne $lastSignature) {
                $lastSignature = $signature
                $stableSince = Get-Date
            }
            $stableFor = if ($stableSince -ne $null) { ((Get-Date) - $stableSince).TotalSeconds } else { 0 }
            if ($stableFor -ge $RequiredStableSec) {
                $state = Read-State -JobDir $state.job_dir
                Set-ObjectProperty -Object $state -Name "status" -Value "succeeded"
                Set-ObjectProperty -Object $state -Name "step" -Value "path_ready"
                Set-ObjectProperty -Object $state -Name "matched_count" -Value $matchCount
                Set-ObjectProperty -Object $state -Name "stable_since" -Value ($(if ($stableSince) { $stableSince.ToUniversalTime().ToString("o") } else { $null }))
                Set-ObjectProperty -Object $state -Name "finished_at" -Value (Get-UtcIso)
                Save-State -JobDir $state.job_dir -State $state
                $paths = @($matches | Sort-Object FullName | Select-Object -First 50 | ForEach-Object { $_.FullName })
                $result = [ordered]@{
                    status = "succeeded"
                    job_id = $state.job_id
                    watch_path = $resolved
                    pattern = $FilterPattern
                    matched_count = $matchCount
                    matches = $paths
                    state_path = $state.state_path
                    result_path = $state.result_path
                    finished_at = $state.finished_at
                }
                Write-JsonFile -Path $state.result_path -Object $result
                $result | ConvertTo-Json -Depth 20 -Compress
                exit 0
            }
        } else {
            $lastSignature = $null
            $stableSince = $null
        }

        if ($MaxSeconds -gt 0 -and ((Get-Date) - $started).TotalSeconds -ge $MaxSeconds) {
            $state = Read-State -JobDir $state.job_dir
            Set-ObjectProperty -Object $state -Name "status" -Value "wait_timeout"
            Set-ObjectProperty -Object $state -Name "step" -Value "wait_timeout"
            Set-ObjectProperty -Object $state -Name "matched_count" -Value $matchCount
            Set-ObjectProperty -Object $state -Name "finished_at" -Value (Get-UtcIso)
            Save-State -JobDir $state.job_dir -State $state
            $result = [ordered]@{
                status = "wait_timeout"
                job_id = $state.job_id
                watch_path = $resolved
                pattern = $FilterPattern
                matched_count = $matchCount
                state_path = $state.state_path
                result_path = $state.result_path
                elapsed_sec = [int]((Get-Date) - $started).TotalSeconds
            }
            Write-JsonFile -Path $state.result_path -Object $result
            $result | ConvertTo-Json -Depth 20 -Compress
            exit 124
        }

        if (((Get-Date) - $lastStateWrite).TotalSeconds -ge 30) {
            $state = Read-State -JobDir $state.job_dir
            Set-ObjectProperty -Object $state -Name "matched_count" -Value $matchCount
            Set-ObjectProperty -Object $state -Name "stable_since" -Value ($(if ($stableSince) { $stableSince.ToUniversalTime().ToString("o") } else { $null }))
            Save-State -JobDir $state.job_dir -State $state
            $lastStateWrite = Get-Date
        }

        if ($ShowProgress) {
            Write-Host ("{0} waiting matches={1}" -f (Get-Date -Format "HH:mm:ss"), $matchCount)
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-NotificationPath {
    param([string]$JobDir)
    return (Join-Path $JobDir "notification.sent.json")
}

function Show-NotificationStatus {
    param([string]$JobDir)
    $path = Get-NotificationPath -JobDir $JobDir
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Read-JsonFile -Path $path | ConvertTo-Json -Depth 20 -Compress
        return
    }
    ([ordered]@{
        status = "pending"
        job_id = (Read-State -JobDir $JobDir).job_id
        notification_path = $path
    } | ConvertTo-Json -Depth 20 -Compress)
}

function Mark-NotificationSent {
    param([string]$JobDir, [string]$TargetThreadId, [string]$SentMessageId)
    if ([string]::IsNullOrWhiteSpace($TargetThreadId)) { throw "Missing -ThreadId." }
    $mutex = Enter-StateMutex -JobDir $JobDir
    try {
        $path = Get-NotificationPath -JobDir $JobDir
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $existing = Read-JsonFile -Path $path
            ([ordered]@{
                status = "already_notified"
                job_id = $existing.job_id
                thread_id = $existing.thread_id
                sent_at = $existing.sent_at
                notification_path = $path
            } | ConvertTo-Json -Depth 20 -Compress)
            return
        }
        $state = Read-JsonFile -Path (Get-StatePath -JobDir $JobDir)
        if (@("succeeded", "failed", "cancelled") -notcontains $state.status) {
            throw "Cannot mark a non-terminal job as notified: $($state.status)"
        }
        $record = [ordered]@{
            status = "notified"
            job_id = $state.job_id
            job_status = $state.status
            thread_id = $TargetThreadId
            message_id = $SentMessageId
            sent_at = Get-UtcIso
            notification_path = $path
        }
        Write-JsonFile -Path $path -Object $record
        $record | ConvertTo-Json -Depth 20 -Compress
    } finally {
        Exit-StateMutex -Mutex $mutex
    }
}

$projectRoot = Get-DefaultRoot
if ([string]::IsNullOrWhiteSpace($Cwd)) {
    $Cwd = $projectRoot
}

switch ($Action) {
    "run" {
        $started = New-CodexJob -JobName $Name -JobCommand $Command -ProjectRoot $projectRoot -WorkingDirectory $Cwd -CommandShell $Shell
        Wait-CodexJob -JobDir $started.job_dir -PollSeconds $IntervalSec -MaxSeconds $TimeoutSec -ShowProgress:$VerboseProgress
    }
    "start" {
        $started = New-CodexJob -JobName $Name -JobCommand $Command -ProjectRoot $projectRoot -WorkingDirectory $Cwd -CommandShell $Shell
        $started | ConvertTo-Json -Depth 20
    }
    "wait" {
        $jobDir = Resolve-JobDir -ProjectRoot $projectRoot -JobValue $Job
        Wait-CodexJob -JobDir $jobDir -PollSeconds $IntervalSec -MaxSeconds $TimeoutSec -ShowProgress:$VerboseProgress
    }
    "status" {
        $jobDir = Resolve-JobDir -ProjectRoot $projectRoot -JobValue $Job
        Show-Status -JobDir $jobDir
    }
    "list" {
        List-Jobs -ProjectRoot $projectRoot
    }
    "cancel" {
        $jobDir = Resolve-JobDir -ProjectRoot $projectRoot -JobValue $Job
        Cancel-Job -JobDir $jobDir
    }
    "wait-path" {
        Wait-PathArtifact -ProjectRoot $projectRoot -WaitName $Name -PathValue $WatchPath -FilterPattern $Pattern -PollSeconds $IntervalSec -MaxSeconds $TimeoutSec -RequiredCount $MinCount -RequiredStableSec $StableSec -Deep:$Recurse -ShowProgress:$VerboseProgress
    }
    "notification-status" {
        $jobDir = Resolve-JobDir -ProjectRoot $projectRoot -JobValue $Job
        Show-NotificationStatus -JobDir $jobDir
    }
    "mark-notified" {
        $jobDir = Resolve-JobDir -ProjectRoot $projectRoot -JobValue $Job
        Mark-NotificationSent -JobDir $jobDir -TargetThreadId $ThreadId -SentMessageId $MessageId
    }
    "run-worker" {
        if ([string]::IsNullOrWhiteSpace($Job)) { throw "Missing worker -Job." }
        $jobDir = (Resolve-Path -LiteralPath $Job).Path
        Start-Worker -JobDir $jobDir
    }
}
