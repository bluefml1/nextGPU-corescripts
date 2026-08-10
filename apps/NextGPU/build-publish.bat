@echo off
setlocal enabledelayedexpansion
:: Build self-contained NextGPU.App (dashboard) and NextGPU.Service (game launcher service).
cd /d "%~dp0"

set "REPO_ROOT=%~dp0..\.."
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

set "SVC_INSTALL_DIR=C:\Program Files\NextGPU\Service"

echo ========================================
echo  NextGPU - Build and Publish
echo ========================================
echo.

where dotnet <nul >nul 2>&1
if errorlevel 1 (
    echo [ERROR] dotnet host not found. Install .NET 8 SDK from:
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

set "HAS_SDK="
for /f "delims=" %%s in ('dotnet --list-sdks 2^>nul') do (
    set "HAS_SDK=1"
    echo [*] Installed SDK: %%s
)
if not defined HAS_SDK (
    echo [ERROR] No .NET SDK installed ^(runtime-only dotnet is not enough^).
    echo   Install .NET 8 SDK.
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

for /f "tokens=*" %%v in ('dotnet --version 2^>nul') do set "DOTNET_VER=%%v"
echo [*] Using dotnet !DOTNET_VER!
echo.

:: ---------------------------------------------------------------------------
:: 1. Publish NextGPU.App (dashboard)
:: ---------------------------------------------------------------------------
echo ========================================
echo  [1/2] Building NextGPU.App (dashboard)
echo ========================================
echo.

if not exist "publish" mkdir "publish"

dotnet publish NextGPU.App\NextGPU.App.csproj ^
    -c Release ^
    -r win-x64 ^
    --self-contained true ^
    -p:PublishSingleFile=true ^
    -p:IncludeNativeLibrariesForSelfExtract=true ^
    -p:EnableCompressionInSingleFile=true ^
    -o publish

if errorlevel 1 (
    echo [ERROR] NextGPU.App publish failed.
    exit /b 1
)

for %%e in (NextGPU.exe NextGPU.dll) do (
    if exist "publish\%%e" (
        echo [OK] NextGPU.App -> apps\NextGPU\publish\%%e
        goto :app_done
    )
)
:app_done

echo [*] Copying to repo root for NextGPU.bat launcher...
copy /y "publish\NextGPU.exe" "%REPO_ROOT%\NextGPU.exe" <nul >nul 2>&1
if errorlevel 1 (
    echo [!] Could not copy to repo root; use apps\NextGPU\publish\NextGPU.exe
) else (
    echo [OK] NextGPU.exe -> %REPO_ROOT%\NextGPU.exe
)
echo.

:: ---------------------------------------------------------------------------
:: 2. Publish NextGPU.Service (game launcher service)
:: ---------------------------------------------------------------------------
echo ========================================
echo  [2/3] Building NextGPU.Service
echo ========================================
echo.

dotnet publish NextGPU.Service\NextGPU.Service.csproj ^
    -c Release ^
    -r win-x64 ^
    --self-contained true ^
    -p:PublishSingleFile=true ^
    -p:IncludeNativeLibrariesForSelfExtract=true ^
    -p:EnableCompressionInSingleFile=true ^
    -o "publish\Service"

if errorlevel 1 (
    echo [ERROR] NextGPU.Service publish failed.
    exit /b 1
)

if not exist "publish\Service\NextGPUService.exe" (
    echo [ERROR] publish\Service\NextGPUService.exe was not created.
    exit /b 1
)
echo [OK] NextGPU.Service -^> apps\NextGPU\publish\Service\NextGPUService.exe

:: ---------------------------------------------------------------------------
:: 3. Publish NextGPU.Launcher (in-session desktop broker)
:: ---------------------------------------------------------------------------
echo ========================================
echo  [3/3] Building NextGPU.Launcher
echo ========================================
echo.

set "LAUNCHER_INSTALL_DIR=%ProgramFiles%\NextGPU\Launcher"

dotnet publish NextGPU.Launcher\NextGPU.Launcher.csproj ^
    -c Release ^
    -r win-x64 ^
    --self-contained true ^
    -p:PublishSingleFile=true ^
    -p:IncludeNativeLibrariesForSelfExtract=true ^
    -p:EnableCompressionInSingleFile=true ^
    -o "publish\Launcher"

if errorlevel 1 (
    echo [ERROR] NextGPU.Launcher publish failed.
    exit /b 1
)

if not exist "publish\Launcher\NextGPU.Launcher.exe" (
    echo [ERROR] publish\Launcher\NextGPU.Launcher.exe was not created.
    exit /b 1
)
echo [OK] NextGPU.Launcher -^> apps\NextGPU\publish\Launcher\NextGPU.Launcher.exe

:: Install to default location
sc query NextGPUService 2>nul | findstr /i "SERVICE_NAME" <nul >nul 2>&1
if not errorlevel 1 (
    echo [*] Stopping existing NextGPUService...
    sc stop NextGPUService <nul >nul 2>&1
    ping 127.0.0.1 -n 4 -w 1000 <nul >nul 2>&1
)
echo [*] Installing NextGPUService to %SVC_INSTALL_DIR%...
if not exist "%SVC_INSTALL_DIR%" mkdir "%SVC_INSTALL_DIR%"
copy /y "publish\Service\NextGPUService.exe" "%SVC_INSTALL_DIR%\NextGPUService.exe" <nul >nul 2>&1
if errorlevel 1 goto :copy_failed
echo [OK] NextGPUService installed to %SVC_INSTALL_DIR%
echo [*] Installing NextGPU.Launcher to %LAUNCHER_INSTALL_DIR%...
if not exist "%LAUNCHER_INSTALL_DIR%" mkdir "%LAUNCHER_INSTALL_DIR%"
copy /y "publish\Launcher\NextGPU.Launcher.exe" "%LAUNCHER_INSTALL_DIR%\NextGPU.Launcher.exe" <nul >nul 2>&1
if errorlevel 1 (
    echo [!] Could not copy launcher to %LAUNCHER_INSTALL_DIR%
) else (
    echo [OK] NextGPU.Launcher installed to %LAUNCHER_INSTALL_DIR%
)
echo [*] Registering service with SCM + EventLog source + firewall rule (built-in tools only)...
call :RegisterService "%SVC_INSTALL_DIR%\NextGPUService.exe"
goto :svc_done
:copy_failed
echo [!] Could not copy service binary to %SVC_INSTALL_DIR%
echo     Run as Administrator to install the service.
:svc_done
echo.

:: ---------------------------------------------------------------------------
:: Done
:: ---------------------------------------------------------------------------
echo ========================================
echo  Build complete
echo ========================================
echo   Dashboard : %REPO_ROOT%\NextGPU.exe
echo   Service   : %SVC_INSTALL_DIR%\NextGPUService.exe
echo   Launcher  : %LAUNCHER_INSTALL_DIR%\NextGPU.Launcher.exe
echo.
echo   To install service (now done automatically if you ran as Administrator):
echo     sc create NextGPUService binPath= "C:\Program Files\NextGPU\Service\NextGPUService.exe" start= auto
echo     sc start NextGPUService
echo.
echo   To smoke test:
echo     powerShell -ExecutionPolicy Bypass -File scripts\runtime\Test-NextGPUService.ps1
echo ========================================
exit /b 0

:: ---------------------------------------------------------------------------
:: RegisterService: idempotently registers NextGPUService with the SCM, writes
:: the EventLog source under HKLM, and ensures the named-pipe firewall rule
:: is present. Uses only built-in tools (sc.exe, reg.exe, netsh, mkdir).
:: ---------------------------------------------------------------------------
:RegisterService
set "SVC_BIN=%~1"
set "SVC_NAME=NextGPUService"
set "SVC_DISPLAY=NextGPU Game Launcher Service"
set "SVC_DESC=Launches games in the correct user session with optional elevation via nextGPU-Admin credentials."

:: Make sure we're running elevated. If not, sc.exe will fail with ERROR_ACCESS_DENIED.
net session <nul >nul 2>&1
if errorlevel 1 (
    echo [!] Not running as Administrator; service registration skipped.
    echo     Re-run this build-publish.bat from an elevated Command Prompt.
    goto :eof
)

:: Stop + delete any previous registration so create is idempotent
sc query %SVC_NAME% 2>nul | findstr /i "STATE" <nul >nul 2>&1
if not errorlevel 1 goto :svc_fresh
echo [*] Removing existing service registration...
sc stop %SVC_NAME% <nul >nul 2>&1
ping 127.0.0.1 -n 4 -w 1000 <nul >nul 2>&1
sc delete %SVC_NAME% <nul >nul 2>&1
ping 127.0.0.1 -n 3 -w 1000 <nul >nul 2>&1
:svc_fresh

echo [*] Creating service '%SVC_NAME%'...
sc create %SVC_NAME% binPath= "%SVC_BIN%" start= auto DisplayName= "%SVC_DISPLAY%"
if errorlevel 1 (
    echo [ERROR] sc create failed.
    goto :eof
)

echo [*] Setting description + recovery actions...
sc description %SVC_NAME% "%SVC_DESC%"
sc failure %SVC_NAME% reset= 86400 actions= restart/60000/restart/60000/restart/60000

echo [*] Writing registry metadata...
reg add "HKLM\SOFTWARE\NextGPU\Service" /f <nul >nul 2>&1
reg add "HKLM\SOFTWARE\NextGPU\Service" /v PipeName   /t REG_SZ /d "NextGPUControl" /f <nul >nul 2>&1
reg add "HKLM\SOFTWARE\NextGPU\Service" /v InstallPath /t REG_SZ /d "%SVC_BIN%" /f <nul >nul 2>&1
reg add "HKLM\SOFTWARE\NextGPU\Service" /v Version    /t REG_SZ /d "1.0.0" /f <nul >nul 2>&1

echo [*] Registering EventLog source 'NextGPUService'...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\NextGPUService" /f <nul >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\NextGPUService" /v EventMessageFile /t REG_SZ /d "%SystemRoot%\Microsoft.NET\Framework64\v4.0.30319\EventLogMessages.dll" /f <nul >nul 2>&1
reg add "HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\NextGPUService" /v TypesSupported /t REG_DWORD /d 7 /f <nul >nul 2>&1

echo [*] Ensuring firewall rule for named-pipe inbound (skipped if firewall service is off)...
set "FW_NAME=NextGPUService - Named Pipe NextGPUControl"
sc query MpsSvc 2>nul | findstr /i "STATE" <nul >nul 2>&1
if errorlevel 1 goto :fw_skipped
netsh advfirewall firewall show rule name="%FW_NAME%" > "%TEMP%\ngfwcheck.txt" 2>&1
findstr /i /c:"%FW_NAME%" "%TEMP%\ngfwcheck.txt" <nul >nul 2>&1
if not errorlevel 1 goto :fw_present
netsh advfirewall firewall add rule name="%FW_NAME%" dir=in action=allow service=any enable=yes profile=any <nul >nul 2>&1
if errorlevel 1 goto :fw_failed
echo     - Firewall rule created.
goto :fw_done
:fw_present
echo     - Firewall rule already present.
goto :fw_done
:fw_failed
echo     - WARNING: could not add firewall rule ^^(firewall service off or locked by GPO^^). Continuing.
goto :fw_done
:fw_skipped
echo     - Windows Firewall service not available; skipping rule ^^(named pipes don't need it^^).
:fw_done
del "%TEMP%\ngfwcheck.txt" <nul >nul 2>&1

echo [*] Ensuring log directory exists...
if not exist "%ProgramData%\NextGPU\Logs" mkdir "%ProgramData%\NextGPU\Logs" <nul >nul 2>&1

echo [*] Starting service (in background)...
:: Start the service without waiting - use start "" to detach from current session.
:: sc start will return immediately because it spawns the service process.
start "" /b sc start %SVC_NAME% >nul 2>&1
:: Wait a moment for the service to start, then confirm status
ping 127.0.0.1 -n 4 -w 1000 <nul >nul 2>&1
for /f "delims=" %%s in ('sc query %SVC_NAME% 2^>nul ^| findstr /i "STATE"') do echo %%s
for /f "tokens=*" %%r in ('sc query %SVC_NAME% 2^>nul ^| findstr /i "RUNNING"') do goto :svc_running
echo [WARN] Service may not have started cleanly. Check: sc query %SVC_NAME%
goto :svc_check_done
:svc_running
echo [OK] NextGPUService is running.
:svc_check_done
exit /b 0
