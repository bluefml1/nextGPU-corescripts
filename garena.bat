@echo off

start "" "Z:\Garena\Garena\Garena.exe"

powershell -WindowStyle Hidden -Command ^
"Unblock-File 'Z:\Garena\Garena\Garena platform service.lnk'; ^
Start-Process 'Z:\Garena\Garena\Garena platform service.lnk' -WindowStyle Hidden"

exit