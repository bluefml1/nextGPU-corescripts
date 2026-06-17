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

:wait_for_network
ping -n 1 8.8.8.8 >nul
if errorlevel 1 (timeout /t 5 /nobreak >nul & goto wait_for_network)

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
    echo [*] Machine is currently updating - skipping repair.
    exit /b 0
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
    echo [*] All checks passed.
    exit /b 0
)

echo.
echo [!] Health check failed. Reason: !REPAIR_REASON!
echo [!] Starting full repair...
echo ====================================================================

:: ===================================================================
:: Reinstall Sunshine + Moonlight + pairing (shared stack script)
:: ===================================================================
echo.
call "%~dp0Run-StreamingStackUpdate.bat" ForceReinstall ForceReinstall ForcePairing
if errorlevel 1 goto repair_failed
echo [*] Repair complete.
exit /b 0
:repair_failed
echo [!] Repair failed.
taskkill /f /im curl.exe >nul 2>&1
if exist "%TEMP%\moonlight_login.json" del "%TEMP%\moonlight_login.json" >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1
if exist "%TEMP%\moonlight_pair_complete.json" del "%TEMP%\moonlight_pair_complete.json" >nul 2>&1
if exist "%COOKIES%" del "%COOKIES%" >nul 2>&1
exit /b 1
