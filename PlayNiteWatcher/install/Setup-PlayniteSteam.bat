@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-PlayniteSteam.ps1" -PickInstallFolder -WithSunshine %*
if errorlevel 1 pause
