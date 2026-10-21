@echo off
cd /d "%~dp0"
echo [SCAN] only detect, no clicking.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_like.ps1" -DebugScan
pause