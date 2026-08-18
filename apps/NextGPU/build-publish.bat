@echo off
setlocal enabledelayedexpansion
:: Build self-contained NextGPU.App (dashboard) and NextGPU.Service (game launcher service).
cd /d "%~dp0"

:: Normalize repo root (avoid ...\apps\NextGPU\..\.. in paths)
for %%I in ("%~dp0..\..") do set "REPO_ROOT=%%~fI"

set "SVC_INSTALL_DIR=C:\Program Files\NextGPU\Service"

echo ========================================
echo  NextGPU - Build and Publish
echo ========================================
echo.

:: Ensure freshly-installed SDK is visible — probe absolute hosts one-by-one
:: NEVER put %ProgramFiles(x86)% inside a for (...) list — the ')' breaks CMD parsing.
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$m=[Environment]::GetEnvironmentVariable('Path','Machine'); $u=[Environment]::GetEnvironmentVariable('Path','User'); if ($m -and $u) { $m + ';' + $u } elseif ($m) { $m } elseif ($u) { $u } else { '' }"`) do (
    if not "%%P"=="" set "PATH=%%P"
)

set "DOTNET_EXE="
:: Prefer parent-resolved host or repo-local portable SDK
if defined NEXTGPU_DOTNET if exist "%NEXTGPU_DOTNET%" call :try_host "%NEXTGPU_DOTNET%"
if not defined DOTNET_EXE call :try_host "%REPO_ROOT%\.dotnet\dotnet.exe"
if not defined DOTNET_EXE if defined ProgramW6432 call :try_host "%ProgramW6432%\dotnet\dotnet.exe"
if not defined DOTNET_EXE call :try_host "%ProgramFiles%\dotnet\dotnet.exe"
if not defined DOTNET_EXE (
    set "PF86=%ProgramFiles(x86)%"
    if defined PF86 call :try_host "!PF86!\dotnet\dotnet.exe"
)
if not defined DOTNET_EXE call :try_host "%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe"
if not defined DOTNET_EXE (
    for /f "tokens=2*" %%A in ('reg query "HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedhost" /v Path 2^>nul') do (
        if exist "%%~B\dotnet.exe" call :try_host "%%~B\dotnet.exe"
    )
)
if not defined DOTNET_EXE (
    for /f "delims=" %%W in ('where dotnet 2^>nul') do (
        call :try_host "%%~W"
        if defined DOTNET_EXE goto :dotnet_resolved
    )
)
:dotnet_resolved

if not defined DOTNET_EXE (
    echo [ERROR] No usable .NET SDK found ^(host missing or runtime-only^).
    echo   Install .NET 8 SDK from:
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

for %%I in ("!DOTNET_EXE!") do set "DOTNET_ROOT=%%~dpI"
if "!DOTNET_ROOT:~-1!"=="\" set "DOTNET_ROOT=!DOTNET_ROOT:~0,-1!"
set "PATH=!DOTNET_ROOT!;%PATH%"
set "DOTNET_ROOT=!DOTNET_ROOT!"
set "DOTNET_MULTILEVEL_LOOKUP=0"

set "HAS_SDK="
"!DOTNET_EXE!" --list-sdks > "%TEMP%\nextgpu-sdk-echo.txt" 2>nul
for /f "usebackq delims=" %%s in ("%TEMP%\nextgpu-sdk-echo.txt") do (
    set "HAS_SDK=1"
    echo [*] Installed SDK: %%s
)
del "%TEMP%\nextgpu-sdk-echo.txt" <nul >nul 2>&1
if not defined HAS_SDK (
    dir /b /ad "!DOTNET_ROOT!\sdk\*" > "%TEMP%\nextgpu-sdk-dirs.txt" 2>nul
    for /f "usebackq delims=" %%s in ("%TEMP%\nextgpu-sdk-dirs.txt") do (
        set "HAS_SDK=1"
        echo [*] Installed SDK folder: %%s
    )
    del "%TEMP%\nextgpu-sdk-dirs.txt" <nul >nul 2>&1
)
if not defined HAS_SDK (
    echo [ERROR] No .NET SDK installed ^(runtime-only dotnet is not enough^).
    echo   Install .NET 8 SDK.
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

"!DOTNET_EXE!" --version > "%TEMP%\nextgpu-dotnet-ver.txt" 2>nul
set "DOTNET_VER="
for /f "usebackq tokens=*" %%v in ("%TEMP%\nextgpu-dotnet-ver.txt") do set "DOTNET_VER=%%v"
del "%TEMP%\nextgpu-dotnet-ver.txt" <nul >nul 2>&1
echo [*] Using !DOTNET_EXE! ^(!DOTNET_VER!^)
echo.
:: ---------------------------------------------------------------------------
:: 1. Publish NextGPU.App (dashboard)
:: ---------------------------------------------------------------------------
echo ========================================
echo  [1/3] Building NextGPU.App (dashboard)
echo ========================================
echo.

if not exist "publish" mkdir "publish"

:: Remove stale dashboard EXE so we never copy/launch a leftover corrupt binary
if exist "publish\NextGPU.exe" del /f /q "publish\NextGPU.exe" <nul >nul 2>&1
if exist "%REPO_ROOT%\NextGPU.exe" del /f /q "%REPO_ROOT%\NextGPU.exe" <nul >nul 2>&1

"!DOTNET_EXE!" publish NextGPU.App\NextGPU.App.csproj ^
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

if not exist "publish\NextGPU.exe" (
    echo [ERROR] publish\NextGPU.exe was not created.
    exit /b 1
)

call :verify_pe "publish\NextGPU.exe"
if errorlevel 1 (
    echo [ERROR] Published NextGPU.exe is invalid ^(corrupt or too small^).
    echo         Windows would report this as "Unsupported 16-Bit Application".
    exit /b 1
)
for %%A in ("publish\NextGPU.exe") do echo [OK] NextGPU.App -^> apps\NextGPU\publish\NextGPU.exe ^(%%~zA bytes^)

echo [*] Copying to repo root for NextGPU.bat launcher...
copy /y /b "publish\NextGPU.exe" "%REPO_ROOT%\NextGPU.exe" <nul >nul 2>&1
if errorlevel 1 (
    echo [!] Could not copy to repo root; use apps\NextGPU\publish\NextGPU.exe
) else (
    call :verify_pe "%REPO_ROOT%\NextGPU.exe"
    if errorlevel 1 (
        echo [!] Root copy failed PE check; removing bad copy. Use publish\NextGPU.exe
        del /f /q "%REPO_ROOT%\NextGPU.exe" <nul >nul 2>&1
    ) else (
        echo [OK] NextGPU.exe -^> %REPO_ROOT%\NextGPU.exe
    )
)
echo.

:: ---------------------------------------------------------------------------
:: 2. Publish NextGPU.Service (game launcher service)
:: ---------------------------------------------------------------------------
echo ========================================
echo  [2/3] Building NextGPU.Service
echo ========================================
echo.

"!DOTNET_EXE!" publish NextGPU.Service\NextGPU.Service.csproj ^
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
call :verify_pe "publish\Service\NextGPUService.exe"
if errorlevel 1 (
    echo [ERROR] Published NextGPUService.exe is invalid.
    exit /b 1
)
for %%A in ("publish\Service\NextGPUService.exe") do echo [OK] NextGPU.Service -^> apps\NextGPU\publish\Service\NextGPUService.exe ^(%%~zA bytes^)

:: ---------------------------------------------------------------------------
:: 3. Publish NextGPU.Launcher (in-session desktop broker)
:: ---------------------------------------------------------------------------
echo ========================================
echo  [3/3] Building NextGPU.Launcher
echo ========================================
echo.

set "LAUNCHER_INSTALL_DIR=%ProgramFiles%\NextGPU\Launcher"

"!DOTNET_EXE!" publish NextGPU.Launcher\NextGPU.Launcher.csproj ^
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
call :verify_pe "publish\Launcher\NextGPU.Launcher.exe"
if errorlevel 1 (
    echo [ERROR] Published NextGPU.Launcher.exe is invalid.
    exit /b 1
)
for %%A in ("publish\Launcher\NextGPU.Launcher.exe") do echo [OK] NextGPU.Launcher -^> apps\NextGPU\publish\Launcher\NextGPU.Launcher.exe ^(%%~zA bytes^)

:: Install to default location
sc query NextGPUService 2>nul | findstr /i "SERVICE_NAME" <nul >nul 2>&1
if not errorlevel 1 (
    echo [*] Stopping existing NextGPUService...
    sc stop NextGPUService <nul >nul 2>&1
    ping 127.0.0.1 -n 4 -w 1000 <nul >nul 2>&1
)
echo [*] Installing NextGPUService to %SVC_INSTALL_DIR%...
if not exist "%SVC_INSTALL_DIR%" mkdir "%SVC_INSTALL_DIR%"
copy /y /b "publish\Service\NextGPUService.exe" "%SVC_INSTALL_DIR%\NextGPUService.exe" <nul >nul 2>&1
if errorlevel 1 goto :copy_failed
echo [OK] NextGPUService installed to %SVC_INSTALL_DIR%
echo [*] Installing NextGPU.Launcher to %LAUNCHER_INSTALL_DIR%...
if not exist "%LAUNCHER_INSTALL_DIR%" mkdir "%LAUNCHER_INSTALL_DIR%"
copy /y /b "publish\Launcher\NextGPU.Launcher.exe" "%LAUNCHER_INSTALL_DIR%\NextGPU.Launcher.exe" <nul >nul 2>&1
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

:: ---------------------------------------------------------------------------
:: verify_pe: exit 0 if file has MZ header and size >= 1 MiB (self-contained)
:: ---------------------------------------------------------------------------
:verify_pe
set "PE_CHECK=%~1"
powershell -NoProfile -Command ^
  "$p=$env:PE_CHECK; if (-not $p -or -not (Test-Path -LiteralPath $p)) { exit 1 };" ^
  "$len=(Get-Item -LiteralPath $p).Length;" ^
  "if ($len -lt 1MB) { Write-Host ('[!] Too small (' + $len + ' bytes): ' + $p); exit 1 };" ^
  "$fs=[IO.File]::OpenRead($p); $b=New-Object byte[] 2; [void]$fs.Read($b,0,2); $fs.Close();" ^
  "if ($b[0] -ne 0x4D -or $b[1] -ne 0x5A) { Write-Host ('[!] Missing MZ PE header: ' + $p); exit 1 };" ^
  "exit 0"
set "PE_ERR=%ERRORLEVEL%"
set "PE_CHECK="
exit /b %PE_ERR%

:: ---------------------------------------------------------------------------
:try_host
set "TRY_HOST=%~1"
if not defined TRY_HOST goto :eof
if not exist "%TRY_HOST%" goto :eof
for %%I in ("%TRY_HOST%") do set "TRY_ROOT=%%~dpI"
if "%TRY_ROOT:~-1%"=="\" set "TRY_ROOT=%TRY_ROOT:~0,-1%"
set "DOTNET_ROOT=%TRY_ROOT%"
set "DOTNET_MULTILEVEL_LOOKUP=0"
"%TRY_HOST%" --list-sdks > "%TEMP%\nextgpu-sdk-list-build.txt" 2>nul
for /f "usebackq delims=" %%s in ("%TEMP%\nextgpu-sdk-list-build.txt") do (
    set "DOTNET_EXE=%TRY_HOST%"
    del "%TEMP%\nextgpu-sdk-list-build.txt" <nul >nul 2>&1
    goto :eof
)
dir /b /ad "%TRY_ROOT%\sdk\*" > "%TEMP%\nextgpu-sdk-dirs-build.txt" 2>nul
for /f "usebackq delims=" %%s in ("%TEMP%\nextgpu-sdk-dirs-build.txt") do (
    set "DOTNET_EXE=%TRY_HOST%"
    del "%TEMP%\nextgpu-sdk-dirs-build.txt" <nul >nul 2>&1
    goto :eof
)
del "%TEMP%\nextgpu-sdk-list-build.txt" <nul >nul 2>&1
del "%TEMP%\nextgpu-sdk-dirs-build.txt" <nul >nul 2>&1
goto :eof
