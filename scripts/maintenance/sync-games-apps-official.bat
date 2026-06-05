@echo off
setlocal enabledelayedexpansion

fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    goto :EOF
)

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)

set "PS_SCRIPT=%SCRIPT_DIR%\scripts\maintenance\Sync-GamesApps-Official.ps1"
if not exist "%PS_SCRIPT%" (
    echo ERROR: Sync-GamesApps-Official.ps1 not found at "%PS_SCRIPT%"
    pause
    exit /b 1
)

echo Running official NextGPU game/apps sync...
echo.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "ERR=!errorlevel!"
echo.
if !ERR! neq 0 (
    echo [!] Sync exited with code !ERR!
) else (
    echo [*] Sync completed.
)
echo.
pause
exit /b !ERR!
