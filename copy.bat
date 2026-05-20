@echo off
setlocal enabledelayedexpansion

:: =============== RESOLVE SCRIPT DIRECTORY ===============
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
:: =========================================================

:: Auto-elevate to Admin
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting Administrator privileges...
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    goto :EOF
)

echo [INFO] Running with Administrator privileges.
echo [INFO] Script directory: %SCRIPT_DIR%
echo.

:: ===================================================================
:: Connect to network share and copy files
:: ===================================================================
set "SHARE_HOST=\\10.10.20.20\ezc_Viethung"
set "SHARE_USER=name123"
set "SHARE_PASS=password123"

echo [*] Connecting to %SHARE_HOST%...
net use "%SHARE_HOST%" "%SHARE_PASS%" /user:"%SHARE_USER%" /persistent:no
if !errorlevel! neq 0 (
    echo ERROR: Failed to connect to %SHARE_HOST%. Check network or credentials.
    pause
    exit /b 1
)

echo [*] Connected. Copying files to %SCRIPT_DIR%...
robocopy "%SHARE_HOST%" "%SCRIPT_DIR%" /E /Z /COPYALL /R:3 /W:5 /NP /LOG:"%SCRIPT_DIR%\network_copy.log"

if !errorlevel! geq 8 (
    echo ERROR: File copy failed. Check %SCRIPT_DIR%\network_copy.log for details.
    net use "%SHARE_HOST%" /delete >nul 2>&1
    pause
    exit /b 1
)

echo [*] All files copied successfully.
echo [*] Log saved to: %SCRIPT_DIR%\network_copy.log

:: Disconnect
net use "%SHARE_HOST%" /delete >nul 2>&1
echo [*] Disconnected from network share.


:: ===================================================================
:: Run extract.bat
:: ===================================================================
echo.
echo [*] Running extract.bat...
set "EXTRACT_SCRIPT=%SCRIPT_DIR%\extract.bat"

if not exist "%EXTRACT_SCRIPT%" (
    echo ERROR: extract.bat not found at "%EXTRACT_SCRIPT%"
    pause
    exit /b 1
)

call "%EXTRACT_SCRIPT%"
if !errorlevel! neq 0 (
    echo ERROR: extract.bat failed with error code !errorlevel!
    pause
    exit /b 1
)

echo.
echo ========================================
echo Done! Files are ready in:
echo %SCRIPT_DIR%
echo ========================================
echo.
pause