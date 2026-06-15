@echo off
:: Single auto-repair cycle (for NextGPU Controller).
call "%~dp0auto-repair.bat" %*
exit /b %errorlevel%
