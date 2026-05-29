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

:: ==============================
:: CONFIGURATION
:: ==============================
set "API_UPDATE_URL=https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus"
set "DEFAULT_STATUS=online"
set "INTERVAL_SECONDS=300"

:loop
:: Timestamp
for /f "tokens=1-4 delims=/ " %%a in ('date /t') do (set "MM=%%a" & set "DD=%%b" & set "YYYY=%%c")
for /f "tokens=1-2 delims=:." %%a in ('time /t') do (set "HH=%%a" & set "MIN=%%b")
if "!HH!"=="" set "HH=00"
if "!HH:~1,1!"=="" set "HH=0!HH!"
if "!MIN:~1,1!"=="" set "MIN=0!MIN!"
set "TIMESTAMP=[%DATE% %HH%:%MIN%:00.00]"

:: ==============================
:: READ MACHINE INFO
:: ==============================
set "DOMAIN_FILE=%SCRIPT_DIR%\domain.txt"
if not exist "%DOMAIN_FILE%" (
    echo [ERROR] domain.txt not found at: %DOMAIN_FILE%. Retrying in 60s...
    timeout /t 60 /nobreak >nul
    goto loop
)

set "DOMAIN=" & set "PUBLIC_IP=" & set "COMPUTER_NAME="
for /f "tokens=2 delims==" %%A in ('findstr "DOMAIN=" "%DOMAIN_FILE%"') do set "DOMAIN=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "PUBLIC_IP=" "%DOMAIN_FILE%"') do set "PUBLIC_IP=%%A"
for /f "tokens=2 delims==" %%A in ('findstr "COMPUTER_NAME=" "%DOMAIN_FILE%"') do set "COMPUTER_NAME=%%A"

if not defined PUBLIC_IP (echo [ERROR] PUBLIC_IP missing. Retrying... & timeout /t 60 /nobreak >nul & goto loop)
if not defined COMPUTER_NAME (echo [ERROR] COMPUTER_NAME missing. Retrying... & timeout /t 60 /nobreak >nul & goto loop)

:: Get Private IP
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "192.168.1."') do (
    for /f "tokens=* delims= " %%b in ("%%a") do (set "PRIVATE_IP=%%b" & goto :private_ip_found)
)
:private_ip_found
if not defined PRIVATE_IP set "PRIVATE_IP=127.0.0.1"

:: ==============================
:: DETERMINE STATUS FROM DOMAIN FILE
:: ==============================
set "CURRENT_STATUS="
for /f "tokens=2 delims==" %%A in ('findstr "STATUS=" "%DOMAIN_FILE%"') do set "CURRENT_STATUS=%%A"
if "!CURRENT_STATUS!"=="" set "CURRENT_STATUS=%DEFAULT_STATUS%"

:: Build and send payload
set "PAYLOAD={\"computer_name\":\"%COMPUTER_NAME%\",\"publicIP\":\"%PUBLIC_IP%\",\"privateIP\":\"%PRIVATE_IP%\",\"status\":\"!CURRENT_STATUS!\"}"
echo %TIMESTAMP% STATUS=!CURRENT_STATUS! PUBLIC=%PUBLIC_IP% PRIVATE=%PRIVATE_IP%
set "RESPONSE_FILE=%TEMP%\api_resp_heartbeat.txt"
curl -s -X POST "%API_UPDATE_URL%" -H "Content-Type: application/json" -d "%PAYLOAD%" -o "%RESPONSE_FILE%"
echo %TIMESTAMP% RESPONSE:
type "%RESPONSE_FILE%"
del "%RESPONSE_FILE%" >nul 2>&1
echo.
timeout /t %INTERVAL_SECONDS% /nobreak >nul
goto loop