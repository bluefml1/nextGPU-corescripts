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

set "DOMAIN=" & set "PUBLIC_IP=" & set "COMPUTER_NAME="
for /f "tokens=2 delims==" %%A in ('findstr "DOMAIN=" "%DOMAIN_FILE%"') do set "DOMAIN=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "PUBLIC_IP=" "%DOMAIN_FILE%"') do set "PUBLIC_IP=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "COMPUTER_NAME=" "%DOMAIN_FILE%"') do set "COMPUTER_NAME=%%A"

if not defined PUBLIC_IP (echo [ERROR] PUBLIC_IP missing from domain.txt. & goto update_fail)
if not defined COMPUTER_NAME (echo [ERROR] COMPUTER_NAME missing from domain.txt. & goto update_fail)

echo [*] domain.txt: %DOMAIN_FILE%
echo [*] Public IP: !PUBLIC_IP!
echo [*] Computer Name (from domain.txt): !COMPUTER_NAME!
echo [*] Windows COMPUTERNAME (pairing host): %COMPUTERNAME%
echo [*] Domain: !DOMAIN!
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

:: Set updating status
set "UPDATING={\"computer_name\":\"!COMPUTER_NAME!\",\"publicIP\":\"!PUBLIC_IP!\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"updating\"}"
echo updating>"%STATUS_FLAG_FILE%"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "!UPDATING!"
set "ML_DOMAIN_FILE=!DOMAIN_FILE!"
powershell -NoLogo -NoProfile -Command "try{$f=$env:ML_DOMAIN_FILE;$lines=Get-Content -LiteralPath $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=updating'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=updating'};$lines|Set-Content -LiteralPath $f -Encoding UTF8; exit 0}catch{ Write-Output $_.Exception.Message; exit 1 }"
if !errorlevel! neq 0 (
    echo [!] WARNING: Failed to write STATUS=updating to domain.txt ^(exit !errorlevel!^).
) else (
    echo [*] domain.txt STATUS=updating written.
)
echo [*] Remote status set to updating.

set "NEEDS_PAIRING=0"

:: ===================================================================
:: SUNSHINE VERSION CHECK
:: ===================================================================
echo.
echo [*] Checking Sunshine version...
set "VERSION_SS_URL=https://raw.githubusercontent.com/bluefml1/nextGPU-sunshine/my-changes/VERSION"

if not exist "%SUNSHINE_DIR%" mkdir "%SUNSHINE_DIR%"

curl -s -o "%TEMP%\remote_ss_version.txt" "%VERSION_SS_URL%"
if %ERRORLEVEL% NEQ 0 (echo [ERROR] Cannot reach GitHub for Sunshine version. & goto update_moonlight)
if not exist "%TEMP%\remote_ss_version.txt" (echo [ERROR] Sunshine version file not created. & goto update_moonlight)

:: Validate content - must be short and not contain HTML/error keywords
for %%F in ("%TEMP%\remote_ss_version.txt") do if %%~zF GTR 100 (
    echo [ERROR] Sunshine version response looks invalid ^(too large^).
    del "%TEMP%\remote_ss_version.txt" >nul 2>&1
    goto update_moonlight
)

set "REMOTE_SS_VERSION="
for /f "usebackq tokens=* delims= " %%a in ("%TEMP%\remote_ss_version.txt") do if not defined REMOTE_SS_VERSION set "REMOTE_SS_VERSION=%%a"

if not defined REMOTE_SS_VERSION (echo [ERROR] Could not read Sunshine remote version. & goto update_moonlight)

:: Reject if value contains HTML-like characters
echo !REMOTE_SS_VERSION! | findstr /i "<\|404\|Error\|html\|rate" >nul
if not errorlevel 1 (
    echo [ERROR] Sunshine version response contains invalid content: !REMOTE_SS_VERSION!
    del "%TEMP%\remote_ss_version.txt" >nul 2>&1
    goto update_moonlight
)

echo [*] Remote Sunshine version: !REMOTE_SS_VERSION!

set "LOCAL_SS_VERSION="
if exist "%SUNSHINE_DIR%\sunshine-version.txt" (
    for /f "usebackq tokens=* delims= " %%a in ("%SUNSHINE_DIR%\sunshine-version.txt") do if not defined LOCAL_SS_VERSION set "LOCAL_SS_VERSION=%%a"
    echo [*] Local Sunshine version: !LOCAL_SS_VERSION!
) else (
    echo [*] No local Sunshine version - skipping update on first install.
    goto update_moonlight
)

if "!LOCAL_SS_VERSION!"=="!REMOTE_SS_VERSION!" (
    echo [*] Sunshine up to date: !LOCAL_SS_VERSION!
    del "%TEMP%\remote_ss_version.txt" >nul 2>&1
    goto update_moonlight
)

echo [*] Updating Sunshine: !LOCAL_SS_VERSION! -> !REMOTE_SS_VERSION!
set "NEEDS_PAIRING=1"

if exist "C:\Program Files\Sunshine\sunshine.exe" (
    taskkill /f /im Sunshine.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    if exist "C:\Program Files\Sunshine\uninstall.exe" (
        "C:\Program Files\Sunshine\uninstall.exe" /S
        set "UNINSTALL_DONE=0"
        for /L %%i in (1,1,30) do (
            if "!UNINSTALL_DONE!"=="0" (
                timeout /t 1 /nobreak >nul
                if not exist "C:\Program Files\Sunshine\uninstall.exe" set "UNINSTALL_DONE=1"
            )
        )
        if "!UNINSTALL_DONE!"=="0" (
            echo [ERROR] Uninstaller timed out after 30s.
            goto :update_fail
        )
    )
    if exist "C:\Program Files\Sunshine" (
        rd /s /q "C:\Program Files\Sunshine" >nul 2>&1
        if exist "C:\Program Files\Sunshine" (
            echo [ERROR] Failed to remove C:\Program Files\Sunshine
            goto :update_fail
        )
    )
)

if exist "%SUNSHINE_DIR%" (
    rd /s /q "%SUNSHINE_DIR%" >nul 2>&1
    timeout /t 1 /nobreak >nul
    if exist "%SUNSHINE_DIR%" (
        echo [ERROR] Failed to remove %SUNSHINE_DIR%
        goto :update_fail
    )
)

curl -L "https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip" -o "%SUNSHINE_ZIP%" --progress-bar
if !errorlevel! neq 0 (
    powershell -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip' -OutFile '%SUNSHINE_ZIP%' -UseBasicParsing"
    if !errorlevel! neq 0 (echo ERROR: Failed to download Sunshine. & goto :update_fail)
)

mkdir "%SUNSHINE_DIR%" 2>nul
powershell -NoLogo -Command "Expand-Archive -Path '%SUNSHINE_ZIP%' -DestinationPath '%SUNSHINE_DIR%' -Force"
if not exist "%SUNSHINE_DIR%\Sunshine.exe" (echo ERROR: Sunshine.exe missing. & goto :update_fail)
del "%SUNSHINE_ZIP%" >nul

"%SUNSHINE_DIR%\Sunshine.exe" /S
timeout /t 5 /nobreak >nul
"C:\Program Files\Sunshine\sunshine.exe" --creds bluefml1 letmeinpls
taskkill /f /im sunshine.exe >nul 2>&1
timeout /t 2 /nobreak >nul
start "" "C:\Program Files\Sunshine\sunshine.exe"

set "PS_ADDAPP=%SCRIPT_DIR%\sunshine\Add-SteamGames.ps1"
if exist "%PS_ADDAPP%" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%PS_ADDAPP%"
) else (
    echo [!] Add-SteamGames.ps1 not found, skipping.
)

cd /d "%SCRIPT_DIR%"
echo !REMOTE_SS_VERSION!> "%SUNSHINE_DIR%\sunshine-version.txt"
echo [*] Sunshine updated to: !REMOTE_SS_VERSION!

:update_moonlight
echo.
echo [*] Checking Moonlight version...
set "ZIP_ML_URL=https://github.com/bluefml1/nextGPU-moonlight/releases/latest/download/moonlight-theme.zip"
set "VERSION_ML_URL=https://raw.githubusercontent.com/bluefml1/nextGPU-moonlight/main/VERSION.txt"
set "MOONLIGHT_SERVICE=moonlight-web"

if not exist "%LOCAL_ML_DIR%" mkdir "%LOCAL_ML_DIR%"

curl -s -o "%TEMP%\remote_ml_version.txt" "%VERSION_ML_URL%" 2>nul
if %ERRORLEVEL% NEQ 0 (echo [ERROR] Cannot reach GitHub for Moonlight version. & goto check_pairing)

set "REMOTE_ML_VERSION="
for /f "usebackq tokens=* delims= " %%a in ("%TEMP%\remote_ml_version.txt") do if not defined REMOTE_ML_VERSION set "REMOTE_ML_VERSION=%%a"

set "LOCAL_ML_VERSION="
if exist "%LOCAL_ML_DIR%\VERSION.txt" (
    for /f "usebackq tokens=* delims= " %%a in ("%LOCAL_ML_DIR%\VERSION.txt") do if not defined LOCAL_ML_VERSION set "LOCAL_ML_VERSION=%%a"
) else (
    echo [*] No local Moonlight version - skipping update on first install.
    goto check_pairing
)

if "!LOCAL_ML_VERSION!"=="!REMOTE_ML_VERSION!" (
    echo [*] Moonlight up to date: !LOCAL_ML_VERSION! - skipping download/reinstall.
    del "%TEMP%\remote_ml_version.txt" >nul 2>&1
    set "ML_CONFIG_CHECK=%LOCAL_ML_DIR%\server\config.json"
    if exist "!ML_CONFIG_CHECK!" (
        findstr /c:"{{computer_name}}" "!ML_CONFIG_CHECK!" >nul 2>&1
        if not errorlevel 1 (
            echo [!] Moonlight config still contains {{computer_name}} placeholder - config substitution only runs on Moonlight update.
        ) else (
            echo [*] Moonlight config placeholder check: OK ^(no {{computer_name}} in file^).
        )
    ) else (
        echo [!] Moonlight config not found at: !ML_CONFIG_CHECK!
    )
    goto check_pairing
)

echo [*] Updating Moonlight: !LOCAL_ML_VERSION! -> !REMOTE_ML_VERSION!
set "NEEDS_PAIRING=1"

net stop moonlight-web 2>nul
timeout /t 2 /nobreak >nul

"%SystemRoot%\System32\curl.exe" -L -o "%MOONLIGHT_ZIP%" "%ZIP_ML_URL%"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to download Moonlight ZIP.
    net start moonlight-web 2>nul
    goto :update_fail
)

:: Backup
if exist "%LOCAL_ML_DIR%.backup" rmdir /s /q "%LOCAL_ML_DIR%.backup" 2>nul
if exist "%LOCAL_ML_DIR%" xcopy "%LOCAL_ML_DIR%" "%LOCAL_ML_DIR%.backup\" /s /e /i /y >nul 2>&1

set "EXTRACT_TO=%SCRIPT_DIR%\moonlight-tmp"
rmdir /s /q "%EXTRACT_TO%" 2>nul
mkdir "%EXTRACT_TO%"

tar -xf "%MOONLIGHT_ZIP%" -C "%EXTRACT_TO%"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to extract Moonlight ZIP. Restoring backup...
    if exist "%LOCAL_ML_DIR%.backup" (rmdir /s /q "%LOCAL_ML_DIR%" 2>nul & xcopy "%LOCAL_ML_DIR%.backup" "%LOCAL_ML_DIR%\" /s /e /i /y >nul)
    del "%MOONLIGHT_ZIP%" "%TEMP%\remote_ml_version.txt" >nul 2>&1
    rmdir /s /q "%EXTRACT_TO%" 2>nul
    net start moonlight-web 2>nul
    goto :update_fail
)

rmdir /s /q "%LOCAL_ML_DIR%" 2>nul
mkdir "%LOCAL_ML_DIR%"

set "FOUND="
if exist "%EXTRACT_TO%\moonlight-web" (
    xcopy "%EXTRACT_TO%\moonlight-web" "%LOCAL_ML_DIR%\" /s /e /i /y >nul & set "FOUND=1"
) else if exist "%EXTRACT_TO%\static" (
    xcopy "%EXTRACT_TO%\*" "%LOCAL_ML_DIR%\" /s /e /y >nul & set "FOUND=1"
) else (
    for /d %%D in ("%EXTRACT_TO%\*") do (
        if exist "%%D\static" (xcopy "%%D\*" "%LOCAL_ML_DIR%\" /s /e /y >nul & set "FOUND=1" & goto :found_folder)
    )
)
:found_folder

if not defined FOUND (
    echo ERROR: Could not locate moonlight-web folder. Restoring backup...
    if exist "%LOCAL_ML_DIR%.backup" (rmdir /s /q "%LOCAL_ML_DIR%" 2>nul & xcopy "%LOCAL_ML_DIR%.backup" "%LOCAL_ML_DIR%\" /s /e /i /y >nul)
    del "%MOONLIGHT_ZIP%" "%TEMP%\remote_ml_version.txt" >nul 2>&1
    rmdir /s /q "%EXTRACT_TO%" 2>nul
    net start moonlight-web 2>nul
    goto :update_fail
)

echo !REMOTE_ML_VERSION!> "%LOCAL_ML_DIR%\VERSION.txt"
echo [*] Moonlight updated to: !REMOTE_ML_VERSION!
del "%MOONLIGHT_ZIP%" "%TEMP%\remote_ml_version.txt" >nul 2>&1
rmdir /s /q "%EXTRACT_TO%" 2>nul
if exist "%LOCAL_ML_DIR%.backup" rmdir /s /q "%LOCAL_ML_DIR%.backup" 2>nul

:: Reinstall Moonlight service
sc query %MOONLIGHT_SERVICE% >nul 2>&1 && (
    net stop %MOONLIGHT_SERVICE% >nul 2>&1
    "%NSSM_EXE%" remove %MOONLIGHT_SERVICE% confirm >nul 2>&1
    timeout /t 2 /nobreak >nul
)

mkdir "%LOCAL_ML_DIR%\server" 2>nul
call :apply_moonlight_config_substitution
if errorlevel 1 goto :update_fail
set "CONFIG_PATH=%LOCAL_ML_DIR%\server\config.json"
call :validate_json_file "%CONFIG_PATH%" "config.json"
if errorlevel 1 goto :update_fail

echo [*] Installing Moonlight Windows service via NSSM...
"%NSSM_EXE%" install %MOONLIGHT_SERVICE% "%LOCAL_ML_DIR%\web-server.exe" || (
    echo [ERROR] Failed to install Moonlight service ^(nssm install^).
    goto :update_fail
)
echo [*] Moonlight service installed.
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppDirectory "%LOCAL_ML_DIR%" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% Start SERVICE_AUTO_START >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppStdout "%LOG_DIR%\moonlight-web.log" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppStderr "%LOG_DIR%\moonlight-web-error.log" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% DisplayName "Moonlight Web Stream" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% Description "Moonlight Web streaming server for remote GPU access" >nul
net start %MOONLIGHT_SERVICE% >nul
if !errorlevel! neq 0 (
    echo [!] WARNING: net start %MOONLIGHT_SERVICE% returned errorlevel !errorlevel!
) else (
    echo [*] Moonlight service started after reinstall.
)

:check_pairing
if "%NEEDS_PAIRING%"=="0" (echo [*] No updates - skipping pairing. & goto online_status)

echo [*] Updates detected - pairing...
set "MOONLIGHT_DATA=%LOCAL_ML_DIR%\server\data.json"
set "MAX_RETRIES=10"
set /a RETRY_COUNT=0
set "COOKIES=%TEMP%\moonlight_cookies.txt"
set "HOST_NAME=%COMPUTERNAME%"
set "HOST_ID=0"

curl -u bluefml1:letmeinpls -H "Content-Type: application/json" -X POST -k https://localhost:47990/api/restart
net stop %MOONLIGHT_SERVICE% >nul 2>&1

:wait_stop_upd
sc query %MOONLIGHT_SERVICE% | find "STOPPED" >nul
if errorlevel 1 (timeout /t 1 /nobreak >nul & goto :wait_stop_upd)

if exist "%MOONLIGHT_DATA%" del "%MOONLIGHT_DATA%"
echo [*] Downloading Moonlight data.json to: %MOONLIGHT_DATA%
curl -L "https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json" -o "%MOONLIGHT_DATA%"
if !errorlevel! neq 0 (
    echo [!] curl data.json failed ^(errorlevel=!errorlevel!^), trying PowerShell...
    set "ML_DATA_OUT=%MOONLIGHT_DATA%"
    powershell -NoLogo -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json' -OutFile $env:ML_DATA_OUT -UseBasicParsing; exit 0}catch{ Write-Output $_.Exception.Message; exit 1 }"
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to download data.json via curl and PowerShell.
        goto :update_fail
    )
    echo [*] data.json downloaded via PowerShell.
) else (
    echo [*] data.json downloaded via curl.
)
call :validate_json_file "%MOONLIGHT_DATA%" "data.json"
if errorlevel 1 goto :update_fail

net start %MOONLIGHT_SERVICE% >nul 2>&1
:wait_start_upd
sc query %MOONLIGHT_SERVICE% | find "RUNNING" >nul
if errorlevel 1 (timeout /t 1 /nobreak >nul & goto :wait_start_upd)

:: Login
curl.exe -c "%COOKIES%" -X POST "http://127.0.0.1:8080/api/login" -H "Content-Type: application/json" -d "{\"name\":\"test\",\"password\":\"test123\"}" -o "%TEMP%\moonlight_login.json" -s
if !errorlevel! neq 0 (
    echo [!] Moonlight login failed ^(curl errorlevel=!errorlevel!^).
    if exist "%TEMP%\moonlight_login.json" (
        echo [!] Login response file:
        type "%TEMP%\moonlight_login.json"
    ) else (
        echo [!] Login response file not created: %TEMP%\moonlight_login.json
    )
    goto :pairing_cleanup
)

echo [*] Using pre-configured host: ID=!HOST_ID! Name=!HOST_NAME! ^(Windows COMPUTERNAME; domain.txt name is !COMPUTER_NAME!^)
timeout /t 2 /nobreak >nul

:: Pairing loop — PIN request runs in separate cmd /c subprocess (long-poll)
:pin_attempt_upd
taskkill /f /im curl.exe >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1

start /b cmd /c "curl.exe -N -b "%COOKIES%" -X POST "http://127.0.0.1:8080/api/pair" -H "Content-Type: application/json" -d "{\"host_id\":!HOST_ID!}" -o "%TEMP%\moonlight_pin_response.json" -s"

set "PAIRING_PIN="
for /L %%i in (1,1,15) do (
    timeout /t 1 /nobreak >nul
    if exist "%TEMP%\moonlight_pin_response.json" (
        set "_pinfile=%TEMP%\moonlight_pin_response.json"
        for /f "delims=" %%P in ('powershell -NoLogo -NoProfile -Command "try{ $raw=Get-Content -Raw $env:_pinfile; ($raw|ConvertFrom-Json).Pin }catch{ '' }"') do set "PAIRING_PIN=%%P"
        if defined PAIRING_PIN if not "!PAIRING_PIN!"=="" goto :pin_found_upd
    )
)

:pin_found_upd
if not defined PAIRING_PIN (
    echo [!] Pairing attempt !RETRY_COUNT!: no PIN received within 15s.
    goto :pairing_failed_upd
)

echo [*] Pairing attempt !RETRY_COUNT!: PIN received, sending to Sunshine...
curl.exe -u bluefml1:letmeinpls -H "Content-Type: application/json" -X POST -k "https://localhost:47990/api/pin" -d "{\"pin\":\"!PAIRING_PIN!\",\"name\":\"!HOST_NAME!\"}" -o "%TEMP%\moonlight_pair_complete.json" -s --max-time 30
if !errorlevel! neq 0 echo [!] Sunshine pin API curl errorlevel=!errorlevel!

set "SUNSHINE_STATUS="
for /f "delims=" %%S in ('powershell -NoLogo -NoProfile -Command "$f='%TEMP%\moonlight_pair_complete.json'; try{ $j=Get-Content -Raw $f | ConvertFrom-Json; Write-Output $j.status }catch{ Write-Output '' }"') do set "SUNSHINE_STATUS=%%S"
echo [*] Sunshine pin API status: !SUNSHINE_STATUS!
if not defined SUNSHINE_STATUS (
    echo [!] Could not parse moonlight_pair_complete.json:
    if exist "%TEMP%\moonlight_pair_complete.json" type "%TEMP%\moonlight_pair_complete.json"
)

if /i "!SUNSHINE_STATUS!"=="True" (
    timeout /t 3 /nobreak >nul
    set "PAIR_RESULT="
    for /f "delims=" %%R in ('powershell -NoLogo -NoProfile -Command "$f='%TEMP%\moonlight_pin_response.json'; try{ $raw=Get-Content -Raw $f; if($raw -match 'Paired'){'Paired'}else{'PairError'} }catch{'PairError'}"') do set "PAIR_RESULT=%%R"
    echo [*] Moonlight pair response: !PAIR_RESULT!
    if "!PAIR_RESULT!"=="Paired" (echo [*] Pairing successful! & goto :pairing_cleanup)
    echo [!] Sunshine accepted pin but Moonlight did not report Paired.
) else (
    echo [!] Sunshine pin API did not return status True.
)

:pairing_failed_upd
set /a RETRY_COUNT+=1
echo [!] Pairing attempt !RETRY_COUNT! failed.
if !RETRY_COUNT! geq %MAX_RETRIES% (
    echo [ERROR] Pairing failed after %MAX_RETRIES% attempts.
    goto :update_fail
)
timeout /t 2 /nobreak >nul
goto :pin_attempt_upd

:pairing_cleanup
taskkill /f /im curl.exe >nul 2>&1
if exist "%TEMP%\moonlight_login.json" del "%TEMP%\moonlight_login.json" >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1
if exist "%TEMP%\moonlight_pair_complete.json" del "%TEMP%\moonlight_pair_complete.json" >nul 2>&1
if exist "%COOKIES%" del "%COOKIES%" >nul 2>&1
goto online_status

:apply_moonlight_config_substitution
set "CONFIG_PATH=%LOCAL_ML_DIR%\server\config.json"
echo.
echo [*] Moonlight config: preparing config.json...
echo [*] Target path: !CONFIG_PATH!
echo [*] Source COMPUTER_NAME from domain.txt: !COMPUTER_NAME!

if exist "!CONFIG_PATH!" (
    echo [*] Removing existing config.json before download.
    del "!CONFIG_PATH!" >nul 2>&1
)

echo [*] Downloading config.json template ^(curl^)...
curl -L "https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json" -o "!CONFIG_PATH!"
if !errorlevel! neq 0 (
    echo [!] curl download failed ^(errorlevel=!errorlevel!^), trying PowerShell Invoke-WebRequest...
    set "ML_CFG_OUT=!CONFIG_PATH!"
    powershell -NoLogo -NoProfile -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json' -OutFile $env:ML_CFG_OUT -UseBasicParsing; exit 0}catch{ Write-Output $_.Exception.Message; exit 1 }"
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to download config.json via curl and PowerShell.
        exit /b 1
    )
    echo [*] config.json downloaded via PowerShell.
) else (
    echo [*] config.json downloaded via curl.
)

if not exist "!CONFIG_PATH!" (
    echo [ERROR] config.json missing after download: !CONFIG_PATH!
    exit /b 1
)
for %%F in ("!CONFIG_PATH!") do echo [*] config.json size: %%~zF bytes

findstr /c:"{{computer_name}}" "!CONFIG_PATH!" >nul 2>&1
if errorlevel 1 (
    echo [!] Downloaded config.json has no {{computer_name}} placeholder - substitution may be unnecessary.
) else (
    echo [*] Downloaded config.json contains {{computer_name}} placeholder - applying substitution.
)

set "ML_COMPUTER_NAME=!COMPUTER_NAME!"
set "ML_CFG=!CONFIG_PATH!"
set "ML_SUB_LOG=%TEMP%\checking_update_ml_config_sub.log"
echo [*] Running config substitution via PowerShell ^(env: ML_CFG, ML_COMPUTER_NAME - avoids %% in path issues^)...
powershell -NoLogo -NoProfile -Command "try { $n=$env:ML_COMPUTER_NAME; if([string]::IsNullOrWhiteSpace($n)) { Write-Output '[ERROR] ML_COMPUTER_NAME is empty or whitespace'; exit 2 }; $name=$n.Trim().ToLowerInvariant(); Write-Output ('[*] Normalized computer_name: ' + $name); $cfg=$env:ML_CFG; if([string]::IsNullOrWhiteSpace($cfg)) { Write-Output '[ERROR] ML_CFG is empty'; exit 3 }; if(-not (Test-Path -LiteralPath $cfg)) { Write-Output ('[ERROR] Config file not found: ' + $cfg); exit 4 }; $c=[System.IO.File]::ReadAllText($cfg); if($c -notmatch '\{\{computer_name\}\}') { Write-Output '[WARN] No {{computer_name}} placeholder found in config - file unchanged'; exit 0 }; $c2=$c -replace '\{\{computer_name\}\}',$name; $enc=New-Object System.Text.UTF8Encoding $false; [System.IO.File]::WriteAllText($cfg,$c2,$enc); if($c2 -match '\{\{computer_name\}\}') { Write-Output '[ERROR] Placeholder still present after replace'; exit 5 }; Write-Output '[+] config.json substitution successful'; exit 0 } catch { Write-Output ('[ERROR] ' + $_.Exception.Message); exit 1 }" > "!ML_SUB_LOG!" 2>&1
set "ML_SUB_EXIT=!errorlevel!"
if exist "!ML_SUB_LOG!" type "!ML_SUB_LOG!"
if "!ML_SUB_EXIT!" neq "0" (
    echo [ERROR] Moonlight config {{computer_name}} substitution failed ^(PowerShell exit code: !ML_SUB_EXIT!^).
    findstr /c:"{{computer_name}}" "!CONFIG_PATH!" >nul 2>&1
    if not errorlevel 1 echo [ERROR] config.json still contains unreplaced {{computer_name}} placeholder.
    exit /b 1
)

findstr /c:"{{computer_name}}" "!CONFIG_PATH!" >nul 2>&1
if not errorlevel 1 (
    echo [ERROR] Verification failed: config.json still contains {{computer_name}}.
    exit /b 1
)
echo [+] Verified: config.json has no {{computer_name}} placeholder.
exit /b 0

:validate_json_file
set "VJF_PATH=%~1"
set "VJF_NAME=%~2"
echo [*] Validating %VJF_NAME%: %VJF_PATH%
if not exist "%VJF_PATH%" (
    echo [ERROR] %VJF_NAME% not found: %VJF_PATH%
    exit /b 1
)
for %%F in ("%VJF_PATH%") do (
    echo [*] %VJF_NAME% size: %%~zF bytes
    if %%~zF lss 2 (
        echo [ERROR] %VJF_NAME% is empty or too small: %VJF_PATH%
        exit /b 1
    )
)
set "VJF_PS_PATH=!VJF_PATH!"
set "VJF_JSON_LOG=%TEMP%\checking_update_json_validate.log"
powershell -NoLogo -NoProfile -Command "try{$p=$env:VJF_PS_PATH;$raw=[IO.File]::ReadAllText($p);if([string]::IsNullOrWhiteSpace($raw)){Write-Output '[ERROR] JSON file is whitespace-only'; exit 1};$null=$raw|ConvertFrom-Json;exit 0}catch{Write-Output ('[ERROR] JSON parse failed: ' + $_.Exception.Message); exit 1}" > "!VJF_JSON_LOG!" 2>&1
if errorlevel 1 (
    if exist "!VJF_JSON_LOG!" type "!VJF_JSON_LOG!"
    echo [ERROR] %VJF_NAME% is not valid JSON: %VJF_PATH%
    exit /b 1
)
if /i "%VJF_NAME%"=="config.json" (
    findstr /c:"{{computer_name}}" "!VJF_PATH!" >nul 2>&1
    if not errorlevel 1 (
        echo [ERROR] config.json still contains unreplaced {{computer_name}} placeholder after validation.
        exit /b 1
    )
    echo [*] config.json JSON valid and placeholder check passed.
) else (
    echo [*] %VJF_NAME% JSON valid.
)
exit /b 0

:update_fail
echo [!] Update failed. Sending update_fail status...
set "FAILPAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"update_fail\"}"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "%FAILPAYLOAD%"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=update_fail'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=update_fail'};$lines|Set-Content $f"
echo [!] Status set to update_fail.
echo [*] [%date% %time%] cycle finished with status: update_fail
exit /b 1

:online_status
echo online>"%STATUS_FLAG_FILE%"
set "UPDATEPAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"online\"}"
curl -s -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus -H "Content-Type: application/json" -d "%UPDATEPAYLOAD%"
powershell -NoLogo -NoProfile -Command "$f='%DOMAIN_FILE%';$lines=Get-Content $f;$lines=$lines|ForEach-Object{if($_ -match '^STATUS='){'STATUS=online'}else{$_}};if(-not($lines-match'^STATUS=')){$lines+='STATUS=online'};$lines|Set-Content $f"
echo [*] Machine is now online.
echo [*] [%date% %time%] cycle finished with status: online

exit /b 0