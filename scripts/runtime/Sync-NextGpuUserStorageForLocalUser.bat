@echo off
setlocal EnableExtensions
title Sync nextGPU user storage (after user recreate)

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run as Administrator.
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

echo.
echo Re-binds scheduled tasks and ACLs to the current local nextGPU account.
echo Usually automatic via nextGPU-UserStorageEnsureBindings (boot + nextGPU logon).
echo Use this only if you recreated nextGPU before that task existed, or for immediate fix.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Sync-NextGpuUserStorageForLocalUser.ps1"
exit /b %ERRORLEVEL%
