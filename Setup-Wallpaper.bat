@echo off
setlocal enabledelayedexpansion

:: Standalone: enable User Configuration "Desktop Wallpaper" (Fill) for all users.
:: Usage: double-click, or: Setup-Wallpaper.bat inline  (from RegisterMachine_Beta.bat)

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "PS1=%SCRIPT_DIR%\Set-DesktopWallpaper-Gpo.ps1"

if not exist "%PS1%" (
    echo ERROR: Set-DesktopWallpaper-Gpo.ps1 not found in:
    echo %SCRIPT_DIR%
    exit /b 1
)

if /i "%~1"=="inline" goto :run_install

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator privileges for wallpaper setup...
    powershell -NoProfile -Command "Start-Process powershell.exe -Verb RunAs -WindowStyle Normal -Wait -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%PS1%\"','-ScriptDir','\"%SCRIPT_DIR%\"'"
    exit /b !errorlevel!
)

:run_install
echo ========================================
echo NextGPU Desktop Wallpaper (Group Policy)
echo ========================================
echo.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -ScriptDir "%SCRIPT_DIR%"
set "ERR=!errorlevel!"
echo.
if !ERR! equ 0 (
    echo [*] Wallpaper policy applied successfully.
) else (
    echo [!] Wallpaper setup failed with exit code !ERR!
)
echo.
if /i not "%~1"=="inline" pause
exit /b !ERR!
