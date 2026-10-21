@echo off
cd /d "%~dp0"
echo [RUN] like up to 500 posts. Ctrl+C to stop. Keep the mini program window in front.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_like.ps1" -Target 500
pause