@echo off
setlocal enabledelayedexpansion
:: Shared Sunshine/Moonlight update entry for checking-update and auto-repair.
:: Requires: SCRIPT_DIR, COMPUTER_NAME (optional for Moonlight config.json substitution)
:: Usage: Run-StreamingStackUpdate.bat [SunshineMode] [MoonlightMode] [ForcePairing]
::   SunshineMode / MoonlightMode: CheckUpdate | ForceReinstall | Skip

set "SS_MODE=%~1"
if "%SS_MODE%"=="" set "SS_MODE=CheckUpdate"
set "ML_MODE=%~2"
if "%ML_MODE%"=="" set "ML_MODE=CheckUpdate"

if not defined SCRIPT_DIR (
    echo [ERROR] SCRIPT_DIR is not set.
    exit /b 1
)

set "STREAMING_STACK_PS1=%SCRIPT_DIR%\scripts\provisioning\Update-NextGpuStreamingStack.ps1"
if not exist "%STREAMING_STACK_PS1%" (
    echo [ERROR] Update-NextGpuStreamingStack.ps1 not found at "%STREAMING_STACK_PS1%"
    exit /b 1
)

set "STACK_ARGS=-SunshineMode %SS_MODE% -MoonlightMode %ML_MODE%"
if /i "%~3"=="ForcePairing" set "STACK_ARGS=%STACK_ARGS% -ForcePairing"

echo.
echo [*] Running shared streaming stack update (Sunshine=%SS_MODE%, Moonlight=%ML_MODE%)...
if defined COMPUTER_NAME (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STREAMING_STACK_PS1%" %STACK_ARGS% -ComputerName "!COMPUTER_NAME!"
) else (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%STREAMING_STACK_PS1%" %STACK_ARGS%
)
exit /b %errorlevel%
