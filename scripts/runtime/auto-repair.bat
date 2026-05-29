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

set "MOONLIGHT_DIR=%SCRIPT_DIR%\moonlight-web"
set "MOONLIGHT_SERVICE=moonlight-web"
set "NSSM_EXE=%SCRIPT_DIR%\nssm\nssm-2.24\win64\nssm.exe"
set "SUNSHINE_SERVICE=gpu-sunshine"
set "LOG_DIR=%SCRIPT_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1

if /i "%~1"=="once" set "RUN_ONCE=1"

:wait_for_network
ping -n 1 8.8.8.8 >nul
if errorlevel 1 (timeout /t 5 /nobreak >nul & goto wait_for_network)

set "CHECK_INTERVAL=60"

:loop
echo.

:: ==============================
:: CHECK DOMAIN STATUS
:: ==============================
set "DOMAIN_FILE=%SCRIPT_DIR%\domain.txt"
set "DOMAIN_STATUS="
set "COMPUTER_NAME="
if exist "%DOMAIN_FILE%" (
    for /f "tokens=2 delims==" %%A in ('findstr "STATUS=" "%DOMAIN_FILE%"') do set "DOMAIN_STATUS=%%A"
    for /f "tokens=2 delims==" %%A in ('findstr "COMPUTER_NAME=" "%DOMAIN_FILE%"') do set "COMPUTER_NAME=%%A"
)
if /i "!DOMAIN_STATUS!"=="updating" (
    echo [*] Machine is currently updating - skipping repair. Retrying in %CHECK_INTERVAL%s.
    timeout /t %CHECK_INTERVAL% /nobreak >nul
    goto loop
)

echo [*] Running health check...
set "REPAIR_NEEDED=0"
set "REPAIR_REASON="

:: ==============================
:: CHECK 1: cloudflared service
:: ==============================
sc query cloudflared | find "RUNNING" >nul
if errorlevel 1 (
    echo [!] cloudflared is NOT running. Attempting restart...
    net start cloudflared >nul 2>&1
    timeout /t 3 /nobreak >nul
    sc query cloudflared | find "RUNNING" >nul
    if errorlevel 1 (
        echo [!] cloudflared restart failed.
        set "REPAIR_NEEDED=1"
        set "REPAIR_REASON=cloudflared down"
    ) else (
        echo [*] cloudflared restarted OK.
    )
) else (
    echo [*] cloudflared: OK
)

:: ==============================
:: CHECK 2: Sunshine process (user session, not session-0 service)
:: ==============================
tasklist /fi "imagename eq sunshine.exe" 2>nul | find /i "sunshine.exe" >nul
if errorlevel 1 (
    echo [!] Sunshine is NOT running. Starting in user session...
    if exist "C:\Program Files\Sunshine\sunshine.exe" (
        set "SUNSHINE_SESSION_PS1=%SCRIPT_DIR%\scripts\provisioning\Start-Sunshine-InSession.ps1"
        if exist "%SUNSHINE_SESSION_PS1%" (
            powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SUNSHINE_SESSION_PS1%" -Quiet >nul 2>&1
        ) else (
            schtasks /Run /TN "nextGPU-SunshineLogon" >nul 2>&1
        )
        timeout /t 5 /nobreak >nul
        tasklist /fi "imagename eq sunshine.exe" 2>nul | find /i "sunshine.exe" >nul
        if errorlevel 1 (
            echo [!] Sunshine still down. RDP/console logon may be required after reboot.
            set "REPAIR_NEEDED=1"
            if not defined REPAIR_REASON set "REPAIR_REASON=Sunshine down"
        ) else (
            echo [*] Sunshine started in user session.
        )
    ) else (
        echo [!] Sunshine.exe not found - full reinstall needed.
        set "REPAIR_NEEDED=1"
        if not defined REPAIR_REASON set "REPAIR_REASON=Sunshine missing"
    )
) else (
    echo [*] Sunshine process: OK
)

:: ==============================
:: CHECK 3: moonlight-web service
:: ==============================
sc query moonlight-web | find "RUNNING" >nul
if errorlevel 1 (
    echo [!] moonlight-web is NOT running. Attempting restart...
    net start moonlight-web >nul 2>&1
    timeout /t 3 /nobreak >nul
    sc query moonlight-web | find "RUNNING" >nul
    if errorlevel 1 (
        echo [!] moonlight-web restart failed.
        set "REPAIR_NEEDED=1"
        if not defined REPAIR_REASON set "REPAIR_REASON=moonlight-web down"
    ) else (
        echo [*] moonlight-web restarted OK.
    )
) else (
    echo [*] moonlight-web: OK
)

:: ==============================
:: CHECK 4: local HTTP response
:: ==============================
for /f %%S in ('curl -o nul -s -w "%%{http_code}" --max-time 10 http://127.0.0.1:8080') do set "HTTP_STATUS=%%S"
if "!HTTP_STATUS!"=="200" (
    echo [*] Local service http://127.0.0.1:8080: OK
) else (
    echo [!] Local service returned status: !HTTP_STATUS!
    set "REPAIR_NEEDED=1"
    if not defined REPAIR_REASON set "REPAIR_REASON=HTTP !HTTP_STATUS!"
)

:: ==============================
:: ALL OK - SKIP
:: ==============================
if "!REPAIR_NEEDED!"=="0" (
    echo [*] All checks passed. Next check in %CHECK_INTERVAL%s.
    if defined RUN_ONCE (echo [*] Single run complete. & exit /b 0)
    timeout /t %CHECK_INTERVAL% /nobreak >nul
    goto loop
)

echo.
echo [!] Health check failed. Reason: !REPAIR_REASON!
echo [!] Starting full repair...
echo ====================================================================

:: ===================================================================
:: STEP 1: Reinstall Sunshine
:: ===================================================================
echo.
echo [*] Step 1: Reinstalling Sunshine...
set "SUNSHINE_ZIP=%SCRIPT_DIR%\sunshine.zip"
set "SUNSHINE_DIR=%SCRIPT_DIR%\sunshine"

if exist "C:\Program Files\Sunshine\sunshine.exe" (
    sc query %SUNSHINE_SERVICE% >nul 2>&1 && (net stop %SUNSHINE_SERVICE% >nul 2>&1)
    echo [*] Uninstalling existing Sunshine...
    taskkill /f /im Sunshine.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    if exist "C:\Program Files\Sunshine\uninstall.exe" (
        "C:\Program Files\Sunshine\uninstall.exe" /S
        timeout /t 5 /nobreak >nul
    )
    if exist "C:\Program Files\Sunshine" rd /s /q "C:\Program Files\Sunshine" >nul 2>&1
    echo [*] Old Sunshine removed.
)

if exist "%SUNSHINE_DIR%" (rd /s /q "%SUNSHINE_DIR%" & timeout /t 1 /nobreak >nul)
if exist "%SUNSHINE_ZIP%" del "%SUNSHINE_ZIP%" >nul

echo [*] Downloading Sunshine...
curl -L "https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip" -o "%SUNSHINE_ZIP%" --progress-bar
if !errorlevel! neq 0 (
    powershell -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip' -OutFile '%SUNSHINE_ZIP%' -UseBasicParsing"
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to download Sunshine.
        goto repair_failed
    )
)

mkdir "%SUNSHINE_DIR%" 2>nul
powershell -NoLogo -Command "Expand-Archive -Path '%SUNSHINE_ZIP%' -DestinationPath '%SUNSHINE_DIR%' -Force"
if not exist "%SUNSHINE_DIR%\Sunshine.exe" (
    echo [ERROR] Sunshine.exe missing after extract.
    goto repair_failed
)
del "%SUNSHINE_ZIP%" >nul

echo [*] Installing Sunshine...
"%SUNSHINE_DIR%\Sunshine.exe" /S
timeout /t 5 /nobreak >nul

if not exist "C:\Program Files\Sunshine\sunshine.exe" (
    echo [ERROR] Sunshine did not install correctly.
    goto repair_failed
)

"C:\Program Files\Sunshine\sunshine.exe" --creds bluefml1 letmeinpls
set "SUNSHINE_SESSION_PS1=%SCRIPT_DIR%\scripts\provisioning\Start-Sunshine-InSession.ps1"
if exist "%SUNSHINE_SESSION_PS1%" (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SUNSHINE_SESSION_PS1%" -Quiet >nul 2>&1
) else (
    taskkill /f /im sunshine.exe >nul 2>&1
    timeout /t 2 /nobreak >nul
    start "" "C:\Program Files\Sunshine\sunshine.exe"
)
timeout /t 3 /nobreak >nul

:: Verify Sunshine is actually running
tasklist /fi "imagename eq sunshine.exe" 2>nul | find /i "sunshine.exe" >nul
if errorlevel 1 (
    echo [ERROR] Sunshine failed to start after install.
    goto repair_failed
)

set "PS_ADDAPP=%SCRIPT_DIR%\sunshine\Add-SteamGames.ps1"
if exist "%PS_ADDAPP%" (
    echo [*] Running Steam game importer...
    powershell -ExecutionPolicy Bypass -NoProfile -File "%PS_ADDAPP%"
) else (
    echo [!] Add-SteamGames.ps1 not found, skipping.
)

set "SUNSHINE_RESTART_PS1=%SCRIPT_DIR%\scripts\provisioning\Invoke-SunshineApiRestart.ps1"
if exist "%SUNSHINE_RESTART_PS1%" (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SUNSHINE_RESTART_PS1%" -WaitAfterSec 5 >nul 2>&1
) else (
    curl -u bluefml1:letmeinpls -H "Content-Type: application/json" -X POST -k https://localhost:47990/api/restart >nul 2>&1
)
echo [*] Sunshine reinstalled and running OK.

:: ===================================================================
:: STEP 2: Reinstall Moonlight — only runs if Step 1 succeeded
:: ===================================================================
echo.
echo [*] Step 2: Reinstalling Moonlight Web...
set "MOONLIGHT_ZIP=%SCRIPT_DIR%\moonlight-theme.zip"

sc query %MOONLIGHT_SERVICE% >nul 2>&1 && (
    net stop %MOONLIGHT_SERVICE% >nul 2>&1
    "%NSSM_EXE%" remove %MOONLIGHT_SERVICE% confirm >nul 2>&1
    timeout /t 2 /nobreak >nul
)

if exist "%MOONLIGHT_DIR%" (rd /s /q "%MOONLIGHT_DIR%" & timeout /t 1 /nobreak >nul)
if exist "%MOONLIGHT_ZIP%" del "%MOONLIGHT_ZIP%" >nul

echo [*] Downloading Moonlight Web...
curl -L "https://github.com/bluefml1/nextGPU-moonlight/releases/latest/download/moonlight-theme.zip" -o "%MOONLIGHT_ZIP%" --progress-bar
if !errorlevel! neq 0 (
    powershell -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://github.com/bluefml1/nextGPU-moonlight/releases/latest/download/moonlight-theme.zip' -OutFile '%MOONLIGHT_ZIP%' -UseBasicParsing"
    if !errorlevel! neq 0 (
        echo [ERROR] Failed to download Moonlight.
        goto repair_failed
    )
)

mkdir "%MOONLIGHT_DIR%" 2>nul
powershell -NoLogo -Command "Expand-Archive -Path '%MOONLIGHT_ZIP%' -DestinationPath '%MOONLIGHT_DIR%' -Force"
if not exist "%MOONLIGHT_DIR%\web-server.exe" (
    echo [ERROR] web-server.exe missing after extract.
    goto repair_failed
)
del "%MOONLIGHT_ZIP%" >nul

mkdir "%MOONLIGHT_DIR%\server" 2>nul
if exist "%MOONLIGHT_DIR%\server\config.json" del "%MOONLIGHT_DIR%\server\config.json"
curl -L "https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json" -o "%MOONLIGHT_DIR%\server\config.json"
if !errorlevel! neq 0 (
    powershell -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json' -OutFile '%MOONLIGHT_DIR%\server\config.json' -UseBasicParsing}catch{}"
)
set "CONFIG_PATH=%MOONLIGHT_DIR%\server\config.json"
set "COMPUTER_NAME_LOWER="
for /f "delims=" %%A in ('powershell -NoLogo -NoProfile -Command "$n='!COMPUTER_NAME!'; if([string]::IsNullOrWhiteSpace($n)){''} else {$n.Trim().ToLowerInvariant()}"') do set "COMPUTER_NAME_LOWER=%%A"
if defined COMPUTER_NAME_LOWER if exist "%CONFIG_PATH%" (
    powershell -NoLogo -NoProfile -Command "$cfg='%CONFIG_PATH%';$name='!COMPUTER_NAME_LOWER!';try{$c=Get-Content -Raw $cfg;$c=$c -replace '\{\{computer_name\}\}',$name;$enc=New-Object System.Text.UTF8Encoding $false;[System.IO.File]::WriteAllText($cfg,$c,$enc)}catch{}"
)

"%NSSM_EXE%" install %MOONLIGHT_SERVICE% "%MOONLIGHT_DIR%\web-server.exe"
if errorlevel 1 (
    echo [ERROR] Failed to install Moonlight service.
    goto repair_failed
)
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppDirectory "%MOONLIGHT_DIR%" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% Start SERVICE_AUTO_START >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppStdout "%LOG_DIR%\moonlight-web.log" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppStderr "%LOG_DIR%\moonlight-web-error.log" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% DisplayName "Moonlight Web Stream" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% Description "Moonlight Web streaming server for remote GPU access" >nul
net start %MOONLIGHT_SERVICE% >nul

:: Verify Moonlight service is running
timeout /t 3 /nobreak >nul
sc query %MOONLIGHT_SERVICE% | find "RUNNING" >nul
if errorlevel 1 (
    echo [ERROR] Moonlight service failed to start after install.
    goto repair_failed
)

:: Verify HTTP is responding
for /f %%S in ('curl -o nul -s -w "%%{http_code}" --max-time 10 http://127.0.0.1:8080') do set "HTTP_STATUS=%%S"
if not "!HTTP_STATUS!"=="200" (
    echo [ERROR] Moonlight HTTP not responding after install. Status: !HTTP_STATUS!
    goto repair_failed
)
echo [*] Moonlight reinstalled and responding OK.

:: ===================================================================
:: STEP 3: Re-pair — only runs if Step 1 and Step 2 succeeded
:: ===================================================================
echo.
echo [*] Step 3: Re-pairing Moonlight with Sunshine...
set "MOONLIGHT_DATA=%MOONLIGHT_DIR%\server\data.json"
set "MAX_RETRIES=10"
set /a RETRY_COUNT=0
set "COOKIES=%TEMP%\moonlight_cookies.txt"
set "HOST_NAME=%COMPUTERNAME%"
set "HOST_ID=0"

net stop %MOONLIGHT_SERVICE% >nul 2>&1
:wait_stop
sc query %MOONLIGHT_SERVICE% | find "STOPPED" >nul
if errorlevel 1 (timeout /t 1 /nobreak >nul & goto :wait_stop)

if exist "%MOONLIGHT_DATA%" del "%MOONLIGHT_DATA%"
curl -L "https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json" -o "%MOONLIGHT_DATA%"
if !errorlevel! neq 0 (
    powershell -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json' -OutFile '%MOONLIGHT_DATA%' -UseBasicParsing}catch{}"
)

net start %MOONLIGHT_SERVICE% >nul 2>&1
:wait_start
sc query %MOONLIGHT_SERVICE% | find "RUNNING" >nul
if errorlevel 1 (timeout /t 1 /nobreak >nul & goto :wait_start)

:: Login
curl.exe -c "%COOKIES%" -X POST "http://127.0.0.1:8080/api/login" -H "Content-Type: application/json" -d "{\"name\":\"test\",\"password\":\"test123\"}" -o "%TEMP%\moonlight_login.json" -s
if !errorlevel! neq 0 (echo [!] Login failed. Skipping pairing. & goto :pairing_done)

echo [*] Using pre-configured host: ID=!HOST_ID! Name=!HOST_NAME!
timeout /t 2 /nobreak >nul

:pin_attempt
taskkill /f /im curl.exe >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1

start /b cmd /c "curl.exe -N -b "%COOKIES%" -X POST "http://127.0.0.1:8080/api/pair" -H "Content-Type: application/json" -d "{\"host_id\":!HOST_ID!}" -o "%TEMP%\moonlight_pin_response.json" -s"

set "PAIRING_PIN="
for /L %%i in (1,1,15) do (
    timeout /t 1 /nobreak >nul
    if exist "%TEMP%\moonlight_pin_response.json" (
        set "_pinfile=%TEMP%\moonlight_pin_response.json"
        for /f "delims=" %%P in ('powershell -NoLogo -NoProfile -Command "try{ $raw=Get-Content -Raw $env:_pinfile; ($raw|ConvertFrom-Json).Pin }catch{ '' }"') do set "PAIRING_PIN=%%P"
        if defined PAIRING_PIN if not "!PAIRING_PIN!"=="" goto :pin_found
    )
)

:pin_found
if not defined PAIRING_PIN (goto :pairing_failed)

curl.exe -u bluefml1:letmeinpls -H "Content-Type: application/json" -X POST -k "https://localhost:47990/api/pin" -d "{\"pin\":\"!PAIRING_PIN!\",\"name\":\"!HOST_NAME!\"}" -o "%TEMP%\moonlight_pair_complete.json" -s --max-time 30

set "SUNSHINE_STATUS="
for /f "delims=" %%S in ('powershell -NoLogo -NoProfile -Command "$f='%TEMP%\moonlight_pair_complete.json'; try{ $j=Get-Content -Raw $f | ConvertFrom-Json; Write-Output $j.status }catch{ Write-Output '' }"') do set "SUNSHINE_STATUS=%%S"

if /i "!SUNSHINE_STATUS!"=="True" (
    timeout /t 3 /nobreak >nul
    set "PAIR_RESULT="
    for /f "delims=" %%R in ('powershell -NoLogo -NoProfile -Command "$f='%TEMP%\moonlight_pin_response.json'; try{ $raw=Get-Content -Raw $f; if($raw -match 'Paired'){'Paired'}else{'PairError'} }catch{'PairError'}"') do set "PAIR_RESULT=%%R"
    if "!PAIR_RESULT!"=="Paired" (echo [*] Pairing successful! & goto :pairing_done)
)

:pairing_failed
set /a RETRY_COUNT+=1
if !RETRY_COUNT! geq %MAX_RETRIES% (echo [!] Pairing failed after %MAX_RETRIES% attempts. & goto :pairing_done)
timeout /t 2 /nobreak >nul
goto :pin_attempt

:pairing_done
taskkill /f /im curl.exe >nul 2>&1
if exist "%TEMP%\moonlight_login.json" del "%TEMP%\moonlight_login.json" >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1
if exist "%TEMP%\moonlight_pair_complete.json" del "%TEMP%\moonlight_pair_complete.json" >nul 2>&1
if exist "%COOKIES%" del "%COOKIES%" >nul 2>&1
echo [*] Repair complete. Waiting 300s before next check...
if defined RUN_ONCE (echo [*] Single run complete. & exit /b 0)
timeout /t 300 /nobreak >nul
goto loop

:repair_failed
echo [!] Repair failed. Waiting 300s before retry...
taskkill /f /im curl.exe >nul 2>&1
if exist "%TEMP%\moonlight_login.json" del "%TEMP%\moonlight_login.json" >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1
if exist "%TEMP%\moonlight_pair_complete.json" del "%TEMP%\moonlight_pair_complete.json" >nul 2>&1
if exist "%COOKIES%" del "%COOKIES%" >nul 2>&1
if defined RUN_ONCE (exit /b 1)
timeout /t 300 /nobreak >nul
goto loop