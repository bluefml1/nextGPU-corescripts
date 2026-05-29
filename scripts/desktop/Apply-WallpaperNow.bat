@echo off
setlocal
set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
set "PS1=%SCRIPT_IMPL_DIR%\Apply-WallpaperNow.ps1"
if not exist "%PS1%" (
    echo ERROR: Apply-WallpaperNow.ps1 not found.
    exit /b 1
)
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
exit /b %errorlevel%
