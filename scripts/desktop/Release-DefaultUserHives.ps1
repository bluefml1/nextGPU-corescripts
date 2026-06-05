#Requires -RunAsAdministrator
# Unmount stale Default-profile hives left by wallpaper/shutdown scripts.
. (Join-Path $PSScriptRoot 'DefaultUserHive.ps1')
Release-StaleDefaultUserHives
exit 0
