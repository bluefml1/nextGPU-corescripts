@echo off
setlocal enabledelayedexpansion

REM Recursively find and process .zip and .rar files
set "SCRIPT_IMPL_DIR=%~dp0"
if "%SCRIPT_IMPL_DIR:~-1%"=="\" set "SCRIPT_IMPL_DIR=%SCRIPT_IMPL_DIR:~0,-1%"
if defined NEXTGPU_REPO_ROOT (
    set "SCRIPT_DIR=%NEXTGPU_REPO_ROOT%"
) else (
    for %%I in ("%SCRIPT_IMPL_DIR%\..\..") do set "SCRIPT_DIR=%%~fI"
)

for /R "%SCRIPT_DIR%" %%F in (*.zip *.rar) do (
    echo Processing: "%%F"
    "C:\Program Files\7-Zip\7z.exe" x -y "%%F" -o"%%~dpF" > nul
    if !errorlevel! equ 0 (
        echo Successfully extracted: "%%F"
        REM Delete main archive and related parts (e.g., .r00, .r01, etc.)
        del "%%F" > nul 2>&1
        for %%E in ("%%~dpnF".r??) do if exist "%%E" del "%%E" > nul
        echo Deleted: "%%F" and related parts
    ) else (
        echo FAILED to extract: "%%F"
    )
)
echo.
echo Processing complete.
pause