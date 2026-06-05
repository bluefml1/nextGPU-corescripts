@echo off
setlocal enabledelayedexpansion
:: Build self-contained NextGPU.exe (no .NET install required on target machines).
cd /d "%~dp0"

set "REPO_ROOT=%~dp0..\.."
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

echo ========================================
echo  NextGPU Controller - Build and Publish
echo ========================================
echo.

where dotnet >nul 2>&1
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
    echo   Install .NET 8 SDK, or copy a pre-built NextGPU.exe to the repo root.
    echo   https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

for /f "tokens=*" %%v in ('dotnet --version 2^>nul') do set "DOTNET_VER=%%v"
echo [*] Using dotnet !DOTNET_VER!

if not exist "publish" mkdir "publish"

echo [*] Publishing win-x64 self-contained single-file...
dotnet publish NextGPU.App\NextGPU.App.csproj ^
    -c Release ^
    -r win-x64 ^
    --self-contained true ^
    -p:PublishSingleFile=true ^
    -p:IncludeNativeLibrariesForSelfExtract=true ^
    -p:EnableCompressionInSingleFile=true ^
    -o publish

if errorlevel 1 (
    echo [ERROR] dotnet publish failed.
    exit /b 1
)

if not exist "publish\NextGPU.exe" (
    echo [ERROR] publish\NextGPU.exe was not created.
    exit /b 1
)

echo [*] Copying to repo root for NextGPU.bat launcher...
copy /y "publish\NextGPU.exe" "%REPO_ROOT%\NextGPU.exe" >nul
if errorlevel 1 (
    echo [!] Could not copy to repo root; use apps\NextGPU\publish\NextGPU.exe
) else (
    echo [*] Installed: %REPO_ROOT%\NextGPU.exe
)

echo.
echo ========================================
echo  Build complete
echo ========================================
echo   Run:  %REPO_ROOT%\NextGPU.bat
echo   Or:   %REPO_ROOT%\NextGPU.exe
echo   Login: bluefml1 / letmeinpls
echo ========================================
exit /b 0
