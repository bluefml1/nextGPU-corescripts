@echo off
setlocal EnableExtensions
title Troubleshoot nextGPU User Storage (U:)

net session >nul 2>&1
set "IS_ADMIN=%ERRORLEVEL%"

echo.
echo ========================================
echo  Troubleshoot per-user S3 mount (U:)
echo ========================================
echo.

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

if "%IS_ADMIN%"=="0" (
    echo [*] Running full diagnose + ACL repair ^(Administrator^)...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Troubleshoot-UserStorage.ps1" -RepairAcl
    echo.
    echo Optional: trigger mount for Moonlight session:
    echo   powershell -File "%SCRIPT_DIR%\Invoke-UserStorageMountFromAdmin.ps1"
) else (
    echo [*] Running diagnose ^(not elevated — ACL repair skipped^)...
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\Troubleshoot-UserStorage.ps1"
)

echo.
if "%IS_ADMIN%"=="0" (
    echo Next: sign in as nextGPU, wait 60 seconds, check U: in This PC.
    echo Or as nextGPU run:
    echo   powershell -File "%SCRIPT_DIR%\Mount-UserStorage.ps1"
) else (
    echo Re-run this .bat as Administrator to fix rclone.conf permissions.
)
echo.
pause
