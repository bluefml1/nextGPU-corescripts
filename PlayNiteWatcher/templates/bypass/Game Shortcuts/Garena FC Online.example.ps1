# Example composite launcher - regenerate via Review and Sync when Helper is set
param([int]$HelperDelaySec = 2)
$helper = 'Z:\Garena\Garena\Garena.exe'
$shortcut = 'Z:\Game Shortcuts\Garena FC Online.lnk'
if ($helper -and (Test-Path -LiteralPath $helper)) {
    Start-Process -FilePath $helper -WindowStyle Hidden
    Start-Sleep -Seconds $HelperDelaySec
}
if ($shortcut -and (Test-Path -LiteralPath $shortcut)) {
    Start-Process -FilePath $shortcut
}
else {
    throw "Shortcut not found: $shortcut"
}
