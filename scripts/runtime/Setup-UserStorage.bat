@echo off
setlocal EnableExtensions
title nextGPU User Storage - Setup (run from this folder)

net session >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Run as Administrator.
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

echo.
echo Running Setup from: %SCRIPT_DIR%
echo (Uses Install-*.ps1 in THIS folder, not ProgramData only.)
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\User-Storage.ps1" -LaunchDir "%SCRIPT_DIR%" Setup
pause
exit /b %ERRORLEVEL%
