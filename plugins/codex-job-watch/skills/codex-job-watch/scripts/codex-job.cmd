@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-job.ps1" %*
