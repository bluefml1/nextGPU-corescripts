@echo off
taskkill /f /im EpicGamesLauncher.exe /t >nul 2>&1
taskkill /f /im EpicWebHelper.exe /t >nul 2>&1
taskkill /f /im EpicGamesLauncherWebHelper.exe /t >nul 2>&1
rmdir /s /q "%localappdata%\EpicGamesLauncher\Saved" >nul 2>&1
reg delete "HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "EpicGamesLauncher" /f >nul 2>&1
reg delete "HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Epic Games\EpicGamesLauncher" /f >nul 2>&1
reg delete "HKEY_CURRENT_USER\Software\Epic Games\Unreal Engine\Builds" /f >nul 2>&1
stop
