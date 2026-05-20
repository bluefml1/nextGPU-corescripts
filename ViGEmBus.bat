@echo off
setlocal enabledelayedexpansion

:: ViGEm Bus Driver - download and silent install (hidden, no restart)

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
set "LOG_FILE=%SCRIPT_DIR%\ViGEmBus.log"

if /i "%~1"=="inline" goto :vigem_install

if /i not "%~1"=="hidden" (
    call :log "========== ViGEmBus session start (launcher) =========="
    call :log "Script=%~f0"
    fltmc >nul 2>&1
    if errorlevel 1 (
        call :log "Not elevated; requesting admin and relaunching hidden."
        powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -ArgumentList 'hidden' -Verb RunAs -WindowStyle Hidden"
    ) else (
        call :log "Already elevated; relaunching hidden."
        powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -ArgumentList 'hidden' -WindowStyle Hidden"
    )
    call :log "Launcher exiting. Log file: %LOG_FILE%"
    exit /b
)

:vigem_install
call :log "========== ViGEmBus install run =========="
call :log "Host=%COMPUTERNAME% User=%USERNAME% OS=%OS%"

set "VIGEM_URL=https://github.com/nefarius/ViGEmBus/releases/download/v1.21.442.0/ViGEmBus_1.21.442_x64_x86_arm64.exe"
set "VIGEM_EXE=%TEMP%\ViGEmBus_1.21.442_x64_x86_arm64.exe"
set "VIGEM_PRODUCT={9C581C76-2D68-40F8-AA6F-94D3C5215C05}"
call :log "URL=%VIGEM_URL%"
call :log "Installer=%VIGEM_EXE%"
call :log "ProductCode=%VIGEM_PRODUCT%"

:: Skip if already installed
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
if !errorlevel! equ 0 (
    call :log "SKIP: ViGEmBus already installed (HKLM Uninstall x64)."
    call :log "Exit code 0"
    exit /b 0
)
reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
if !errorlevel! equ 0 (
    call :log "SKIP: ViGEmBus already installed (HKLM Uninstall WOW6432)."
    call :log "Exit code 0"
    exit /b 0
)
call :log "Registry check: not installed; proceeding with download."

if exist "%VIGEM_EXE%" (
    call :log "Removing stale installer at %VIGEM_EXE%"
    del /f /q "%VIGEM_EXE%" >nul 2>&1
)

call :log "Downloading with curl..."
curl -L -s "%VIGEM_URL%" -o "%VIGEM_EXE%" --retry 3
set "DL_ERR=!errorlevel!"
if !DL_ERR! neq 0 (
    call :log "WARN: curl failed with exit code !DL_ERR!; trying PowerShell Invoke-WebRequest."
    powershell -NoProfile -WindowStyle Hidden -Command ^
        "$ProgressPreference='SilentlyContinue';" ^
        "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;" ^
        "Invoke-WebRequest -Uri '%VIGEM_URL%' -OutFile '%VIGEM_EXE%' -UseBasicParsing"
    set "DL_ERR=!errorlevel!"
    if !DL_ERR! neq 0 (
        call :log "ERROR: Download failed (PowerShell exit !DL_ERR!)."
        call :log "Exit code 1"
        exit /b 1
    )
    call :log "Download OK via PowerShell."
) else (
    call :log "Download OK via curl."
)

if not exist "%VIGEM_EXE%" (
    call :log "ERROR: Installer file missing after download."
    call :log "Exit code 1"
    exit /b 1
)

for %%A in ("%VIGEM_EXE%") do call :log "Installer size: %%~zA bytes"

call :log "Installing silently (/exenoui /qn /norestart)..."
powershell -NoProfile -WindowStyle Hidden -Command ^
    "$p = Start-Process -FilePath '%VIGEM_EXE%' -ArgumentList '/exenoui','/qn','/norestart' -Wait -PassThru -WindowStyle Hidden;" ^
    "exit $p.ExitCode"
set "INSTALL_ERR=!errorlevel!"
call :log "Installer exit code: !INSTALL_ERR!"

shutdown /a >nul 2>&1
if !errorlevel! equ 0 call :log "Cancelled a pending system restart (shutdown /a)."
timeout /t 3 /nobreak >nul

reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
if !errorlevel! equ 0 (
    call :log "Post-install verify: product found in registry (x64)."
) else (
    reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
    if !errorlevel! equ 0 (
        call :log "Post-install verify: product found in registry (WOW6432)."
    ) else (
        call :log "WARN: Post-install verify: product not found in uninstall registry."
    )
)

if exist "%VIGEM_EXE%" (
    del /f /q "%VIGEM_EXE%" >nul 2>&1
    call :log "Removed installer from %TEMP%."
)

if !INSTALL_ERR! equ 0 (
    call :log "SUCCESS: ViGEmBus install completed."
) else (
    call :log "ERROR: ViGEmBus install failed."
)
call :log "Exit code !INSTALL_ERR!"
call :log "========== ViGEmBus install run end =========="
exit /b !INSTALL_ERR!

:log
>>"%LOG_FILE%" echo [%date% %time%] %~1
exit /b
