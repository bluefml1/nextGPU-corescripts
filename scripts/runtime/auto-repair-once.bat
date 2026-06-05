@echo off
:: Single auto-repair cycle (for NextGPU Controller). Does not loop forever.
call "%~dp0auto-repair.bat" once %*
exit /b %errorlevel%
