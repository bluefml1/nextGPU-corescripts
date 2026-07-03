@echo off
taskkill /f /im steam.exe /t >nul 2>&1
taskkill /f /im steamwebhelper.exe /t >nul 2>&1
del "%ProgramFiles(x86)%\Steam\config\loginusers.vdf" >nul 2>&1
del "%ProgramFiles(x86)%\Steam\config\config.vdf" >nul 2>&1
reg delete "HKEY_CURRENT_USER\Software\Valve\Steam" /v AutoLoginUser /f >nul 2>&1
reg delete "HKEY_CURRENT_USER\Software\Valve\Steam" /v RememberPassword /f >nul 2>&1
echo Steam login cleared. Restart Steam to log in again.
exit