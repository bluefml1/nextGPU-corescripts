@echo off
setlocal
:: Build controller, copy to repo root, create Desktop shortcut.
cd /d "%~dp0"
set "REPO_ROOT=%~dp0..\.."
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

call "%~dp0build-publish.bat"
if errorlevel 1 exit /b 1

set "EXE=%REPO_ROOT%\NextGPU.exe"
if not exist "%EXE%" set "EXE=%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe"

echo [*] Creating Desktop shortcut...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ws=New-Object -ComObject WScript.Shell; $s=$ws.CreateShortcut([Environment]::GetFolderPath('Desktop')+'\NextGPU.lnk'); $s.TargetPath='%EXE%'; $s.WorkingDirectory='%REPO_ROOT%'; $s.Description='nextGPU host controller'; $s.Save()"

echo [*] Done. Use Desktop shortcut or double-click %REPO_ROOT%\NextGPU.bat
exit /b 0
