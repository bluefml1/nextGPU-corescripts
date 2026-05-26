@echo off
setlocal enabledelayedexpansion

:: =====================================================================
:: update-games.bat — wrapper for Update-Games.ps1
:: Double-click to run, or call from another script
:: =====================================================================

:: Auto-elevate to Admin
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    goto :EOF
)

set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PS_SCRIPT=%SCRIPT_DIR%\Update-Games.ps1"

if not exist "%PS_SCRIPT%" (
    echo ERROR: Update-Games.ps1 not found at "%PS_SCRIPT%"
    pause
    exit /b 1
)

:: Read from domain.txt if available
set "COMPUTER_NAME="
set "PUBLIC_IP="
if exist "%SCRIPT_DIR%\domain.txt" (
    for /f "tokens=1,2 delims==" %%a in (%SCRIPT_DIR%\domain.txt) do (
        if "%%a"=="COMPUTER_NAME" set "COMPUTER_NAME=%%b"
        if "%%a"=="PUBLIC_IP"     set "PUBLIC_IP=%%b"
    )
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

powershell -ExecutionPolicy Bypass -NoProfile -File "%PS_SCRIPT%" -ComputerName "%COMPUTER_NAME%" -PublicIP "%PUBLIC_IP%"

echo.
pause