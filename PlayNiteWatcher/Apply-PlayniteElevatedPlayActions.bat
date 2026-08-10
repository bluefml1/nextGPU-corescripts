@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Apply-PlayniteElevatedPlayActions.ps1" %*
exit /b %ERRORLEVEL%
