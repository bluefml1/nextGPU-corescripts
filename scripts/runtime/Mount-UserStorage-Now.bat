@echo off
setlocal EnableExtensions
title Mount U: for nextGPU (Moonlight)

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run as Administrator while renter is connected in Moonlight.
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

echo.
echo Mount per-user S3 as U: in the nextGPU session (not your Admin desktop).
echo Renter must be connected in Moonlight first.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Invoke-UserStorageMountFromAdmin.ps1"
exit /b %ERRORLEVEL%
