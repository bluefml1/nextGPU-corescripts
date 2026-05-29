@echo off
setlocal enabledelayedexpansion

:: Restrict shutdown/restart to NextGPU-Authority only.
:: Usage: double-click, or: Setup-Shutdown-Policy.bat inline

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)
set "PS1=%SCRIPT_DIR%\scripts\desktop\Set-ShutdownPolicy.ps1"

if not exist "%PS1%" (
    echo ERROR: Set-ShutdownPolicy.ps1 not found in:
    echo %SCRIPT_DIR%
    exit /b 1
)

if /i "%~1"=="inline" goto :run_install

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator privileges for shutdown policy...
    powershell -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -WindowStyle Normal -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS1%\"','-ScriptDir','\"%SCRIPT_DIR%\"'"
    exit /b !errorlevel!
)

:run_install
echo ========================================
echo NextGPU Shutdown / Restart Lock
echo ========================================
echo.
echo Only NextGPU-Authority may shut down or restart this PC.
echo nextGPU and other users are blocked.
echo.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -ScriptDir "%SCRIPT_DIR%"
set "ERR=!errorlevel!"
echo.
if !ERR! equ 0 (
    echo [*] Shutdown policy applied successfully.
) else (
    echo [!] Shutdown policy failed with exit code !ERR!
)
echo.
if /i not "%~1"=="inline" pause
exit /b !ERR!
