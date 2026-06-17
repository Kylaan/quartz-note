@echo off
REM One-click publish launcher. Args (e.g. -Preview) are forwarded to the ps1.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish.ps1" %*
echo.
pause
