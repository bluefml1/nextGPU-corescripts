@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%GamesApps-Manifest.ps1"
if not exist "%PS_SCRIPT%" (
    echo ERROR: GamesApps-Manifest.ps1 not found at "%PS_SCRIPT%"
    exit /b 1
)

for /f "delims=" %%I in ('powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  ". '%PS_SCRIPT%'; . '%SCRIPT_DIR%Install-GarenaClient.ps1'; $e = Get-ResolvedGarenaClientExePath; if ($e) { Write-Output $e }"') do set "GARENA_EXE=%%I"

if not defined GARENA_EXE (
    echo ERROR: Garena.exe not found. Run Arrange Games/Apps ^(Garena^) first.
    exit /b 1
)

if exist "%SCRIPT_DIR%Start-GarenaAppHelper.ps1" (
    powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Start-GarenaAppHelper.ps1" -Quiet
    if errorlevel 1 echo WARNING: gxxapphelper could not be started.
)

start "" "%GARENA_EXE%"

exit /b 0
