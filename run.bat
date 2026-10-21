@echo off
rem 一键启动（绕过 PowerShell 执行策略限制）
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0auto_like.ps1" %*
pause
