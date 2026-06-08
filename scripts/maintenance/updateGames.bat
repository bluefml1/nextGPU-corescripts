@echo off
setlocal enabledelayedexpansion

:: =====================================================================
:: update-games.bat — wrapper for Update-Games.ps1
:: Double-click to run, or call from another script
::   /UseDomainTxt  — read COMPUTER_NAME and PUBLIC_IP from domain.txt (no prompts)
:: =====================================================================

set "USE_DOMAIN_TXT="
if /i "%~1"=="/UseDomainTxt" (
    set "USE_DOMAIN_TXT=1"
    shift
)

:: Auto-elevate to Admin
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    goto :EOF
)

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)

set "PS_SCRIPT=%SCRIPT_DIR%\scripts\maintenance\Update-Games.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: Update-Games.ps1 not found at "%PS_SCRIPT%"
    pause
    exit /b 1
)

:: Read from domain.txt if available
set "COMPUTER_NAME="
set "PUBLIC_IP="
if exist "%SCRIPT_DIR%\domain.txt" (
    for /f "usebackq tokens=1,2 delims==" %%a in ("%SCRIPT_DIR%\domain.txt") do (
        if "%%a"=="COMPUTER_NAME" set "COMPUTER_NAME=%%b"
        if "%%a"=="PUBLIC_IP"     set "PUBLIC_IP=%%b"
    )
)

if defined USE_DOMAIN_TXT (
    if not defined COMPUTER_NAME (
        echo ERROR: COMPUTER_NAME missing from "%SCRIPT_DIR%\domain.txt"
        pause
        exit /b 1
    )
    if not defined PUBLIC_IP (
        echo ERROR: PUBLIC_IP missing from "%SCRIPT_DIR%\domain.txt"
        pause
        exit /b 1
    )
    echo [INFO] Using domain.txt:
    echo   computer_name = %COMPUTER_NAME%
    echo   publicIP      = %PUBLIC_IP%
    echo.
    goto :run_script
)

if defined COMPUTER_NAME if defined PUBLIC_IP (
    echo [INFO] Auto-detected from domain.txt:
    echo   computer_name = %COMPUTER_NAME%
    echo   publicIP      = %PUBLIC_IP%
    echo.
    set /p "USE_AUTO=Use these values? (Y/N): "
    if /i "!USE_AUTO!"=="Y" goto :run_script
)

:ask_input
set /p "COMPUTER_NAME=Enter computer_name: "
set /p "PUBLIC_IP=Enter publicIP: "

:run_script
echo.
echo Running Update-Games.ps1...
echo.

set "NEXTGPU_REPO_ROOT=%SCRIPT_DIR%"
powershell -ExecutionPolicy Bypass -NoProfile -File "%PS_SCRIPT%" -ComputerName "%COMPUTER_NAME%" -PublicIP "%PUBLIC_IP%"

echo.
pause