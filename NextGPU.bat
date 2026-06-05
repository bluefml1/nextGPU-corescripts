@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: NextGPU Controller - one-click launcher (repo root)
:: - Auto-installs .NET 8 SDK if missing (winget)
:: - Builds app if needed
:: - Starts NextGPU.exe
:: =============================================================================
set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
set "NEXTGPU_REPO_ROOT=%REPO_ROOT%"

set "EXE=%REPO_ROOT%\NextGPU.exe"
if exist "%EXE%" goto :launch

set "EXE=%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe"
if exist "%EXE%" goto :launch

echo.
echo [*] NextGPU Controller not built yet on this machine.
echo [*] Attempting one-time build...
echo.

call :ensure_dotnet_sdk
if errorlevel 1 exit /b 1

call "%REPO_ROOT%\apps\NextGPU\build-publish.bat"
if errorlevel 1 (
    echo [ERROR] Build failed. See messages above.
    pause
    exit /b 1
)

set "EXE=%REPO_ROOT%\NextGPU.exe"
if not exist "%EXE%" set "EXE=%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe"
if not exist "%EXE%" (
    echo [ERROR] NextGPU.exe still missing after build.
    pause
    exit /b 1
)

:launch
echo [*] Starting NextGPU Controller...
echo [*] Repo: %REPO_ROOT%
start "" "%EXE%"
exit /b 0

:ensure_dotnet_sdk
set "HAS_DOTNET_HOST="
set "HAS_DOTNET_SDK="

where dotnet >nul 2>&1
if not errorlevel 1 set "HAS_DOTNET_HOST=1"

if defined HAS_DOTNET_HOST (
    for /f "delims=" %%s in ('dotnet --list-sdks 2^>nul') do (
        set "HAS_DOTNET_SDK=1"
        goto :sdk_ok
    )
)

echo [*] .NET SDK not found. Installing .NET 8 SDK automatically...
where winget >nul 2>&1
if errorlevel 1 (
    echo [ERROR] winget not found, cannot auto-install .NET SDK.
    echo Install .NET 8 SDK manually:
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    pause
    exit /b 1
)

fltmc >nul 2>&1
if errorlevel 1 (
    echo [*] Requesting Administrator privileges to install .NET SDK...
    powershell -NoProfile -Command "Start-Process cmd.exe -Verb RunAs -ArgumentList '/c winget install --id Microsoft.DotNet.SDK.8 --exact --accept-package-agreements --accept-source-agreements --silent'"
) else (
    winget install --id Microsoft.DotNet.SDK.8 --exact --accept-package-agreements --accept-source-agreements --silent
)

if errorlevel 1 (
    echo [ERROR] Failed to install Microsoft.DotNet.SDK.8 via winget.
    echo Please install manually from:
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    pause
    exit /b 1
)

echo [*] Verifying .NET SDK install...
for /f "delims=" %%s in ('dotnet --list-sdks 2^>nul') do (
    set "HAS_DOTNET_SDK=1"
    goto :sdk_ok
)
echo [ERROR] .NET SDK still not detected after installation.
echo Please restart terminal and try again.
pause
exit /b 1

:sdk_ok
echo [*] .NET SDK detected.
exit /b 0
