@echo off
REM Hidden elevate helper: WinExe NextGPU.Launcher (no PowerShell window).
setlocal
set "LAUNCHER=%ProgramFiles%\NextGPU\Launcher\NextGPU.Launcher.exe"
if not exist "%LAUNCHER%" (
  echo ERROR: Missing %LAUNCHER%
  exit /b 2
)
"%LAUNCHER%" --play-elevated %*
exit /b %ERRORLEVEL%
