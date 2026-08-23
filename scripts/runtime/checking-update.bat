@echo off
setlocal enabledelayedexpansion

:: ==============================
:: RESOLVE SCRIPT DIRECTORY
:: ==============================
set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)
set "LOG_DIR=%SCRIPT_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOG_FILE=%LOG_DIR%\checking-update.log"

if /i "%~1" neq "__RUN" (
    call "%~f0" __RUN >> "%LOG_FILE%" 2>&1
    exit /b %errorlevel%
)

echo [*] Log file: %LOG_FILE%
echo [*] Script directory: %SCRIPT_DIR%
echo [*] Environment: USERNAME=%USERNAME% USERDOMAIN=%USERDOMAIN% COMPUTERNAME=%COMPUTERNAME%
echo [*] TEMP=%TEMP%

:: Derived paths - everything lives directly in SCRIPT_DIR
set "SUNSHINE_DIR=%SCRIPT_DIR%\sunshine"
set "SUNSHINE_ZIP=%SCRIPT_DIR%\sunshine.zip"
set "LOCAL_ML_DIR=%SCRIPT_DIR%\moonlight-web"
set "MOONLIGHT_ZIP=%SCRIPT_DIR%\moonlight.zip"
set "NSSM_EXE=%SCRIPT_DIR%\nssm\nssm-2.24\win64\nssm.exe"

set "STATUS_FLAG_FILE=%TEMP%\machine_status_flag.txt"

:run_once
echo.
echo ==================================================
echo [*] [%date% %time%] auto-update cycle started
echo ==================================================

:: ==============================
:: READ MACHINE INFO
:: ==============================
set "DOMAIN_FILE=%SCRIPT_DIR%\domain.txt"

if not exist "%DOMAIN_FILE%" (
    echo [ERROR] domain.txt not found at: %DOMAIN_FILE%
    goto update_fail
)

set "DOMAIN=" & set "PUBLIC_IP=" & set "COMPUTER_NAME=" & set "VENDOR_ID_ENABLED=" & set "VENDOR_ID="
for /f "tokens=2 delims==" %%A in ('findstr "DOMAIN=" "%DOMAIN_FILE%"') do set "DOMAIN=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "PUBLIC_IP=" "%DOMAIN_FILE%"') do set "PUBLIC_IP=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "COMPUTER_NAME=" "%DOMAIN_FILE%"') do set "COMPUTER_NAME=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "VENDOR_ID_ENABLED=" "%DOMAIN_FILE%"') do set "VENDOR_ID_ENABLED=%%A"
for /f "tokens=2 delims==" %%A in ('findstr /b "VENDOR_ID=" "%DOMAIN_FILE%"') do set "VENDOR_ID=%%A"

if not defined PUBLIC_IP (echo [ERROR] PUBLIC_IP missing from domain.txt. & goto update_fail)
if not defined COMPUTER_NAME (echo [ERROR] COMPUTER_NAME missing from domain.txt. & goto update_fail)
if not defined VENDOR_ID_ENABLED (
    if defined VENDOR_ID if not "!VENDOR_ID!"=="" (
        set "VENDOR_ID_ENABLED=yes"
    ) else (
        set "VENDOR_ID_ENABLED=no"
    )
)

echo [*] domain.txt: %DOMAIN_FILE%
echo [*] Public IP: !PUBLIC_IP!
echo [*] Computer Name (from domain.txt): !COMPUTER_NAME!
echo [*] Windows COMPUTERNAME (pairing host): %COMPUTERNAME%
echo [*] Domain: !DOMAIN!
echo [*] Vendor ID enabled: !VENDOR_ID_ENABLED!
if /i not "!COMPUTER_NAME!"=="%COMPUTERNAME%" (
    echo [!] NOTE: domain.txt COMPUTER_NAME differs from Windows COMPUTERNAME - config uses domain.txt, pairing uses %%COMPUTERNAME%%.
)

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "192.168.1."') do (
    for /f "tokens=* delims= " %%b in ("%%a") do (set "PRIVATE_IP=%%b" & goto :private_ip_found)
)
:private_ip_found
if not defined PRIVATE_IP set "PRIVATE_IP=127.0.0.1"
echo [*] Availability check disabled. Proceeding with update check...

:: ==============================
:: CHECK MACHINE AVAILABILITY
:: ==============================
rem set "API_URL=https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/getMachineInfor?publicIP=%PUBLIC_IP%&computer_name=!COMPUTER_NAME!"

rem curl -s "%API_URL%" -o "%TEMP%\machine_check.json"

:: Basic validation
if not exist "%TEMP%\machine_check.json" (
    echo [*] Availability API check skipped.
    rem goto machine_not_available
)

:: Check success=true
rem findstr /i "\"success\":true" "%TEMP%\machine_check.json" >nul

:: Check available=yes
rem findstr /i "\"available\":\"yes\"" "%TEMP%\machine_check.json" >nul

echo [+] Proceeding with update check...
goto machine_available

:machine_not_available
echo [!] Machine not available - skipping update.
exit /b 0

:machine_available

echo [+] Update check started.

:: Updating status is published by sunshine/endSession.ps1 (STEP 0) before clean-session.
:: checking-update.bat only runs the stack update and final online / vendor_shutdown paths.
if not exist "%STATUS_FLAG_FILE%" (
    echo updating>"%STATUS_FLAG_FILE%"
)

call "%~dp0Run-StreamingStackUpdate.bat" CheckUpdate CheckUpdate
if errorlevel 1 goto update_fail

:: Vendor hosts: shutdown API only; leave STATUS=updating (no online / offline path)
if /i "!VENDOR_ID_ENABLED!"=="yes" goto vendor_shutdown
goto online_status

:update_fail
echo [!] Update failed. Sending update_fail status...
set "FAILPAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"update_fail\"}"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "%FAILPAYLOAD%"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=update_fail'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=update_fail'};$lines|Set-Content $f"
echo [!] Status set to update_fail.
echo [*] [%date% %time%] cycle finished with status: update_fail
exit /b 1

:vendor_shutdown
echo [*] Vendor host: requesting onDemandGPUHost shutdown; leaving status as updating...
set "VENDOR_SHUTDOWN_PS1=%~dp0Invoke-VendorOfflineShutdown.ps1"
if not exist "%VENDOR_SHUTDOWN_PS1%" (
    echo [ERROR] Invoke-VendorOfflineShutdown.ps1 not found. Skipping shutdown; leaving status as updating.
    exit /b 1
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%VENDOR_SHUTDOWN_PS1%" -ComputerName "%COMPUTER_NAME%"
if errorlevel 1 (
    echo [!] Vendor shutdown sequence failed ^(exit !errorlevel!^). Machine left running; status remains updating.
    exit /b 1
)
echo updating>"%STATUS_FLAG_FILE%"
echo [*] Vendor shutdown requested; status left as updating.
echo [*] [%date% %time%] cycle finished with status: updating
exit /b 0

:online_status
echo online>"%STATUS_FLAG_FILE%"
set "UPDATEPAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"online\"}"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "%UPDATEPAYLOAD%"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=online'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=online'};$lines|Set-Content $f"
echo [*] Machine is now online.
echo [*] [%date% %time%] cycle finished with status: online

exit /b 0
