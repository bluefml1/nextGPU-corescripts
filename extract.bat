@echo off
setlocal enabledelayedexpansion

REM Recursively find and process .zip and .rar files
for /R %%F in (*.zip *.rar) do (
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