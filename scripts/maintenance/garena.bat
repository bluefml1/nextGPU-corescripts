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

start "" "%GARENA_EXE%"

for %%D in ("%GARENA_EXE%") do set "GARENA_DIR=%%~dpD"
powershell -WindowStyle Hidden -Command ^
"Unblock-File '%GARENA_DIR%Garena platform service.lnk' -ErrorAction SilentlyContinue; ^
 Start-Process '%GARENA_DIR%Garena platform service.lnk' -WindowStyle Hidden -ErrorAction SilentlyContinue"

exit /b 0
