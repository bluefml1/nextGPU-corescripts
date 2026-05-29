@echo off
setlocal enabledelayedexpansion

:: Standalone: enable desktop wallpaper (Fit) plus lock/sign-in wallpaper.
:: Usage: double-click, or: Setup-Wallpaper.bat inline  (from RegisterMachine_Beta.bat)

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)
set "PS1=%SCRIPT_DIR%\scripts\desktop\Set-DesktopWallpaper-Gpo.ps1"

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
echo NextGPU Desktop + Sign-in Wallpaper
echo ========================================
echo.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -ScriptDir "%SCRIPT_DIR%"
set "ERR=!errorlevel!"
echo.
if !ERR! equ 0 (
    echo [*] Desktop and sign-in wallpaper applied successfully.
    echo [*] To see what is active, run: scripts\desktop\Test-WallpaperPolicy.ps1
    echo [*] Then REBOOT once. After reboot, sign in as nextGPU and wait ~90s.
    echo [*] If still cropped: scripts\desktop\Apply-WallpaperNow.bat while logged in as that user.
) else (
    echo [!] Wallpaper setup failed with exit code !ERR!
)
echo.
if /i not "%~1"=="inline" pause
exit /b !ERR!
