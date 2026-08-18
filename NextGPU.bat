@echo off
setlocal enabledelayedexpansion
:: =============================================================================
:: NextGPU Controller - one-click launcher (repo root)
:: - Auto-installs .NET 8 SDK if missing (winget, then direct offline EXE)
:: - Resolves dotnet via absolute paths (avoids PATH + CMD (x86) paren bugs)
:: - Builds app if needed / if existing EXE is corrupt
:: - Verifies PE (MZ) + minimum size before launch
:: =============================================================================
set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
set "NEXTGPU_REPO_ROOT=%REPO_ROOT%"
set "NEXTGPU_DOTNET="
set "DOTNET_SDK_URL=https://builds.dotnet.microsoft.com/dotnet/Sdk/8.0.423/dotnet-sdk-8.0.423-win-x64.exe"
set "DOTNET_SDK_URL2=https://aka.ms/dotnet/8.0/sdk/win-x64/dotnet-sdk-win-x64.exe"

call :refresh_path

set "EXE="
call :pick_valid_exe
if defined EXE goto :launch

echo.
echo [*] NextGPU Controller not built yet (or existing EXE is invalid).
echo [*] Attempting one-time build...
echo.

call :ensure_dotnet_sdk
if errorlevel 1 exit /b 1

call "%REPO_ROOT%\apps\NextGPU\build-publish.bat"
if errorlevel 1 (
    echo [ERROR] Build failed. See messages above.
    pause
    exit /b 1
)

set "EXE="
call :pick_valid_exe
if not defined EXE (
    echo [ERROR] NextGPU.exe missing or invalid after build.
    echo         Check: %REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe
    pause
    exit /b 1
)

:launch
echo [*] Starting NextGPU Controller...
echo [*] Repo: %REPO_ROOT%
echo [*] Exe:  %EXE%
start "" "%EXE%"
exit /b 0

:: ---------------------------------------------------------------------------
:pick_valid_exe
set "EXE="
if exist "%REPO_ROOT%\NextGPU.exe" (
    call :verify_pe "%REPO_ROOT%\NextGPU.exe"
    if not errorlevel 1 (
        set "EXE=%REPO_ROOT%\NextGPU.exe"
        goto :eof
    )
    echo [!] Invalid/corrupt: %REPO_ROOT%\NextGPU.exe - removing and rebuilding if needed.
    del /f /q "%REPO_ROOT%\NextGPU.exe" <nul >nul 2>&1
)
if exist "%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe" (
    call :verify_pe "%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe"
    if not errorlevel 1 (
        set "EXE=%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe"
        goto :eof
    )
    echo [!] Invalid/corrupt: %REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe - removing.
    del /f /q "%REPO_ROOT%\apps\NextGPU\publish\NextGPU.exe" <nul >nul 2>&1
)
goto :eof

:: ---------------------------------------------------------------------------
:refresh_path
set "PATH_REFRESHED="
for /f "usebackq delims=" %%P in (`powershell -NoProfile -Command "$m=[Environment]::GetEnvironmentVariable('Path','Machine'); $u=[Environment]::GetEnvironmentVariable('Path','User'); if ($m -and $u) { $m + ';' + $u } elseif ($m) { $m } elseif ($u) { $u } else { '' }"`) do (
    if not "%%P"=="" (
        set "PATH=%%P"
        set "PATH_REFRESHED=1"
    )
)
if not defined PATH_REFRESHED echo [!] PATH refresh returned empty; keeping current PATH.

if defined ProgramW6432 set "PATH=%ProgramW6432%\dotnet;%PATH%"
set "PATH=%ProgramFiles%\dotnet;%PATH%"
call :prepend_pf86_dotnet
if exist "%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe" set "PATH=%LOCALAPPDATA%\Microsoft\dotnet;%PATH%"
if exist "%REPO_ROOT%\.dotnet\dotnet.exe" set "PATH=%REPO_ROOT%\.dotnet;%PATH%"
goto :eof

:prepend_pf86_dotnet
set "PF86=%ProgramFiles(x86)%"
if defined PF86 set "PATH=%PF86%\dotnet;%PATH%"
goto :eof

:: ---------------------------------------------------------------------------
:verify_pe
set "PE_CHECK=%~1"
powershell -NoProfile -Command ^
  "$p=$env:PE_CHECK; if (-not $p -or -not (Test-Path -LiteralPath $p)) { exit 1 };" ^
  "$len=(Get-Item -LiteralPath $p).Length;" ^
  "if ($len -lt 1MB) { Write-Host ('[!] Too small (' + $len + ' bytes): ' + $p); exit 1 };" ^
  "$fs=[IO.File]::OpenRead($p); $b=New-Object byte[] 2; [void]$fs.Read($b,0,2); $fs.Close();" ^
  "if ($b[0] -ne 0x4D -or $b[1] -ne 0x5A) { Write-Host ('[!] Missing MZ PE header: ' + $p); exit 1 };" ^
  "exit 0"
set "PE_ERR=%ERRORLEVEL%"
set "PE_CHECK="
exit /b %PE_ERR%

:: ---------------------------------------------------------------------------
:ensure_dotnet_sdk
call :refresh_path
call :resolve_dotnet_sdk
if not errorlevel 1 goto :sdk_ok

echo [*] .NET SDK not found via PATH or known install folders.
call :dump_dotnet_probe

:: System installers (winget / machine EXE) claim success on this host but leave
:: no files under Program Files\dotnet. Prefer a per-repo SDK via Microsoft's
:: official install script — no Program Files write required.
echo [*] Installing .NET 8 SDK into repo-local folder via dotnet-install.ps1...
echo [*] Target: %REPO_ROOT%\.dotnet
call :install_sdk_repo_local
call :refresh_path
call :resolve_dotnet_sdk
if not errorlevel 1 goto :sdk_ok

:: Last ditch: winget + machine installer (rarely helps when package is orphaned)
where winget >nul 2>&1
if not errorlevel 1 (
    echo [*] Repo-local install failed. Trying winget + machine EXE as last resort...
    call :winget_install_sdk_force
    timeout /t 5 /nobreak >nul
    call :install_sdk_direct
    timeout /t 5 /nobreak >nul
    call :refresh_path
    call :resolve_dotnet_sdk
    if not errorlevel 1 goto :sdk_ok
)

echo [ERROR] .NET SDK still not detected after installation.
call :dump_dotnet_probe
echo         Manual fallback:
echo           powershell -NoProfile -ExecutionPolicy Bypass -Command ^
echo             "irm https://dot.net/v1/dotnet-install.ps1 | iex; & ([IO.Path]::Combine($HOME,'.dotnet','dotnet.exe')) --list-sdks"
echo         Or download: https://dotnet.microsoft.com/download/dotnet/8.0
pause
exit /b 1

:sdk_ok
echo [*] .NET SDK detected: !NEXTGPU_DOTNET!
exit /b 0

:: ---------------------------------------------------------------------------
:: install_sdk_repo_local: Microsoft's portable install script into .\.dotnet
:: ---------------------------------------------------------------------------
:install_sdk_repo_local
set "REPO_DOTNET=%REPO_ROOT%\.dotnet"
if not exist "%REPO_DOTNET%" mkdir "%REPO_DOTNET%"
set "DOTNET_INSTALL_PS1=%TEMP%\nextgpu-dotnet-install.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue';" ^
  "$ps1=$env:DOTNET_INSTALL_PS1; $dir=$env:REPO_DOTNET;" ^
  "try {" ^
  "  Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $ps1 -UseBasicParsing;" ^
  "} catch {" ^
  "  Write-Host ('[ERROR] Failed to download dotnet-install.ps1: ' + $_.Exception.Message);" ^
  "  exit 1" ^
  "};" ^
  "Write-Host ('[*] Running: ' + $ps1 + ' -Channel 8.0 -InstallDir ' + $dir);" ^
  "& $ps1 -Channel 8.0 -InstallDir $dir -Verbose;" ^
  "if (-not (Test-Path (Join-Path $dir 'dotnet.exe'))) { Write-Host '[ERROR] dotnet.exe missing after install'; exit 1 };" ^
  "$sdks = & (Join-Path $dir 'dotnet.exe') --list-sdks 2>$null;" ^
  "Write-Host ('[*] Installed SDKs: ' + ($sdks -join '; '));" ^
  "if (-not $sdks) { exit 1 }; exit 0"
exit /b %ERRORLEVEL%

:: ---------------------------------------------------------------------------
:winget_install_sdk
fltmc >nul 2>&1
if errorlevel 1 (
    echo [*] Requesting Administrator privileges to install .NET SDK...
    powershell -NoProfile -Command ^
      "$wg=(Get-Command winget -EA SilentlyContinue).Source; if (-not $wg) { exit 1 };" ^
      "$p=Start-Process -FilePath $wg -Verb RunAs -Wait -PassThru -ArgumentList 'install --id Microsoft.DotNet.SDK.8 --exact --accept-package-agreements --accept-source-agreements --silent --disable-interactivity';" ^
      "if ($null -eq $p) { exit 1 }; exit $p.ExitCode"
) else (
    winget install --id Microsoft.DotNet.SDK.8 --exact --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
)
exit /b 0

:winget_install_sdk_force
fltmc >nul 2>&1
if errorlevel 1 (
    echo [*] Requesting Administrator privileges to force-repair .NET SDK...
    powershell -NoProfile -Command ^
      "$wg=(Get-Command winget -EA SilentlyContinue).Source; if (-not $wg) { exit 1 };" ^
      "$p=Start-Process -FilePath $wg -Verb RunAs -Wait -PassThru -ArgumentList 'install --id Microsoft.DotNet.SDK.8 --exact --force --accept-package-agreements --accept-source-agreements --silent --disable-interactivity';" ^
      "if ($null -eq $p) { exit 1 }; exit $p.ExitCode"
) else (
    winget install --id Microsoft.DotNet.SDK.8 --exact --force --accept-package-agreements --accept-source-agreements --silent --disable-interactivity
)
exit /b 0

:: ---------------------------------------------------------------------------
:: install_sdk_direct: download official EXE and run /install /quiet /norestart
:: ---------------------------------------------------------------------------
:install_sdk_direct
set "SDK_SETUP=%TEMP%\nextgpu-dotnet-sdk-8-win-x64.exe"
echo [*] Download target: %SDK_SETUP%

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ProgressPreference='SilentlyContinue';" ^
  "$urls=@($env:DOTNET_SDK_URL, $env:DOTNET_SDK_URL2);" ^
  "$out=$env:SDK_SETUP;" ^
  "$ok=$false;" ^
  "foreach ($u in $urls) {" ^
  "  if (-not $u) { continue };" ^
  "  try {" ^
  "    Write-Host ('[*] Downloading ' + $u);" ^
  "    Invoke-WebRequest -Uri $u -OutFile $out -UseBasicParsing;" ^
  "    if ((Test-Path $out) -and ((Get-Item $out).Length -gt 10MB)) { $ok=$true; break }" ^
  "  } catch { Write-Host ('[!] Download failed: ' + $_.Exception.Message) }" ^
  "};" ^
  "if (-not $ok) { exit 1 }; exit 0"
if errorlevel 1 (
    echo [ERROR] Could not download .NET SDK installer.
    exit /b 1
)

echo [*] Running SDK installer quietly (may prompt UAC)...
fltmc >nul 2>&1
if errorlevel 1 (
    powershell -NoProfile -Command ^
      "$p=Start-Process -FilePath $env:SDK_SETUP -Verb RunAs -Wait -PassThru -ArgumentList '/install /quiet /norestart';" ^
      "if ($null -eq $p) { exit 1 }; exit $p.ExitCode"
) else (
    "%SDK_SETUP%" /install /quiet /norestart
)
echo [*] Installer exit code: %ERRORLEVEL%
exit /b 0

:: ---------------------------------------------------------------------------
:resolve_dotnet_sdk
set "NEXTGPU_DOTNET="

:: Prefer repo-local portable SDK (works when machine install is broken/orphaned)
call :try_dotnet_host "%REPO_ROOT%\.dotnet\dotnet.exe"
if defined NEXTGPU_DOTNET goto :resolve_dotnet_found

if defined ProgramW6432 call :try_dotnet_host "%ProgramW6432%\dotnet\dotnet.exe"
if defined NEXTGPU_DOTNET goto :resolve_dotnet_found

call :try_dotnet_host "%ProgramFiles%\dotnet\dotnet.exe"
if defined NEXTGPU_DOTNET goto :resolve_dotnet_found

set "PF86=%ProgramFiles(x86)%"
if defined PF86 call :try_dotnet_host "%PF86%\dotnet\dotnet.exe"
if defined NEXTGPU_DOTNET goto :resolve_dotnet_found

call :try_dotnet_host "%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe"
if defined NEXTGPU_DOTNET goto :resolve_dotnet_found

for /f "tokens=2*" %%A in ('reg query "HKLM\SOFTWARE\dotnet\Setup\InstalledVersions\x64\sharedhost" /v Path 2^>nul') do (
    if exist "%%~B\dotnet.exe" call :try_dotnet_host "%%~B\dotnet.exe"
)
if defined NEXTGPU_DOTNET goto :resolve_dotnet_found

for /f "delims=" %%W in ('where dotnet 2^>nul') do (
    call :try_dotnet_host "%%~W"
    if defined NEXTGPU_DOTNET goto :resolve_dotnet_found
)

exit /b 1

:resolve_dotnet_found
for %%I in ("!NEXTGPU_DOTNET!") do set "DOTNET_ROOT=%%~dpI"
if "!DOTNET_ROOT:~-1!"=="\" set "DOTNET_ROOT=!DOTNET_ROOT:~0,-1!"
set "PATH=!DOTNET_ROOT!;%PATH%"
set "DOTNET_ROOT=!DOTNET_ROOT!"
set "DOTNET_MULTILEVEL_LOOKUP=0"
exit /b 0

:: ---------------------------------------------------------------------------
:try_dotnet_host
set "TRY_HOST=%~1"
if not defined TRY_HOST goto :eof
if not exist "%TRY_HOST%" goto :eof

for %%I in ("%TRY_HOST%") do set "TRY_ROOT=%%~dpI"
if "%TRY_ROOT:~-1%"=="\" set "TRY_ROOT=%TRY_ROOT:~0,-1%"

set "DOTNET_ROOT=%TRY_ROOT%"
set "DOTNET_MULTILEVEL_LOOKUP=0"

set "NG_SDK_LIST=%TEMP%\nextgpu-sdk-list.txt"
"%TRY_HOST%" --list-sdks > "%NG_SDK_LIST%" 2>"%TEMP%\nextgpu-sdk-err.txt"
for /f "usebackq delims=" %%s in ("%NG_SDK_LIST%") do (
    set "NEXTGPU_DOTNET=%TRY_HOST%"
    del "%NG_SDK_LIST%" <nul >nul 2>&1
    goto :eof
)

dir /b /ad "%TRY_ROOT%\sdk\*" > "%TEMP%\nextgpu-sdk-dirs.txt" 2>nul
for /f "usebackq delims=" %%s in ("%TEMP%\nextgpu-sdk-dirs.txt") do (
    echo [!] --list-sdks empty but found sdk folder: %%s
    set "NEXTGPU_DOTNET=%TRY_HOST%"
    del "%TEMP%\nextgpu-sdk-dirs.txt" <nul >nul 2>&1
    goto :eof
)
del "%NG_SDK_LIST%" <nul >nul 2>&1
del "%TEMP%\nextgpu-sdk-dirs.txt" <nul >nul 2>&1
goto :eof

:: ---------------------------------------------------------------------------
:: dump_dotnet_probe — NO nested ( ... path-with-(x86) ... ) blocks
:: ---------------------------------------------------------------------------
:dump_dotnet_probe
echo [*] Dotnet probe diagnostics:
if exist "%REPO_ROOT%\.dotnet\dotnet.exe" echo     OK  %REPO_ROOT%\.dotnet\dotnet.exe
if not exist "%REPO_ROOT%\.dotnet\dotnet.exe" echo     --  %REPO_ROOT%\.dotnet\dotnet.exe
if defined ProgramW6432 goto :dump_w6432
echo     --  ProgramW6432 unset
goto :dump_pf
:dump_w6432
if exist "%ProgramW6432%\dotnet\dotnet.exe" echo     OK  %ProgramW6432%\dotnet\dotnet.exe
if not exist "%ProgramW6432%\dotnet\dotnet.exe" echo     --  %ProgramW6432%\dotnet\dotnet.exe
:dump_pf
if exist "%ProgramFiles%\dotnet\dotnet.exe" echo     OK  %ProgramFiles%\dotnet\dotnet.exe
if not exist "%ProgramFiles%\dotnet\dotnet.exe" echo     --  %ProgramFiles%\dotnet\dotnet.exe

set "PF86=%ProgramFiles(x86)%"
if not defined PF86 goto :dump_local
if exist "!PF86!\dotnet\dotnet.exe" echo     OK  !PF86!\dotnet\dotnet.exe
if not exist "!PF86!\dotnet\dotnet.exe" echo     --  !PF86!\dotnet\dotnet.exe

:dump_local
if exist "%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe" echo     OK  %LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe
if not exist "%LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe" echo     --  %LOCALAPPDATA%\Microsoft\dotnet\dotnet.exe
echo     where.exe:
where dotnet 2>nul
if exist "%REPO_ROOT%\.dotnet\sdk" (
    echo     sdk folders under %REPO_ROOT%\.dotnet\sdk:
    dir /b /ad "%REPO_ROOT%\.dotnet\sdk" 2>nul
)
if exist "%ProgramFiles%\dotnet\sdk" (
    echo     sdk folders under %ProgramFiles%\dotnet\sdk:
    dir /b /ad "%ProgramFiles%\dotnet\sdk" 2>nul
)
if defined ProgramW6432 if exist "%ProgramW6432%\dotnet\sdk" (
    echo     sdk folders under %ProgramW6432%\dotnet\sdk:
    dir /b /ad "%ProgramW6432%\dotnet\sdk" 2>nul
)
goto :eof
