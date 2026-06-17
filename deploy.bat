@echo off
REM Build images locally and ship to NAS + cloud. Args (-NasOnly/-CloudOnly) forwarded.
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy.ps1" %*
echo.
pause
