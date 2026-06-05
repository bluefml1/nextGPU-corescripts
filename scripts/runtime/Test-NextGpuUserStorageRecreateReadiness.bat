@echo off
setlocal EnableExtensions
title nextGPU storage recreate readiness

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run as Administrator.
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Test-NextGpuUserStorageRecreateReadiness.ps1" %*
set "EC=%ERRORLEVEL%"
pause
exit /b %EC%
