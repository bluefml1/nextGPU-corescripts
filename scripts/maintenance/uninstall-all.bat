@echo off
setlocal enabledelayedexpansion

:: nextGPU full local uninstaller wrapper.
:: Preview without changes:
::   uninstall-all.bat whatif
:: Run without prompt:
::   uninstall-all.bat force
:: Keep local users nextGPU / NextGPU-Admin:
::   uninstall-all.bat force keepusers

set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)
set "PS1=%SCRIPT_DIR%\scripts\maintenance\Uninstall-NextGPU.ps1"

if not exist "%PS1%" (
    echo ERROR: Uninstall-NextGPU.ps1 not found in:
    echo %SCRIPT_DIR%
    exit /b 1
)

set "PS_ARGS="

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="force" set "PS_ARGS=!PS_ARGS! -Force"
if /i "%~1"=="whatif" set "PS_ARGS=!PS_ARGS! -WhatIf"
if /i "%~1"=="skipdrivers" set "PS_ARGS=!PS_ARGS! -SkipDrivers"
if /i "%~1"=="skipfiles" set "PS_ARGS=!PS_ARGS! -SkipGeneratedFiles"
if /i "%~1"=="keepusers" set "PS_ARGS=!PS_ARGS! -KeepLocalUsers"
shift /1
goto parse_args

:args_done

set "NEXTGPU_REPO_ROOT=%SCRIPT_DIR%"
set "PS_ARGS=!PS_ARGS! -RepoRoot ""%SCRIPT_DIR%"""

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator privileges for nextGPU uninstall...
    set "ELEVATED_ARGS=-NoProfile -ExecutionPolicy Bypass -File ""%PS1%""!PS_ARGS!"
    powershell -NoProfile -Command "$p=Start-Process powershell.exe -Verb RunAs -WindowStyle Normal -Wait -PassThru -ArgumentList '%ELEVATED_ARGS%'; exit $p.ExitCode"
    exit /b !errorlevel!
)

echo ========================================
echo nextGPU Full Local Uninstaller
echo ========================================
echo.
echo This removes local services, Sunshine/Moonlight/cloudflared, drivers
echo (VDD/VAD/VB-CABLE - reboot if they still appear in Device Manager),
echo scheduled tasks (including nextGPU-*), wallpaper/shutdown policy,
echo CLOUDFLARE_TUNNEL_TOKEN, local users nextGPU and NextGPU-Admin, and generated logs.
echo It does not delete Cloudflare DNS/tunnel resources from your account.
echo It does not remove the NextGPU-Authority admin account or this script folder.
echo.

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PS_ARGS%
set "ERR=!errorlevel!"
echo.
if !ERR! equ 0 (
    echo [*] Uninstall completed. Reboot is recommended, especially if VDD/VAD were installed.
) else (
    echo [!] Uninstall exited with code !ERR!.
)
echo.
pause
exit /b !ERR!

