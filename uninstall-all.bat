@echo off
setlocal

set "NEXTGPU_REPO_ROOT=%~dp0"
if "%NEXTGPU_REPO_ROOT:~-1%"=="\" set "NEXTGPU_REPO_ROOT=%NEXTGPU_REPO_ROOT:~0,-1%"

pushd "%NEXTGPU_REPO_ROOT%"
call "%NEXTGPU_REPO_ROOT%\scripts\maintenance\uninstall-all.bat" %*
set "NEXTGPU_EXIT=%errorlevel%"
popd
exit /b %NEXTGPU_EXIT%
