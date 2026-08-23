#Requires -Version 5.1
<#
    Wrapper so PlayNiteWatcher\Export-SunshineFromPlaynite.ps1 and export\
    share one implementation (Steam = steam.exe -applaunch, no Playnite --start).
#>
. (Join-Path $PSScriptRoot "export\SunshineExport-Core.ps1")
