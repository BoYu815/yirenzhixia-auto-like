@echo off
cd /d "%~dp0"
echo [TEST] like 3 posts. Keep the mini program window in front.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_like.ps1" -Target 3 -MaxClicks 8
pause