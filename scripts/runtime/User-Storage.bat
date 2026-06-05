@echo off
setlocal EnableExtensions
title nextGPU User Storage (U:)

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: Setup/Sync need repo folder (Install-*.ps1). Mount/Test use published ProgramData when present.
set "RUN_DIR=%SCRIPT_DIR%"
if /i "%~1"=="Setup" goto :run
if /i "%~1"=="Sync" goto :run
if /i "%~1"=="MountAdmin" goto :run
if exist "%ProgramData%\nextGPU\scripts\runtime\User-Storage.ps1" (
    set "RUN_DIR=%ProgramData%\nextGPU\scripts\runtime"
)
:run

if /i "%~1"=="" (
    echo.
    echo  nextGPU User Storage - one script for setup / test / mount
    echo  Usage: User-Storage.bat [Test^|Status^|Mount^|Open^|Setup^|Sync^|Troubleshoot^|Logs^|Menu^|Help]
    echo  Default: auto ^(Test, or Mount if nextGPU and U: missing^)
    echo.
)

if /i "%~1"=="Setup" goto :run_setup_sync
if /i "%~1"=="Sync" goto :run_setup_sync
goto :run_other
:run_setup_sync
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\User-Storage.ps1" -LaunchDir "%SCRIPT_DIR%" %*
goto :done
:run_other
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%RUN_DIR%\User-Storage.ps1" -LaunchDir "%SCRIPT_DIR%" %*
:done
set "EC=%ERRORLEVEL%"
if /i not "%~1"=="" if /i not "%~1"=="Help" if /i not "%~1"=="Test" if /i not "%~1"=="Logs" pause
exit /b %EC%
