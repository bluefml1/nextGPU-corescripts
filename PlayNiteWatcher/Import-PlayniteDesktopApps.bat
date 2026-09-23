@echo off
cd /d "%~dp0"
set "PS1=%~dp0Import-PlayniteDesktopApps.ps1"
if not exist "%PS1%" (
    echo ERROR: Import-PlayniteDesktopApps.ps1 not found at "%PS1%"
    pause
    exit /b 1
)
for %%A in ("%PS1%") do if %%~zA==0 (
    echo ERROR: Import-PlayniteDesktopApps.ps1 is empty. Restore it from PlayNiteWatcher\import\ or git history.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
    echo.
    echo Import failed with exit code %ERR%.
    pause
    exit /b %ERR%
)
