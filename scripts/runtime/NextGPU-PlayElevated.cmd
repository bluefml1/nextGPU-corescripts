@echo off
REM Playnite File play-action helper: elevates via NextGPUService.
setlocal
set "SCRIPT=%ProgramData%\nextGPU\scripts\NextGPU-PlayElevated.ps1"
if not exist "%SCRIPT%" (
  echo ERROR: Missing %SCRIPT%
  exit /b 2
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
