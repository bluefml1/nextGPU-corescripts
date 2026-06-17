@echo off
setlocal enabledelayedexpansion
:: Single update cycle (for Task Scheduler). Does not loop.

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

:: Derived paths - everything lives directly in SCRIPT_DIR
set "SUNSHINE_DIR=%SCRIPT_DIR%\sunshine"
set "SUNSHINE_ZIP=%SCRIPT_DIR%\sunshine.zip"
set "LOCAL_ML_DIR=%SCRIPT_DIR%\moonlight-web"
set "MOONLIGHT_ZIP=%SCRIPT_DIR%\moonlight.zip"
set "NSSM_EXE=%SCRIPT_DIR%\nssm\nssm-2.24\win64\nssm.exe"
set "LOG_DIR=%SCRIPT_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

set "STATUS_FLAG_FILE=%TEMP%\machine_status_flag.txt"

:: ==============================
:: READ MACHINE INFO
:: ==============================
set "DOMAIN_FILE=%SCRIPT_DIR%\domain.txt"

if not exist "%DOMAIN_FILE%" (
    echo [ERROR] domain.txt not found at: %DOMAIN_FILE%
    exit /b 1
)

set "DOMAIN=" & set "PUBLIC_IP=" & set "COMPUTER_NAME="
for /f "tokens=2 delims==" %%A in ('findstr "DOMAIN=" "%DOMAIN_FILE%"') do set "DOMAIN=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "PUBLIC_IP=" "%DOMAIN_FILE%"') do set "PUBLIC_IP=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "COMPUTER_NAME=" "%DOMAIN_FILE%"') do set "COMPUTER_NAME=%%A"

if not defined PUBLIC_IP (echo [ERROR] PUBLIC_IP missing. & exit /b 1)
if not defined COMPUTER_NAME (echo [ERROR] COMPUTER_NAME missing. & exit /b 1)

echo [*] Public IP: !PUBLIC_IP!
echo [*] Computer Name: !COMPUTER_NAME!
echo [*] Domain: !DOMAIN!

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "192.168.1."') do (
    for /f "tokens=* delims= " %%b in ("%%a") do (set "PRIVATE_IP=%%b" & goto :private_ip_found)
)
:private_ip_found
if not defined PRIVATE_IP set "PRIVATE_IP=127.0.0.1"

:: ==============================
:: CHECK MACHINE AVAILABILITY
:: ==============================
set "API_URL=https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/getMachineInfor?publicIP=%PUBLIC_IP%&computer_name=!COMPUTER_NAME!"

curl -s "%API_URL%" -o "%TEMP%\machine_check.json"

:: Basic validation
if not exist "%TEMP%\machine_check.json" (
    echo [ERROR] API response missing.
    goto machine_not_available
)

:: Check success=true
findstr /i "\"success\":true" "%TEMP%\machine_check.json" >nul || goto machine_not_available

:: Check available=yes
findstr /i "\"available\":\"yes\"" "%TEMP%\machine_check.json" >nul || goto machine_not_available

echo [+] Machine available. Proceeding with update check...
goto machine_available

:machine_not_available
echo [!] Machine not available - skipping update.
exit /b 0

:machine_available

echo [+] Machine available. Proceeding with update check...

:: Set updating status
set "UPDATING={\"computer_name\":\"!COMPUTER_NAME!\",\"publicIP\":\"!PUBLIC_IP!\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"updating\"}"
echo updating>"%STATUS_FLAG_FILE%"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "!UPDATING!"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=updating'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=updating'};$lines|Set-Content $f"
echo [*] Status set to updating.

call "%~dp0Run-StreamingStackUpdate.bat" CheckUpdate CheckUpdate
if errorlevel 1 goto :update_fail
goto online_status
:update_fail
echo [!] Update failed. Sending update_fail status...
set "FAILPAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"update_fail\"}"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "%FAILPAYLOAD%"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=update_fail'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=update_fail'};$lines|Set-Content $f"
echo [!] Status set to update_fail.
exit /b 1

:online_status
echo online>"%STATUS_FLAG_FILE%"
set "UPDATEPAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"online\"}"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "%UPDATEPAYLOAD%"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=online'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=online'};$lines|Set-Content $f"
echo [*] Machine is now online.
exit /b 0
