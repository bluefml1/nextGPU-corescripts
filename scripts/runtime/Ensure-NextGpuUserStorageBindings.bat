@echo off
setlocal EnableExtensions
title Ensure nextGPU user storage bindings

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run as Administrator.
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Ensure-NextGpuUserStorageBindings.ps1"
exit /b %ERRORLEVEL%
