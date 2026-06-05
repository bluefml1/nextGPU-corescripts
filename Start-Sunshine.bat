@echo off
setlocal
set "NEXTGPU_REPO_ROOT=%~dp0"
if "%NEXTGPU_REPO_ROOT:~-1%"=="\" set "NEXTGPU_REPO_ROOT=%NEXTGPU_REPO_ROOT:~0,-1%"
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%NEXTGPU_REPO_ROOT%\scripts\provisioning\Start-Sunshine-InSession.ps1"
exit /b %errorlevel%
