@echo off
setlocal enabledelayedexpansion

:: ViGEm Bus Driver - download and silent install (no restart; console stays visible)

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)
set "LOG_DIR=%SCRIPT_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOG_FILE=%LOG_DIR%\ViGEmBus.log"

if /i "%~1"=="inline" (
    set "VIGEM_CONSOLE=1"
    goto :vigem_install
)

call :log "========== ViGEmBus session start (launcher) =========="
call :log "Script=%~f0"
fltmc >nul 2>&1
if errorlevel 1 (
    call :log "Not elevated; requesting admin (visible window)."
    echo Requesting Administrator privileges for ViGEmBus...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'inline' -Verb RunAs -WindowStyle Normal -Wait"
    set "ERR=!errorlevel!"
    call :log "Elevated install finished. Exit code !ERR!"
    exit /b !ERR!
)
set "VIGEM_CONSOLE=1"
goto :vigem_install

:vigem_install
call :log "========== ViGEmBus install run =========="
call :log "Host=%COMPUTERNAME% User=%USERNAME% OS=%OS%"

set "VIGEM_URL=https://github.com/nefarius/ViGEmBus/releases/download/v1.21.442.0/ViGEmBus_1.21.442_x64_x86_arm64.exe"
set "VIGEM_EXE=%TEMP%\ViGEmBus_1.21.442_x64_x86_arm64.exe"
set "VIGEM_PRODUCT={9C581C76-2D68-40F8-AA6F-94D3C5215C05}"
call :log "URL=%VIGEM_URL%"
call :log "Installer=%VIGEM_EXE%"
call :log "ProductCode=%VIGEM_PRODUCT%"

call :uninstall_vigem_if_present

call :log "Proceeding with ViGEmBus download and install."

if exist "%VIGEM_EXE%" (
    call :log "Removing stale installer at %VIGEM_EXE%"
    del /f /q "%VIGEM_EXE%" >nul 2>&1
)

call :log "Downloading with curl..."
curl -L -s "%VIGEM_URL%" -o "%VIGEM_EXE%" --retry 3
set "DL_ERR=!errorlevel!"
if !DL_ERR! neq 0 (
    call :log "WARN: curl failed with exit code !DL_ERR!; trying PowerShell Invoke-WebRequest."
    powershell -NoProfile -Command ^
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
"%VIGEM_EXE%" /exenoui /qn /norestart
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

:detect_vigem_installed
set "VIGEM_PRESENT="
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
if !errorlevel! equ 0 set "VIGEM_PRESENT=1"
if not defined VIGEM_PRESENT (
    reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
    if !errorlevel! equ 0 set "VIGEM_PRESENT=1"
)
if not defined VIGEM_PRESENT (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "if(Get-PnpDevice -ErrorAction SilentlyContinue|Where-Object{$_.InstanceId -like 'ROOT\ViGEmBus*'}|Select-Object -First 1){exit 0};exit 1" >nul 2>&1
    if !errorlevel! equ 0 set "VIGEM_PRESENT=1"
)
exit /b 0

:uninstall_vigem_if_present
call :detect_vigem_installed
if not defined VIGEM_PRESENT (
    call :log "No existing ViGEmBus install detected."
    exit /b 0
)
call :log "Existing ViGEmBus detected; uninstalling before fresh install..."

reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
set "VIGEM_MSI_PRESENT=0"
if !errorlevel! equ 0 set "VIGEM_MSI_PRESENT=1"
if "!VIGEM_MSI_PRESENT!"=="0" (
    reg query "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\%VIGEM_PRODUCT%" >nul 2>&1
    if !errorlevel! equ 0 set "VIGEM_MSI_PRESENT=1"
)
if "!VIGEM_MSI_PRESENT!"=="1" (
    call :log "Running msiexec /x %VIGEM_PRODUCT% /qn /norestart ..."
    msiexec /x %VIGEM_PRODUCT% /qn /norestart
    set "UNINST_ERR=!errorlevel!"
    call :log "msiexec uninstall exit code: !UNINST_ERR!"
    timeout /t 5 /nobreak >nul
) else (
    call :log "ViGEmBus MSI product not in uninstall registry; removing PnP devices only."
)

call :log "Removing ViGEmBus PnP devices (if any)..."
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
    "$devs=@(Get-PnpDevice -ErrorAction SilentlyContinue|Where-Object{$_.InstanceId -like 'ROOT\ViGEmBus*'});" ^
    "foreach($d in $devs){try{pnputil /remove-device $d.InstanceId 2^>$null|Out-Null}catch{};try{Remove-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue}catch{}};" ^
    "if($devs.Count -gt 0){Write-Host ('[*] Removed '+$devs.Count+' ViGEmBus PnP device(s).')}else{Write-Host '[*] No ViGEmBus PnP devices found.'}"

shutdown /a >nul 2>&1
if !errorlevel! equ 0 call :log "Cancelled a pending system restart after uninstall (shutdown /a)."
timeout /t 2 /nobreak >nul

call :detect_vigem_installed
if defined VIGEM_PRESENT (
    call :log "WARN: ViGEmBus may still be present after uninstall; continuing with install anyway."
) else (
    call :log "ViGEmBus uninstall completed."
)
exit /b 0

:log
if defined VIGEM_CONSOLE echo [%date% %time%] %~1
>>"%LOG_FILE%" echo [%date% %time%] %~1
exit /b
