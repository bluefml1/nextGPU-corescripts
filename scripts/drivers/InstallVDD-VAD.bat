@echo off
setlocal enabledelayedexpansion

:: ONE-CLICK: double-click this file. Downloads + installs VDD and VAD when missing/broken.
:: Skips when drivers are already ready. Use: InstallVDD-VAD.bat force  to reinstall anyway.
:: Log: logs\VDD-VAD.log

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)
set "LOG_DIR=%SCRIPT_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOG_FILE=%LOG_DIR%\VDD-VAD.log"
set "INSTALL_DIR=%SCRIPT_DIR%\VDD-VAD-Install"
set "PS1=%SCRIPT_DIR%\scripts\drivers\silent-install-vdd-vad.ps1"
set "PS_ARGS=-SkipIfInstalled"

if not exist "%PS1%" (
    call :log "ERROR: Missing %PS1%"
    exit /b 1
)

if /i "%~1"=="hidden" (
    shift /1
    goto run_install
)

if /i "%~1"=="force" set "PS_ARGS=-Force"

call :log "========== One-click VDD+VAD (launcher) =========="
call :log "Double-click install started."
fltmc >nul 2>&1
if errorlevel 1 (
    call :log "UAC: click Yes to download and install drivers."
    if /i "%PS_ARGS%"=="-Force" (
        powershell -NoProfile -WindowStyle Normal -Command "Start-Process -FilePath '%~f0' -ArgumentList 'hidden','force' -Verb RunAs -WindowStyle Normal -Wait"
    ) else (
        powershell -NoProfile -WindowStyle Normal -Command "Start-Process -FilePath '%~f0' -ArgumentList 'hidden' -Verb RunAs -WindowStyle Normal -Wait"
    )
    set "ERR=!errorlevel!"
    call :log "Elevated install finished. Exit code !ERR!"
    exit /b !ERR!
)
goto run_install

:run_install
if /i "%~1"=="force" set "PS_ARGS=-Force"

call :log "========== One-click VDD+VAD (install run) =========="
echo [*] VDD/VAD progress will print below and also write to %LOG_FILE%

powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "%PS1%" -LogPath "%LOG_FILE%" -InstallDir "%INSTALL_DIR%" %PS_ARGS%
set "ERR=!errorlevel!"
call :log "Finished. Exit code !ERR! (0=success)"
exit /b !ERR!

:log
>>"%LOG_FILE%" echo [%date% %time%] %~1
exit /b
