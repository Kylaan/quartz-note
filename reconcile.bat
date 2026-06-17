@echo off
REM Double-click launcher for reconcile-bucket.ps1 (keeps the window open).
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0reconcile-bucket.ps1"
echo.
pause
