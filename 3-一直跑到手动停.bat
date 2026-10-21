@echo off
cd /d "%~dp0"
echo [RUN] like forever (Target=0), press Ctrl+C to stop.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_like.ps1" -Target 0
pause