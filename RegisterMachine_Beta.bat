@echo off
setlocal enabledelayedexpansion

:: =====================================================================
:: GPU Rental Machine Setup Script
:: =====================================================================

:: =============== RESOLVE SCRIPT DIRECTORY ===============
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
:: =========================================================

:: Auto-elevate to Admin (visible console so install progress can be tracked)
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    set "RM_ELEVATE_BAT=%~f0"
    set "RM_ELEVATE_DIR=%SCRIPT_DIR%"
    powershell -NoProfile -Command "Start-Process cmd.exe -Verb RunAs -WindowStyle Normal -ArgumentList ('/k','cd /d \"\"' + $env:RM_ELEVATE_DIR + '\"\" && call \"\"' + $env:RM_ELEVATE_BAT + '\"\" __elevated__')"
    exit /b
)
if /i "%~1"=="__elevated__" shift /1

echo [INFO] Running with Administrator privileges.
echo [INFO] Script directory: %SCRIPT_DIR%
echo.

:: =============== USER INPUT SECTION ===============
echo ========================================
echo Required Configuration
echo ========================================
echo.

:input_cf_token
set /p "CF_API_TOKEN=Enter Cloudflare API Token: "
if "%CF_API_TOKEN%"=="" (echo ERROR: API Token cannot be empty! & goto input_cf_token)

:input_account_id
set /p "ACCOUNT_ID=Enter Cloudflare Account ID: "
if "%ACCOUNT_ID%"=="" (echo ERROR: Account ID cannot be empty! & goto input_account_id)


:input_api_key
set /p "API_KEY=Enter API Key: "
if "%API_KEY%"=="" (echo ERROR: API Key cannot be empty! & goto input_api_key)

:input_computer_name
set /p "COMPUTER_NAME_CUSTOM=Enter Computer Name (e.g., GPU-RENTAL-01): "
if "%COMPUTER_NAME_CUSTOM%"=="" (echo ERROR: Computer Name cannot be empty! & goto input_computer_name)

:input_price
set /p "PRICE=Enter Original Price (e.g., 10.99): "
if "%PRICE%"=="" (echo ERROR: Price cannot be empty! & goto input_price)

:input_vendor_id
set "VENDOR_ID="
set /p "VENDOR_ID=Enter Vendor ID (optional, press Enter to skip): "
for /f "delims=" %%V in ('powershell -NoLogo -NoProfile -Command "$v='%VENDOR_ID%'; if([string]::IsNullOrWhiteSpace($v)){''} else {$v.Trim()}"') do set "VENDOR_ID=%%V"

:input_admin_account
set /p "ADMIN_ACCOUNT_NAME=Enter current admin account username to rename: "
if "%ADMIN_ACCOUNT_NAME%"=="" (echo ERROR: Admin account username cannot be empty! & goto input_admin_account)

echo.
echo Configuration Summary:
echo - API Token: %CF_API_TOKEN:~0,10%...
echo - Account ID: %ACCOUNT_ID%
echo - Price: $%PRICE%
if defined VENDOR_ID if not "!VENDOR_ID!"=="" (echo - Vendor ID: !VENDOR_ID!) else (echo - Vendor ID: ^(not set^))
echo - Admin account (username + full name): %ADMIN_ACCOUNT_NAME% -^> NextGPU-Authority
echo.
set /p "CONFIRM=Is this correct? (Y/N): "
if /i not "%CONFIRM%"=="Y" (
    echo Please re-enter the configuration.
    echo.
    goto input_cf_token
)
set "COMPUTER_NAME_LOWER="
for /f "delims=" %%A in ('powershell -NoLogo -NoProfile -Command "$n='%COMPUTER_NAME_CUSTOM%'; if([string]::IsNullOrWhiteSpace($n)){''} else {$n.Trim().ToLowerInvariant()}"') do set "COMPUTER_NAME_LOWER=%%A"
if not defined COMPUTER_NAME_LOWER (
    echo ERROR: Failed to normalize Computer Name.
    pause
    exit /b 1
)
:: ===================================================================
:: WMI / WMIC probe (install WMIC only when image supports it; CIM fallback)
:: ===================================================================
echo [*] Checking WMI / WMIC support...
set "WMI_PROBE_SCRIPT=%SCRIPT_DIR%\Ensure-WmiSupport.ps1"
set "WMI_PROBE_LOG=%SCRIPT_DIR%\wmi-probe.log"
if not exist "%WMI_PROBE_SCRIPT%" (
    echo [!] WARNING: Ensure-WmiSupport.ps1 not found — quick CIM check only.
    powershell -NoLogo -NoProfile -Command "try{Get-CimInstance Win32_OperatingSystem|Out-Null;exit 0}catch{exit 1}"
    if !errorlevel! neq 0 (
        echo ERROR: WMI/CIM not available on this machine.
        pause
        exit /b 1
    )
    echo [*] CIM available. Continuing without WMIC.
) else (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%WMI_PROBE_SCRIPT%" -LogPath "%WMI_PROBE_LOG%"
    if !errorlevel! neq 0 (
        echo.
        echo ERROR: WMI inventory not available. See %WMI_PROBE_LOG%
        pause
        exit /b 1
    )
)
where wmic >nul 2>&1
if !errorlevel! equ 0 (
    wmic os get caption >nul 2>&1
    if !errorlevel! equ 0 (
        echo [*] WMIC CLI available.
    ) else (
        echo [*] WMIC present but CLI failed — using PowerShell CIM for inventory.
    )
) else (
    echo [*] WMIC not used — using PowerShell CIM for inventory.
)
echo.
:: =============== STATIC CONFIG ===============
set "LOCAL_SERVICE=http://127.0.0.1:8080"
set "ROOT_DOMAIN=next-gpu.com"
:: ===============================================

:: ===================================================================
:: [1] VDD + VAD
:: ===================================================================
echo [1] Installing Virtual Display Driver and Virtual Audio Driver...
set "VDD_PS1=%SCRIPT_DIR%\silent-install-vdd-vad.ps1"
set "VDD_LOG=%SCRIPT_DIR%\VDD-VAD.log"
set "VDD_INSTALL_DIR=%SCRIPT_DIR%\VDD-VAD-Install"
if not exist "%VDD_PS1%" (
    echo [!] WARNING: silent-install-vdd-vad.ps1 not found, skipping VDD+VAD.
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%VDD_PS1%" -LogPath "%VDD_LOG%" -InstallDir "%VDD_INSTALL_DIR%"
    if !errorlevel! neq 0 (
        echo [!] WARNING: VDD+VAD install returned exit code !errorlevel!. See VDD-VAD.log
    ) else (
        echo [*] VDD+VAD ready.
    )
    echo [*] Driver files: %VDD_INSTALL_DIR%
)
echo [*] Waiting for virtual display to enumerate...
timeout /t 10 /nobreak >nul
echo.

echo.
echo Starting installation process...
echo.

:: ===================================================================
:: [1/8] SUNSHINE
:: ===================================================================
echo [1/8] Installing Sunshine...
set "SUNSHINE_ZIP=%SCRIPT_DIR%\sunshine.zip"
set "SUNSHINE_DIR=%SCRIPT_DIR%\sunshine"

if exist "C:\Program Files\Sunshine\sunshine.exe" (
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

echo [*] Downloading Sunshine...
curl -L "https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip" -o "%SUNSHINE_ZIP%" --progress-bar
if !errorlevel! neq 0 (
    powershell -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip' -OutFile '%SUNSHINE_ZIP%' -UseBasicParsing"
    if !errorlevel! neq 0 (echo ERROR: Failed to download Sunshine. & pause & exit /b 1)
)

mkdir "%SUNSHINE_DIR%" 2>nul
powershell -NoLogo -Command "Expand-Archive -Path '%SUNSHINE_ZIP%' -DestinationPath '%SUNSHINE_DIR%' -Force"
if !errorlevel! neq 0 (echo ERROR: Failed to extract Sunshine. & pause & exit /b 1)
if not exist "%SUNSHINE_DIR%\Sunshine.exe" (echo ERROR: Sunshine.exe missing. & pause & exit /b 1)

del "%SUNSHINE_ZIP%" >nul
echo [*] Installing Sunshine...
"%SUNSHINE_DIR%\Sunshine.exe" /S
timeout /t 5 /nobreak >nul

"C:\Program Files\Sunshine\sunshine.exe" --creds bluefml1 letmeinpls
taskkill /f /im sunshine.exe >nul 2>&1
timeout /t 2 /nobreak >nul
start "" "C:\Program Files\Sunshine\sunshine.exe"

set "PS_ADDAPP=%SCRIPT_DIR%\sunshine\Add-SteamGames.ps1"
if not exist "%PS_ADDAPP%" (
    echo Warning: Add-SteamGames.ps1 not found at "%PS_ADDAPP%", skipping.
) else (
    echo Running Steam game importer...
    powershell -ExecutionPolicy Bypass -NoProfile -File "%PS_ADDAPP%"
)

call :setup_sunshine_device_id

:: ===================================================================
:: [2/8] NSSM
:: ===================================================================
echo [2/8] Setting up NSSM...
set "NSSM_ZIP=%SCRIPT_DIR%\nssm-2.24.zip"
set "NSSM_EXTRACT_DIR=%SCRIPT_DIR%\nssm"
set "NSSM_EXE=%SCRIPT_DIR%\nssm\nssm-2.24\win64\nssm.exe"

if exist "%NSSM_EXE%" (
    echo [*] NSSM already present, skipping download.
    goto nssm_ready
)

if exist "%NSSM_ZIP%" del "%NSSM_ZIP%"

set "MAX_DOWNLOAD_ATTEMPTS=10"
set "DOWNLOAD_ATTEMPT=0"

:download_nssm_loop
set /a DOWNLOAD_ATTEMPT+=1
if %DOWNLOAD_ATTEMPT% gtr %MAX_DOWNLOAD_ATTEMPTS% (echo ERROR: Failed to download NSSM. & pause & exit /b 1)

echo [*] Downloading NSSM... (Attempt %DOWNLOAD_ATTEMPT%)
if exist "%NSSM_ZIP%" del "%NSSM_ZIP%" >nul 2>&1

set /a "METHOD=%DOWNLOAD_ATTEMPT% %% 3"
if %METHOD%==1 (
    curl -L "https://github.com/Nguyenanvu202/NssmService/raw/refs/heads/main/nssm-2.24.zip" -o "%NSSM_ZIP%" --progress-bar
) else if %METHOD%==2 (
    curl -L "https://github.com/Nguyenanvu202/NssmService/raw/refs/heads/main/nssm-2.24.zip" -o "%NSSM_ZIP%" --progress-bar --retry 3
) else (
    powershell -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/NssmService/raw/refs/heads/main/nssm-2.24.zip' -OutFile '%NSSM_ZIP%' -UseBasicParsing"
)

if not exist "%NSSM_ZIP%" (timeout /t 2 /nobreak >nul & goto :download_nssm_loop)

powershell -Command "try{Add-Type -AssemblyName System.IO.Compression.FileSystem;$z=[System.IO.Compression.ZipFile]::OpenRead('%NSSM_ZIP%');$z.Dispose()}catch{exit 1}"
if !errorlevel! neq 0 (timeout /t 2 /nobreak >nul & goto :download_nssm_loop)

mkdir "%NSSM_EXTRACT_DIR%" 2>nul
powershell -NoLogo -Command "Expand-Archive -Path '%NSSM_ZIP%' -DestinationPath '%NSSM_EXTRACT_DIR%' -Force"
if !errorlevel! neq 0 (echo ERROR: Failed to extract NSSM. & pause & exit /b 1)
if not exist "%NSSM_EXE%" (echo ERROR: nssm.exe not found after extraction. & pause & exit /b 1)
del "%NSSM_ZIP%" >nul

:nssm_ready
echo [*] NSSM ready: %NSSM_EXE%

:: ===================================================================
:: [3/8] MOONLIGHT
:: ===================================================================
echo [3/8] Setting up Moonlight Web...
set "MOONLIGHT_ZIP=%SCRIPT_DIR%\moonlight-theme.zip"
set "MOONLIGHT_DIR=%SCRIPT_DIR%\moonlight-web"
set "MOONLIGHT_SERVICE=moonlight-web"

sc query %MOONLIGHT_SERVICE% >nul 2>&1 && (
    net stop %MOONLIGHT_SERVICE% >nul 2>&1
    "%NSSM_EXE%" remove %MOONLIGHT_SERVICE% confirm >nul 2>&1
    timeout /t 2 /nobreak >nul
)

if exist "%MOONLIGHT_DIR%" (rd /s /q "%MOONLIGHT_DIR%" & timeout /t 1 /nobreak >nul)
if exist "%MOONLIGHT_ZIP%" del "%MOONLIGHT_ZIP%"

echo [*] Downloading Moonlight Web...
curl -L "https://github.com/bluefml1/nextGPU-moonlight/releases/latest/download/moonlight-theme.zip" -o "%MOONLIGHT_ZIP%" --progress-bar
if !errorlevel! neq 0 (
    powershell -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://github.com/bluefml1/nextGPU-moonlight/releases/latest/download/moonlight-theme.zip' -OutFile '%MOONLIGHT_ZIP%' -UseBasicParsing"
    if !errorlevel! neq 0 (echo ERROR: Failed to download Moonlight. & pause & exit /b 1)
)

mkdir "%MOONLIGHT_DIR%" 2>nul
powershell -NoLogo -Command "Expand-Archive -Path '%MOONLIGHT_ZIP%' -DestinationPath '%MOONLIGHT_DIR%' -Force"
if !errorlevel! neq 0 (echo ERROR: Failed to extract Moonlight. & pause & exit /b 1)
if not exist "%MOONLIGHT_DIR%\web-server.exe" (echo ERROR: web-server.exe missing. & pause & exit /b 1)
del "%MOONLIGHT_ZIP%" >nul

mkdir "%MOONLIGHT_DIR%\server" 2>nul
if exist "%MOONLIGHT_DIR%\server\config.json" del "%MOONLIGHT_DIR%\server\config.json"
echo [*] Downloading config.json...
curl -L "https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json" -o "%MOONLIGHT_DIR%\server\config.json"
if !errorlevel! neq 0 (
    powershell -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json' -OutFile '%MOONLIGHT_DIR%\server\config.json' -UseBasicParsing}catch{}"
)
set "CONFIG_PATH=%MOONLIGHT_DIR%\server\config.json"
if exist "%CONFIG_PATH%" (
    powershell -NoLogo -NoProfile -Command "$cfg='%CONFIG_PATH%';$name='%COMPUTER_NAME_LOWER%';try{$c=Get-Content -Raw $cfg;$c=$c -replace '\{\{computer_name\}\}',$name;$enc=New-Object System.Text.UTF8Encoding $false;[System.IO.File]::WriteAllText($cfg,$c,$enc)}catch{}"
)

"%NSSM_EXE%" install %MOONLIGHT_SERVICE% "%MOONLIGHT_DIR%\web-server.exe" || (echo ERROR: Failed to install Moonlight service. & pause & exit /b 1)
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppDirectory "%MOONLIGHT_DIR%" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% Start SERVICE_AUTO_START >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppStdout "%MOONLIGHT_DIR%\moonlight-web.log" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% AppStderr "%MOONLIGHT_DIR%\moonlight-web-error.log" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% DisplayName "Moonlight Web Stream" >nul
"%NSSM_EXE%" set %MOONLIGHT_SERVICE% Description "Moonlight Web streaming server for remote GPU access" >nul
net start %MOONLIGHT_SERVICE% >nul

:: ===================================================================
:: [4/8] PAIRING
:: ===================================================================
echo [4/8] Pairing Moonlight with Sunshine...
set "MAX_RETRIES=100"
set "MOONLIGHT_DATA=%MOONLIGHT_DIR%\server\data.json"
set /a RETRY_COUNT=0
set "COOKIES=%TEMP%\moonlight_cookies.txt"
set "HOST_NAME=%COMPUTERNAME%"

:: Stop service & download fresh data.json
net stop %MOONLIGHT_SERVICE% >nul 2>&1
:wait_stop
sc query %MOONLIGHT_SERVICE% | find "STOPPED" >nul
if errorlevel 1 (timeout /t 1 /nobreak >nul & goto :wait_stop)

if exist "%MOONLIGHT_DATA%" del "%MOONLIGHT_DATA%"
curl -L "https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json" -o "%MOONLIGHT_DATA%"
if !errorlevel! neq 0 (
    powershell -Command "try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$ProgressPreference='SilentlyContinue';Invoke-WebRequest -Uri 'https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json' -OutFile '%MOONLIGHT_DATA%' -UseBasicParsing}catch{}"
)

:: Start service
net start %MOONLIGHT_SERVICE% >nul 2>&1
:wait_start
sc query %MOONLIGHT_SERVICE% | find "RUNNING" >nul
if errorlevel 1 (timeout /t 1 /nobreak >nul & goto :wait_start)

:: Login
curl.exe -c "%COOKIES%" -X POST "http://127.0.0.1:8080/api/login" -H "Content-Type: application/json" -d "{\"name\":\"test\",\"password\":\"test123\"}" -o "%TEMP%\moonlight_login.json" -s
if !errorlevel! neq 0 (echo [!] Login failed. Skipping pairing. & goto :pairing_done)

set "HOST_ID=0"
echo [*] Using pre-configured host: ID=!HOST_ID! Name=!HOST_NAME!
timeout /t 2 /nobreak >nul

:: Pairing loop — PIN request runs in separate cmd /c subprocess (long-poll)
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

curl.exe -u bluefml1:letmeinpls -H "Content-Type: application/json" -X POST -k "https://localhost:47990/api/pin" -d "{\"pin\":\"!PAIRING_PIN!\",\"name\":\"%HOST_NAME%\"}" -o "%TEMP%\moonlight_pair_complete.json" -s --max-time 30

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

:: ===================================================================
:: ViGEmBus
:: ===================================================================
echo [*] Installing ViGEmBus...
set "VIGEM_BAT=%SCRIPT_DIR%\ViGEmBus.bat"
if not exist "%VIGEM_BAT%" (
    echo [!] WARNING: ViGEmBus.bat not found, skipping.
) else (
    call "%VIGEM_BAT%" inline
    if !errorlevel! neq 0 (
        echo [!] WARNING: ViGEmBus install returned exit code !errorlevel!. See ViGEmBus.log
    ) else (
        echo [*] ViGEmBus ready.
    )
)
echo.

:: ===================================================================
:: [5/8] CLOUDFLARED
:: ===================================================================
echo [5/8] Setting up Cloudflared...
set "CLOUDFLARED_EXE=%SCRIPT_DIR%\cloudflared.exe"

if not exist "%CLOUDFLARED_EXE%" (
    echo [*] Downloading cloudflared...
    curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" -o "%CLOUDFLARED_EXE%" --progress-bar
    if !errorlevel! neq 0 (
        powershell -Command "$ProgressPreference='SilentlyContinue';[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -Uri 'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe' -OutFile '%CLOUDFLARED_EXE%' -UseBasicParsing"
        if !errorlevel! neq 0 (echo ERROR: Failed to download cloudflared. & pause & exit /b 1)
    )
) else (
    echo [*] Cloudflared already exists, skipping download.
)

echo [*] Verifying Cloudflare token...
curl -H "Authorization: Bearer %CF_API_TOKEN%" "https://api.cloudflare.com/client/v4/accounts/%ACCOUNT_ID%/tokens/verify"

for /f "delims=" %%i in ('curl -s -H "Authorization: Bearer %CF_API_TOKEN%" "https://api.cloudflare.com/client/v4/zones?name=%ROOT_DOMAIN%" ^| powershell -Command "($input|ConvertFrom-Json).result[0].id"') do set "ZONE_ID=%%i"

:: ===================================================================
:: [6/8] IPs & DNS ID
:: ===================================================================
echo [6/8] Detecting IPs...
set "PUBLIC_IP="
for /f "delims=" %%i in ('powershell -Command "try{(irm -Uri 'https://api.ipify.org' -UseBasicParsing -TimeoutSec 5).Trim()}catch{'Failed'}"') do set "PUBLIC_IP=%%i"
if "!PUBLIC_IP!"=="" set "PUBLIC_IP=Failed"
if "!PUBLIC_IP!"=="Failed" (set "PUBLIC_IP=127.0.0.1") else (echo Public IP: !PUBLIC_IP!)

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "192.168.1."') do (
    for /f "tokens=* delims= " %%b in ("%%a") do (set "PRIVATE_IP=%%b" & goto :private_ip_found)
)
:private_ip_found
if not defined PRIVATE_IP set "PRIVATE_IP=127.0.0.1"
echo Private IP: %PRIVATE_IP%

set "NAME=%COMPUTER_NAME_CUSTOM%"

for /f "delims=" %%h in ('powershell -NoLogo -Command "$input='%PUBLIC_IP%,%NAME%';$bytes=[System.Text.Encoding]::UTF8.GetBytes($input);$hash=(New-Object Security.Cryptography.SHA256Managed).ComputeHash($bytes);$alpha='abcdefghijklmnopqrstuvwxyz0123456789';$id='';for($i=0;$i-lt8;$i++){$id+=$alpha[[int]$hash[$i]%%$alpha.Length]};$id.ToUpper()"') do set "DNS_ID=%%h"

set "DOMAIN=%DNS_ID%.%ROOT_DOMAIN%"
set "TUNNEL_NAME=%DNS_ID%-tunnel"

:: ===================================================================
:: [7/8] TUNNEL & DNS
:: ===================================================================
echo [7/8] Creating Cloudflare Tunnel...

:check_tunnel_exists
curl -s -H "Authorization: Bearer %CF_API_TOKEN%" "https://api.cloudflare.com/client/v4/accounts/%ACCOUNT_ID%/cfd_tunnel?name=%TUNNEL_NAME%" -o "%TEMP%\tunnel_check.json"
for /f "delims=" %%A in ('powershell -NoLogo -Command "try{$json=Get-Content -Raw '%TEMP%\tunnel_check.json'|ConvertFrom-Json;if($json.result.Count -gt 0){'EXISTS'}else{'NOTFOUND'}}catch{'ERROR'}"') do set "TUNNEL_CHECK=%%A"

if "%TUNNEL_CHECK%"=="EXISTS" (
    for /f "delims=" %%R in ('powershell -NoLogo -Command "$c='abcdefghijklmnopqrstuvwxyz0123456789';$r='';1..4|%%{$r+=$c[(Get-Random -Maximum $c.Length)]};$r"') do set "RANDOM_SUFFIX=%%R"
    set "DNS_ID=%DNS_ID%!RANDOM_SUFFIX!"
    set "DOMAIN=%DNS_ID%.%ROOT_DOMAIN%"
    set "TUNNEL_NAME=%DNS_ID%-tunnel"
    goto :check_tunnel_exists
)
del "%TEMP%\tunnel_check.json" >nul 2>&1

curl --request POST "https://api.cloudflare.com/client/v4/accounts/%ACCOUNT_ID%/cfd_tunnel" ^
     -H "Authorization: Bearer %CF_API_TOKEN%" -H "Content-Type: application/json" ^
     --data "{ \"name\": \"%TUNNEL_NAME%\", \"config_src\": \"cloudflare\" }" -o "%TEMP%\tunnel_response.json"

for /f "delims=" %%A in ('powershell -NoLogo -Command "(Get-Content -Raw '%TEMP%\tunnel_response.json'|ConvertFrom-Json).result.id"') do set "TUNNEL_ID=%%A"
for /f "delims=" %%A in ('powershell -NoLogo -Command "(Get-Content -Raw '%TEMP%\tunnel_response.json'|ConvertFrom-Json).result.token"') do set "TUNNEL_TOKEN=%%A"
echo Tunnel ID: %TUNNEL_ID%

curl -X PUT "https://api.cloudflare.com/client/v4/accounts/%ACCOUNT_ID%/cfd_tunnel/%TUNNEL_ID%/configurations" ^
    -H "Authorization: Bearer %CF_API_TOKEN%" -H "Content-Type: application/json" ^
    --data "{\"config\":{\"ingress\":[{\"hostname\":\"%DOMAIN%\",\"service\":\"%LOCAL_SERVICE%\",\"originRequest\":{}},{\"service\":\"http_status:404\"}]}}"

curl -s -X GET "https://api.cloudflare.com/client/v4/zones/%ZONE_ID%/dns_records?name=%DOMAIN%" ^
     -H "Authorization: Bearer %CF_API_TOKEN%" -H "Content-Type: application/json" -o "%TEMP%\existing_dns.json"
for /f "delims=" %%A in ('powershell -NoLogo -Command "try{$json=Get-Content -Raw '%TEMP%\existing_dns.json'|ConvertFrom-Json;if($json.result.Count -gt 0){$json.result[0].id}else{''}}catch{''}"') do set "EXISTING_DNS_ID=%%A"
if defined EXISTING_DNS_ID if not "%EXISTING_DNS_ID%"=="" (
    curl -s -X DELETE "https://api.cloudflare.com/client/v4/zones/%ZONE_ID%/dns_records/%EXISTING_DNS_ID%" -H "Authorization: Bearer %CF_API_TOKEN%" >nul
    timeout /t 2 /nobreak >nul
)

curl -s -X POST "https://api.cloudflare.com/client/v4/zones/%ZONE_ID%/dns_records" ^
    -H "Authorization: Bearer %CF_API_TOKEN%" -H "Content-Type: application/json" ^
    --data "{\"type\":\"CNAME\",\"name\":\"%DOMAIN%\",\"content\":\"%TUNNEL_ID%.cfargotunnel.com\",\"proxied\":true}" -o "%TEMP%\dns_create_response.json"
echo [*] DNS record created.

taskkill /f /im cloudflared.exe >nul 2>&1
timeout /t 2 /nobreak >nul
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\Cloudflared" /f >nul 2>&1
sc query cloudflared >nul 2>&1 && (
    net stop cloudflared >nul 2>&1
    "%CLOUDFLARED_EXE%" service uninstall >nul 2>&1
    sc delete cloudflared >nul 2>&1
    timeout /t 3 /nobreak >nul
)
if exist "%USERPROFILE%\.cloudflared" rd /s /q "%USERPROFILE%\.cloudflared" >nul 2>&1

setx CLOUDFLARE_TUNNEL_TOKEN "%TUNNEL_TOKEN%" /M >nul 2>&1
"%CLOUDFLARED_EXE%" service install "%TUNNEL_TOKEN%"
sc config cloudflared start= auto >nul 2>&1
net start cloudflared >nul 2>&1

echo.
echo ========================================
echo Tunnel: %TUNNEL_NAME%
echo Domain: https://%DOMAIN%
echo ========================================

:: ===================================================================
:: System Info (PowerShell CIM — works without wmic.exe)
:: ===================================================================
set "INVENTORY_SCRIPT=%SCRIPT_DIR%\Get-MachineInventory.ps1"
set "OS_NAME="
set "OS_VERSION="
set "CPU="
set "TotalPhysicalMemory=0"
set "GPU_NAME="
set "LAST_CHECKIN="
if not exist "%INVENTORY_SCRIPT%" (
    echo ERROR: Get-MachineInventory.ps1 not found at "%INVENTORY_SCRIPT%"
    pause
    exit /b 1
)
for /f "tokens=1,* delims==" %%a in ('powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%INVENTORY_SCRIPT%"') do (
    if /i "%%a"=="OS_NAME" set "OS_NAME=%%b"
    if /i "%%a"=="OS_VERSION" set "OS_VERSION=%%b"
    if /i "%%a"=="CPU" set "CPU=%%b"
    if /i "%%a"=="TotalPhysicalMemory" set "TotalPhysicalMemory=%%b"
    if /i "%%a"=="GPU_NAME" set "GPU_NAME=%%b"
    if /i "%%a"=="LAST_CHECKIN" set "LAST_CHECKIN=%%b"
)
if not defined OS_NAME (
    echo ERROR: Failed to collect system inventory via CIM.
    pause
    exit /b 1
)

set "BENCH_MARK_CPU=0"
set "BENCH_MARK_GPU=0"
set "BENCHMARK_SCRIPT=%SCRIPT_DIR%\Get-BenchmarkScores-Silent.ps1"
if exist "%BENCHMARK_SCRIPT%" (
    for /f "tokens=1,2 delims=|" %%a in ('powershell -ExecutionPolicy Bypass -NoProfile -File "%BENCHMARK_SCRIPT%"') do (
        set "BENCH_MARK_CPU=%%a"
        set "BENCH_MARK_GPU=%%b"
    )
)

if not defined LAST_CHECKIN (
    for /f "delims=" %%t in ('powershell -NoLogo -NoProfile -Command "Get-Date -Format \"yyyy-MM-dd HH:mm\""') do set "LAST_CHECKIN=%%t"
)

set "STATUS=online"
set "NOTES=ready to use"
set "LOG_FILE=%SCRIPT_DIR%\setup_log_%DATE:~-4%%DATE:~4,2%%DATE:~7,2%.txt"
set "LOG_FILE=%LOG_FILE: =0%"
echo Script started at %DATE% %TIME% > "%LOG_FILE%"

:: ===================================================================
:: Fetch game list
:: ===================================================================
set "TEMP_GAMES_FILE=%TEMP%\moonlight_games.json"
set "GAMES_OUTPUT_FILE=%TEMP%\games_json_output.txt"
set "PS_SCRIPT=%TEMP%\parse_games.ps1"

if not defined HOST_ID goto :build_payload

curl -s "http://localhost:8080/api/apps?host_id=!HOST_ID!&force_refresh=false" -o "%TEMP_GAMES_FILE%"

if exist "%TEMP_GAMES_FILE%" (
    for %%A in ("%TEMP_GAMES_FILE%") do set "FILE_SIZE=%%~zA"
    if !FILE_SIZE! GTR 0 (
        > "%PS_SCRIPT%" (
            echo $ErrorActionPreference = 'Stop'
            echo try {
            echo     $json = Get-Content -Raw '%TEMP_GAMES_FILE%' ^| ConvertFrom-Json
            echo     if ^($json.apps^) {
            echo         $gamesList = @^(^)
            echo         foreach ^($app in $json.apps^) {
            echo             $title = $app.title.Trim^(^)
            echo             $appId = $app.app_id
            echo             $url = "https://%DOMAIN%/stream.html?hostId=!HOST_ID!&appId=$appId"
            echo             $gamesList += '\"' + $title + '\":\"' + $url + '\"'
            echo         }
            echo         $gamesList -join "," ^| Out-File -FilePath '%GAMES_OUTPUT_FILE%' -Encoding ASCII -NoNewline
            echo     }
            echo } catch { exit 1 }
        )
        powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%PS_SCRIPT%" >nul 2>&1
        del "%PS_SCRIPT%" >nul 2>&1
    )
    del "%TEMP_GAMES_FILE%" >nul 2>&1
)

:build_payload
set "GAMES_JSON="
if exist "%GAMES_OUTPUT_FILE%" (
    for /f "usebackq delims=" %%A in ("%GAMES_OUTPUT_FILE%") do set "GAMES_JSON=!GAMES_JSON!%%A"
    del "%GAMES_OUTPUT_FILE%" >nul 2>&1
)

set "VENDOR_FIELD="
if defined VENDOR_ID if not "!VENDOR_ID!"=="" set "VENDOR_FIELD=,\"vendor_id\":\"!VENDOR_ID!\""

if defined GAMES_JSON (
    set PAYLOAD={\"computer_name\":\"%NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"%STATUS%\",\"domain\":\"%DOMAIN%\",\"Operation_system\":\"%OS_NAME%\",\"Processor\":\"%CPU%\",\"RAM\":\"%TotalPhysicalMemory% GB\",\"GPU_name\":\"%GPU_NAME%\",\"bench_mark_cpu\":\"%BENCH_MARK_CPU%\",\"bench_mark_gpu\":\"%BENCH_MARK_GPU%\",\"original_price\":\"%PRICE%\"!VENDOR_FIELD!,\"last_checkin\":\"%LAST_CHECKIN%\",\"notes\":\"%NOTES%\",!GAMES_JSON!}
) else (
    set PAYLOAD={\"computer_name\":\"%NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"%STATUS%\",\"domain\":\"%DOMAIN%\",\"Operation_system\":\"%OS_NAME%\",\"Processor\":\"%CPU%\",\"RAM\":\"%TotalPhysicalMemory% GB\",\"GPU_name\":\"%GPU_NAME%\",\"bench_mark_cpu\":\"%BENCH_MARK_CPU%\",\"bench_mark_gpu\":\"%BENCH_MARK_GPU%\",\"original_price\":\"%PRICE%\"!VENDOR_FIELD!,\"last_checkin\":\"%LAST_CHECKIN%\",\"notes\":\"%NOTES%\"}
)

echo.
echo Registering machine...
set "REGISTER_LOG=%SCRIPT_DIR%\register_api_log.txt"
echo ======================================== > "%REGISTER_LOG%"
echo Timestamp: %DATE% %TIME% >> "%REGISTER_LOG%"
echo ======================================== >> "%REGISTER_LOG%"
echo PAYLOAD: >> "%REGISTER_LOG%"
echo !PAYLOAD! >> "%REGISTER_LOG%"
echo. >> "%REGISTER_LOG%"
echo RESPONSE: >> "%REGISTER_LOG%"
curl -X POST https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/registerMachine -H "x-api-key: %API_KEY%" -H "Content-Type: application/json" -d "!PAYLOAD!" -o "%TEMP%\register_response.json" -s
type "%TEMP%\register_response.json" >> "%REGISTER_LOG%"
echo. >> "%REGISTER_LOG%"
echo ======================================== >> "%REGISTER_LOG%"
del "%TEMP%\register_response.json" >nul 2>&1
echo [*] API log saved to: %REGISTER_LOG%

:: Save domain info
> "%SCRIPT_DIR%\domain.txt" echo DOMAIN=%DOMAIN%
>> "%SCRIPT_DIR%\domain.txt" echo PUBLIC_IP=%PUBLIC_IP%
>> "%SCRIPT_DIR%\domain.txt" echo COMPUTER_NAME=%NAME%
echo [*] domain.txt saved.

:: ===================================================================
:: [7/8] Heartbeat Service
:: ===================================================================
echo [7/8] Setting up heartbeat service...
set "HEARTBEAT_SCRIPT=%SCRIPT_DIR%\heartbeat-only.bat"
set "HEARTBEAT_SERVICE=gpu-heartbeat"

if not exist "%HEARTBEAT_SCRIPT%" (echo ERROR: heartbeat-only.bat not found. & exit /b 1)

sc query %HEARTBEAT_SERVICE% >nul 2>&1 && (
    net stop %HEARTBEAT_SERVICE% >nul 2>&1
    "%NSSM_EXE%" remove %HEARTBEAT_SERVICE% confirm >nul 2>&1
)

"%NSSM_EXE%" install %HEARTBEAT_SERVICE% "cmd.exe" || (echo ERROR: Failed to install heartbeat. & exit /b 1)
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% AppParameters "/c \"%HEARTBEAT_SCRIPT%\"" >nul
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% AppDirectory "%SCRIPT_DIR%" >nul
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% Start SERVICE_AUTO_START >nul
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% AppStdout "%SCRIPT_DIR%\heartbeat.log" >nul
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% AppStderr "%SCRIPT_DIR%\heartbeat-error.log" >nul
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% DisplayName "GPU Heartbeat" >nul
"%NSSM_EXE%" set %HEARTBEAT_SERVICE% Description "Periodic status reporter for GPU rental machine" >nul
net start %HEARTBEAT_SERVICE% >nul && echo [*] Heartbeat running. || echo [!] Heartbeat will start on next boot.

:: ===================================================================
:: [8/8] Auto-Update Service
:: ===================================================================
:: ===================================================================
:: [8/8] Auto-Repair Service
:: ===================================================================
echo [/8] Setting up auto-repair service...
set "AUTO_REPAIR_SCRIPT=%SCRIPT_DIR%\auto-repair.bat"
set "AUTO_REPAIR_SERVICE=auto-repair"

if not exist "%AUTO_REPAIR_SCRIPT%" (echo ERROR: auto-repair.bat not found. & exit /b 1)

sc query %AUTO_REPAIR_SERVICE% >nul 2>&1 && (
    net stop %AUTO_REPAIR_SERVICE% >nul 2>&1
    "%NSSM_EXE%" remove %AUTO_REPAIR_SERVICE% confirm >nul 2>&1
)

"%NSSM_EXE%" install %AUTO_REPAIR_SERVICE% "cmd.exe" || (echo ERROR: Failed to install auto-repair. & exit /b 1)
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% AppParameters "/c \"%AUTO_REPAIR_SCRIPT%\"" >nul
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% AppDirectory "%SCRIPT_DIR%" >nul
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% Start SERVICE_AUTO_START >nul
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% AppStdout "%SCRIPT_DIR%\auto-repair.log" >nul
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% AppStderr "%SCRIPT_DIR%\auto-repair-error.log" >nul
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% DisplayName "Auto-Repair" >nul
"%NSSM_EXE%" set %AUTO_REPAIR_SERVICE% Description "Domain health monitor for GPU rental machine" >nul
net start %AUTO_REPAIR_SERVICE% >nul && echo [*] Auto-repair running. || echo [!] Auto-repair will start on next boot.

:: ===================================================================
:: Run TaskScheduler.ps1
:: ===================================================================
echo [*] Running TaskScheduler.ps1...
set "TASK_SCHEDULER_SCRIPT=%SCRIPT_DIR%\TaskScheduler.ps1"

if not exist "%TASK_SCHEDULER_SCRIPT%" (
    echo [!] WARNING: TaskScheduler.ps1 not found at "%TASK_SCHEDULER_SCRIPT%", skipping.
) else (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%TASK_SCHEDULER_SCRIPT%"
    if !errorlevel! neq 0 (
        echo [!] WARNING: TaskScheduler.ps1 exited with errors.
    ) else (
        echo [*] TaskScheduler.ps1 completed successfully.
    )
)



:: ===================================================================
:: Run launchGameTaskScheduler.ps1
:: ===================================================================
echo [*] Running launchGameTaskScheduler.ps1...
set "TASK_SCHEDULER_LAUNCH_GAME_SCRIPT=%SCRIPT_DIR%\launchGameTaskScheduler.ps1"

if not exist "%TASK_SCHEDULER_LAUNCH_GAME_SCRIPT%" (
    echo [!] WARNING: launchGameTaskScheduler.ps1 not found at "%TASK_SCHEDULER_LAUNCH_GAME_SCRIPT%", skipping.
) else (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%TASK_SCHEDULER_LAUNCH_GAME_SCRIPT%"
    if !errorlevel! neq 0 (
        echo [!] WARNING: launchGameTaskScheduler.ps1 exited with errors.
    ) else (
        echo [*] launchGameTaskScheduler.ps1 completed successfully.
    )
)
:: ===================================================================
:: Wallpaper (before admin rename - same as Setup-Wallpaper.bat standalone)
:: User Configuration GPO; runs Set-DesktopWallpaper-Gpo.ps1 via inline (no extra UAC)
:: ===================================================================
echo [*] Setting up desktop wallpaper (Group Policy)...
set "WALLPAPER_BAT=%SCRIPT_DIR%\Setup-Wallpaper.bat"
if not exist "%WALLPAPER_BAT%" (
    echo [!] WARNING: Setup-Wallpaper.bat not found, skipping wallpaper.
) else (
    call "%WALLPAPER_BAT%" inline
    if !errorlevel! neq 0 (
        echo [!] WARNING: Wallpaper setup returned exit code !errorlevel!.
    ) else (
        echo [*] Wallpaper policy ready. Check gpedit: User Configuration - Desktop Wallpaper.
    )
)
echo.

:: ===================================================================
:: Post-Registration: Set Admin Account Username and Full Name (after wallpaper)
:: ===================================================================
echo [*] Setting admin account "%ADMIN_ACCOUNT_NAME%" username and full name to NextGPU-Authority...
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$old='%ADMIN_ACCOUNT_NAME%'.Trim(); $new='NextGPU-Authority'; $u=Get-LocalUser -Name $old -EA SilentlyContinue; if(-not $u){$u=Get-LocalUser -Name $new -EA SilentlyContinue}; if(-not $u){Write-Host '[!] WARN: account not found:' $old; exit 1}; $e=Get-LocalUser -Name $new -EA SilentlyContinue; if($e -and $e.SID -ne $u.SID){Write-Host '[!] ERROR:' $new 'already exists'; exit 1}; if($u.Name -ine $new){Rename-LocalUser -Name $u.Name -NewName $new; Write-Host '[*] OK: renamed username' $u.Name 'to' $new}; if((Get-LocalUser -Name $new).FullName -cne $new){Set-LocalUser -Name $new -FullName $new; Write-Host '[*] OK: full name set to' $new} elseif($u.Name -ieq $new){Write-Host '[*] SKIP: username and full name already' $new}; exit 0"
if !errorlevel! neq 0 (
    echo [!] WARNING: Failed to update admin account. It may not exist or was already configured.
)

echo [*] Creating new user account...
net user "nextGPU" /add
if !errorlevel! equ 0 (
    echo [*] User account 'nextGPU' created successfully.
) else (
    echo [!] WARNING: Failed to create user account. It may already exist.
)
echo.
echo ========================================
echo Installation Complete!
echo Your machine is now registered and ready.
echo ========================================
echo.
echo [*] Reboot manually when convenient to finish driver and account changes.
pause
exit /b 0

:setup_sunshine_device_id
:: ===================================================================
:: Setup Sunshine output device_id (VDD / MTT1337)
:: ===================================================================
echo [*] Setting Sunshine output device_id...
set "DISPLAY_DEVICE_ID_SCRIPT=%SCRIPT_DIR%\Get-DisplayDeviceId.ps1"
if not exist "%DISPLAY_DEVICE_ID_SCRIPT%" (
    echo [!] WARNING: Get-DisplayDeviceId.ps1 not found, skipping device_id setup.
    exit /b 0
)
set "DISPLAY_DEVICE_ID="
for /f "delims=" %%D in ('powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DISPLAY_DEVICE_ID_SCRIPT%" 2^>nul') do set "DISPLAY_DEVICE_ID=%%D"
if not defined DISPLAY_DEVICE_ID (
    echo [!] Retrying device_id with inactive display paths...
    for /f "delims=" %%D in ('powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%DISPLAY_DEVICE_ID_SCRIPT%" -IncludeInactive 2^>nul') do set "DISPLAY_DEVICE_ID=%%D"
)
if not defined DISPLAY_DEVICE_ID (
    echo [!] WARNING: Failed to resolve display device_id. Install continues. Run Get-DisplayDeviceId.ps1 -ListAll after reboot.
    exit /b 0
)
powershell -NoLogo -NoProfile -Command "$id='%DISPLAY_DEVICE_ID%';$cfg='C:\Program Files\Sunshine\config\sunshine.conf';if(-not(Test-Path $cfg)){Write-Error 'sunshine.conf not found';exit 1};function Set-Line([string]$c,[string]$n,[string]$v){if($c -match ('(?m)^\s*'+[regex]::Escape($n)+'\s*=')){return ($c -replace ('(?m)^\s*'+[regex]::Escape($n)+'\s*=.*'),($n+' = '+$v))}return ($c.TrimEnd()+\"`r`n\"+$n+' = '+$v+\"`r`n\")};$c=Get-Content -Raw $cfg;$c=Set-Line $c 'output_name' $id;$c=Set-Line $c 'dd_configuration_option' 'ensure_active';[IO.File]::WriteAllText($cfg,$c,[Text.UTF8Encoding]::new($false));exit 0"
if !errorlevel! neq 0 (
    echo [!] WARNING: Failed to update sunshine.conf with output_name.
    exit /b 0
)
echo [*] output_name set to %DISPLAY_DEVICE_ID%
echo [*] dd_configuration_option set to ensure_active
taskkill /f /im sunshine.exe >nul 2>&1
timeout /t 3 /nobreak >nul
start "" "C:\Program Files\Sunshine\sunshine.exe"
timeout /t 5 /nobreak >nul
echo [*] Sunshine restarted with VDD display settings.
exit /b 0