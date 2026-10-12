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
:: CHECK MACHINE STATUS FLAG
:: ==============================
set "DOMAIN_FILE=%SCRIPT_DIR%\domain.txt"
set "DOMAIN_STATUS="
set "COMPUTER_NAME="
set "PUBLIC_IP="
set "PRIVATE_IP="
set "VENDOR_ID="
set "VENDOR_ID_ENABLED="
set "IDENTITY_PS1=%SCRIPT_IMPL_DIR%\Invoke-NextGpuMachineIdentity.ps1"
if exist "%IDENTITY_PS1%" (
    for /f "usebackq delims=" %%S in (`powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%IDENTITY_PS1%" -Action GetStatus -RepoRoot "%SCRIPT_DIR%"`) do set "DOMAIN_STATUS=%%S"
)
if not defined DOMAIN_STATUS set "DOMAIN_STATUS=online"
if /i "!DOMAIN_STATUS!"=="updating" (
    echo [*] Machine is currently updating - skipping repair.
    exit /b 0
)
echo [*] machine-status.flag=!DOMAIN_STATUS!

if exist "%DOMAIN_FILE%" (
    for /f "tokens=2 delims==" %%A in ('findstr "COMPUTER_NAME=" "%DOMAIN_FILE%"') do set "COMPUTER_NAME=%%A"
    for /f "tokens=2 delims==" %%A in ('findstr "PUBLIC_IP=" "%DOMAIN_FILE%"') do set "PUBLIC_IP=%%A"
    for /f "tokens=2 delims==" %%A in ('findstr "VENDOR_ID_ENABLED=" "%DOMAIN_FILE%"') do set "VENDOR_ID_ENABLED=%%A"
    for /f "tokens=2 delims==" %%A in ('findstr /b "VENDOR_ID=" "%DOMAIN_FILE%"') do set "VENDOR_ID=%%A"
)
if not defined VENDOR_ID_ENABLED (
    if defined VENDOR_ID (
        set "VENDOR_ID_ENABLED=yes"
    ) else (
        set "VENDOR_ID_ENABLED=no"
    )
)

for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /i "192.168.1."') do (
    for /f "tokens=* delims= " %%b in ("%%a") do (set "PRIVATE_IP=%%b" & goto :private_ip_found)
)
:private_ip_found
if not defined PRIVATE_IP set "PRIVATE_IP=127.0.0.1"

set "STATUS_API=https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus"
set "ERROR_MARKED=0"
set "UNRESOLVED=0"
set "STOP_FOR_UPDATE=0"

echo [*] Running health check...
set "REPAIR_NEEDED=0"
set "REPAIR_REASON="
set "PAIR_NEEDED=0"
set "SUN_CREDS_NEEDED=0"

:: ==============================
:: CHECK 1: cloudflared service
:: Never triggers Sunshine/Moonlight ForceReinstall — tunnel-only recovery.
:: ==============================
sc query cloudflared | find "RUNNING" >nul
if errorlevel 1 (
    echo [!] cloudflared is NOT running. Attempting restart...
    call :mark_error
    net start cloudflared >nul 2>&1
    timeout /t 3 /nobreak >nul
    sc query cloudflared | find "RUNNING" >nul
    if errorlevel 1 (
        echo [!] cloudflared restart failed - leaving Sunshine/Moonlight alone.
        echo [!] Fix cloudflared separately; will not ForceReinstall streaming stack.
        set "UNRESOLVED=1"
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
    call :mark_error
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
    call :mark_error
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
    echo [WARN] Local service returned status: !HTTP_STATUS!
    call :mark_error
    set "REPAIR_NEEDED=1"
    if not defined REPAIR_REASON set "REPAIR_REASON=HTTP !HTTP_STATUS!"
)

:: ==============================
:: CHECK 5: Sunshine credentials + Moonlight pairing material
:: Missing creds/pair => restore/re-pair only (no ForceReinstall unless stack is down).
:: ==============================
set "CRED_TEST_PS1=%SCRIPT_DIR%\scripts\provisioning\Test-StreamingCredentials.ps1"
set "RESTORE_CREDS_PS1=%SCRIPT_DIR%\scripts\provisioning\Restore-SunshineCredentials.ps1"
if "!REPAIR_NEEDED!"=="0" (
    if exist "!CRED_TEST_PS1!" (
        powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "!CRED_TEST_PS1!" -RepoRoot "!SCRIPT_DIR!"
        if errorlevel 3 (
            echo [!] Sunshine credentials AND Moonlight pairing material missing.
            set "SUN_CREDS_NEEDED=1"
            set "PAIR_NEEDED=1"
            call :mark_error
        ) else if errorlevel 2 (
            echo [!] Sunshine API credentials deleted or empty.
            set "SUN_CREDS_NEEDED=1"
            set "PAIR_NEEDED=1"
            call :mark_error
        ) else if errorlevel 1 (
            echo [!] Moonlight pairing credentials deleted or incomplete.
            set "PAIR_NEEDED=1"
            call :mark_error
        ) else (
            echo [*] Streaming credentials / pairing: OK
        )
    ) else (
        echo [WARN] Credential test script missing: !CRED_TEST_PS1!
        set "PAIR_NEEDED=1"
        call :mark_error
    )
) else (
    echo [*] Skipping credential check ^(full repair will restore creds + pair^).
)

if "!STOP_FOR_UPDATE!"=="1" goto stop_for_update

:: ==============================
:: FULL REPAIR (Sunshine + Moonlight + pairing)
:: Only for Sunshine / Moonlight / HTTP failures — NOT cloudflared.
:: ==============================
if "!REPAIR_NEEDED!"=="1" (
    echo.
    echo [WARN] Health check failed. Reason: !REPAIR_REASON!
    echo [!] Starting full repair...
    echo ====================================================================
    echo.
    call "%~dp0Run-StreamingStackUpdate.bat" ForceReinstall ForceReinstall ForcePairing
    if errorlevel 1 goto repair_failed
    echo [*] Repair complete.
    goto repair_done
)

:: ==============================
:: RESTORE SUNSHINE CREDENTIALS (no reinstall)
:: ==============================
if "!SUN_CREDS_NEEDED!"=="1" (
    echo.
    echo [!] Restoring Sunshine credentials ^(no stack reinstall^)...
    echo ====================================================================
    if not exist "!RESTORE_CREDS_PS1!" (
        echo [WARN] Missing !RESTORE_CREDS_PS1!
        goto repair_failed
    )
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "!RESTORE_CREDS_PS1!" -RepoRoot "!SCRIPT_DIR!"
    if errorlevel 1 (
        echo [!] Sunshine credential restore failed.
        goto repair_failed
    )
    echo [*] Sunshine credentials restored.
    set "PAIR_NEEDED=1"
)

:: ==============================
:: PAIRING-ONLY REPAIR (restores deleted Moonlight pair_info)
:: ==============================
if "!PAIR_NEEDED!"=="1" (
    echo.
    echo [!] Pairing / credential material needs repair.
    echo [!] Re-pairing Moonlight with Sunshine ^(no stack reinstall^)...
    echo ====================================================================
    echo.
    call "%~dp0Run-StreamingStackUpdate.bat" Skip Skip ForcePairing
    if errorlevel 1 goto repair_failed
    echo [*] Pairing repair complete.
    goto repair_done
)

echo [*] All checks passed.
goto repair_done

:: ==============================
:: STATUS REPORTING
:: error: flag + updateStatus as soon as a failure is found (skipped for update_fail).
:: After a successful repair: error -> online; update_fail -> onDemandGPUHost (vendor) or online.
:: ==============================
:repair_done
if "!STOP_FOR_UPDATE!"=="1" goto stop_for_update
if "!UNRESOLVED!"=="1" (
    echo [WARN] Unresolved failure - status left as !DOMAIN_STATUS!.
    exit /b 1
)
if /i "!DOMAIN_STATUS!"=="update_fail" if "!ERROR_MARKED!"=="1" (
    if /i "!VENDOR_ID_ENABLED!"=="yes" goto ondemand_shutdown
    call :post_status online
    if "!STOP_FOR_UPDATE!"=="1" goto stop_for_update
    exit /b 0
)
if /i "!DOMAIN_STATUS!"=="error" call :post_status online
if "!STOP_FOR_UPDATE!"=="1" goto stop_for_update
exit /b 0

:ondemand_shutdown
call :read_current_status
if /i "!CURRENT_STATUS!"=="updating" goto stop_for_update
set "VENDOR_SHUTDOWN_PS1=%SCRIPT_IMPL_DIR%\Invoke-VendorOfflineShutdown.ps1"
if not exist "!VENDOR_SHUTDOWN_PS1!" (
    echo [ERROR] Invoke-VendorOfflineShutdown.ps1 not found. Flag stays update_fail.
    exit /b 1
)
echo [*] update_fail repaired on vendor host - calling onDemandGPUHost shutdown only ^(no status change^).
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "!VENDOR_SHUTDOWN_PS1!" -ComputerName "!COMPUTER_NAME!"
if errorlevel 1 (
    echo [WARN] onDemandGPUHost shutdown failed ^(exit !errorlevel!^). Flag stays update_fail.
    exit /b 1
)
echo [*] onDemandGPUHost shutdown requested; flag left as update_fail.
exit /b 0

:stop_for_update
echo [*] Machine status changed to updating during this run - stopping without touching status.
exit /b 0

:mark_error
if "!ERROR_MARKED!"=="1" exit /b 0
set "ERROR_MARKED=1"
if /i "!DOMAIN_STATUS!"=="update_fail" (
    echo [*] Flag is update_fail - repairing only, status unchanged.
    exit /b 0
)
if /i "!DOMAIN_STATUS!"=="error" (
    echo [*] Status already error - not re-sending.
    exit /b 0
)
call :post_status error
exit /b 0

:: Never overwrite updating: checking-update may have started after this run read the flag.
:post_status
call :read_current_status
if /i "!CURRENT_STATUS!"=="updating" (
    set "STOP_FOR_UPDATE=1"
    exit /b 0
)
if exist "%IDENTITY_PS1%" (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%IDENTITY_PS1%" -Action SetStatus -Status %~1 >nul
    if errorlevel 1 echo [!] WARNING: Failed to write machine-status.flag=%~1.
)
set "STATUS_PAYLOAD={\"computer_name\":\"!COMPUTER_NAME!\",\"publicIP\":\"!PUBLIC_IP!\",\"privateIP\":\"!PRIVATE_IP!\",\"status\":\"%~1\"}"
curl -s --max-time 15 -X POST "!STATUS_API!" -H "Content-Type: application/json" -d "!STATUS_PAYLOAD!"
echo.
set "DOMAIN_STATUS=%~1"
echo [*] Status set to %~1 ^(machine-status.flag + updateStatus API^).
exit /b 0

:read_current_status
set "CURRENT_STATUS="
if exist "%IDENTITY_PS1%" (
    for /f "usebackq delims=" %%S in (`powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%IDENTITY_PS1%" -Action GetStatus -RepoRoot "%SCRIPT_DIR%"`) do set "CURRENT_STATUS=%%S"
)
exit /b 0

:repair_failed
echo [!] Repair failed.
if exist "%TEMP%\moonlight_login.json" del "%TEMP%\moonlight_login.json" >nul 2>&1
if exist "%TEMP%\moonlight_pin_response.json" del "%TEMP%\moonlight_pin_response.json" >nul 2>&1
if exist "%TEMP%\moonlight_pair_complete.json" del "%TEMP%\moonlight_pair_complete.json" >nul 2>&1
if exist "%COOKIES%" del "%COOKIES%" >nul 2>&1
exit /b 1
