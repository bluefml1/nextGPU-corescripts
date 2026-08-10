#Requires -RunAsAdministrator
param(
    [int]$AppID         = 1746050434,
    [string]$PipeName   = "NextGPUControl",
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"

# ── Helpers ────────────────────────────────────────────────────────────────────

function Get-ConsoleSessionId {
    $sig = @'
        [DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();
'@
    Add-Type -MemberDefinition $sig -Name Win32Session -Namespace Test -PassThru | Out-Null
    return [Test.Win32Session]::WTSGetActiveConsoleSessionId()
}

function Get-TokenSessionId {
    param([int]$ProcessId)
    $sig = @'
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
        [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr hObject);
        [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
        [DllImport("advapi32.dll", SetLastError=true)] public static extern bool GetTokenInformation(IntPtr TokenHandle, uint TokenInformationClass,
            IntPtr TokenInformation, uint TokenInformationLength, out uint ReturnLength);
        public const uint TOKEN_QUERY = 0x0008;
        public const uint TokenSession = 12;
'@
    Add-Type -MemberDefinition $sig -Name Win32Token -Namespace Test -PassThru | Out-Null
    $hProcess = [Test.Win32Token]::OpenProcess(0x0400, $false, $ProcessId)
    if ($hProcess -eq [IntPtr]::Zero) { return $null }
    try {
        $hToken = [IntPtr]::Zero
        if (-not [Test.Win32Token]::OpenProcessToken($hProcess, [Test.Win32Token]::TOKEN_QUERY, [ref]$hToken)) {
            return $null
        }
        try {
            $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
            try {
                $ok = [Test.Win32Token]::GetTokenInformation(
                    $hToken, [Test.Win32Token]::TokenSession, $buf, 4, [ref]$null)
                if ($ok) {
                    return [Runtime.InteropServices.Marshal]::ReadInt32($buf)
                }
                return $null
            } finally {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($buf)
            }
        } finally {
            [Test.Win32Token]::CloseHandle($hToken) | Out-Null
        }
    } finally {
        [Test.Win32Token]::CloseHandle($hProcess) | Out-Null
    }
}

function Get-ProcessUser {
    param([int]$ProcessId)
    try {
        $proc = Get-Process -Id $ProcessId -ErrorAction Stop
        $owner = $proc.GetOwner()
        return "$($owner.Domain)\$($owner.User)"
    } catch {
        return $null
    }
}

function Get-ConsoleUsername {
    $sessionId = Get-ConsoleSessionId
    $sig = @'
        [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSQuerySessionInformation(
            IntPtr hServer, uint SessionId, uint WTSInfoClass, out IntPtr ppBuffer, out uint pBytesReturned);
        [DllImport("wtsapi32.dll")] public static extern void WTSFreeMemory(IntPtr pMemory);
        public const uint WTSUserName = 5;
        public const uint WTSDomainName = 7;
        public const uint WTS_CURRENT_SERVER_HANDLE = 0;
'@
    Add-Type -MemberDefinition $sig -Name WtsSession -Namespace Test -PassThru | Out-Null

    $domainPtr = [IntPtr]::Zero; $domainLen = 0
    $ok = [Test.WtsSession]::WTSQuerySessionInformation(
        [Test.WtsSession]::WTS_CURRENT_SERVER_HANDLE,
        $sessionId,
        [Test.WtsSession]::WTSDomainName,
        [ref]$domainPtr,
        [ref]$domainLen)
    try {
        $domain = if ($ok -and $domainLen -gt 0) {
            [Runtime.InteropServices.Marshal]::PtrToStringUni($domainPtr, $domainLen / 2)
        } else { "" }
    } finally {
        if ($domainPtr -ne [IntPtr]::Zero) { [Test.WtsSession]::WTSFreeMemory($domainPtr) }
    }

    $userPtr = [IntPtr]::Zero; $userLen = 0
    $ok = [Test.WtsSession]::WTSQuerySessionInformation(
        [Test.WtsSession]::WTS_CURRENT_SERVER_HANDLE,
        $sessionId,
        [Test.WtsSession]::WTSUserName,
        [ref]$userPtr,
        [ref]$userLen)
    try {
        $user = if ($ok -and $userLen -gt 0) {
            [Runtime.InteropServices.Marshal]::PtrToStringUni($userPtr, $userLen / 2)
        } else { "" }
    } finally {
        if ($userPtr -ne [IntPtr]::Zero) { [Test.WtsSession]::WTSFreeMemory($userPtr) }
    }

    if ($user) { return "$domain\$user" } else { return $null }
}

function Connect-NextGPipe {
    param([string]$Name)
    $pipe = New-Object IO.Pipes.NamedPipeClientStream(
        ".", $Name, [IO.Pipes.PipeDirection]::InOut,
        [IO.Pipes.PipeOptions]::None,
        [Security.Principal.TokenImpersonationLevel]::Impersonation)
    $pipe.Connect(5000)
    return $pipe
}

function Read-JsonMessage {
    param([IO.Pipes.NamedPipeClientStream]$Pipe)
    $lenBuf = New-Object byte[] 4
    $read = $Pipe.Read($lenBuf, 0, 4)
    if ($read -lt 4) { throw "Short read on length" }
    $len = [BitConverter]::ToUInt32($lenBuf, 0)
    $buf = New-Object byte[] $len
    $total = 0
    while ($total -lt $len) {
        $r = $Pipe.Read($buf, $total, $len - $total)
        if ($r -eq 0) { throw "Pipe closed" }
        $total += $r
    }
    $json = [Text.Encoding]::UTF8.GetString($buf, 0, $len)
    return $json | ConvertFrom-Json
}

# ── Preamble ───────────────────────────────────────────────────────────────────

$consoleSessionId = Get-ConsoleSessionId
$consoleUsername  = Get-ConsoleUsername

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  NextGPU Elevated Launch - E2E Test" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host ("  Console session : $consoleSessionId")
Write-Host ("  Console user    : $consoleUsername")
Write-Host ("  AppID           : $AppID")
Write-Host ("  Pipe           : \\.\pipe\$PipeName")
Write-Host ("  Timeout        : $TimeoutSeconds s")
Write-Host ""

# ── Connect & send ─────────────────────────────────────────────────────────────

Write-Host "[TEST] Connecting to pipe..." -ForegroundColor Yellow
try {
    $pipe = Connect-NextGPipe $PipeName
    Write-Host "[TEST] Pipe connected OK." -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Could not connect to pipe: $_" -ForegroundColor Red
    Write-Host "  Is NextGPUService running?" -ForegroundColor Red
    exit 1
}

Write-Host ("[TEST] Sending launch-elevated request (appID=$AppID)...") -ForegroundColor Yellow
$request = @{
    version = 1
    op      = "launch-elevated"
    appID   = $AppID
    args    = ""
    workingDir = ""
}
$jsonBytes = [Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Compress))
$lenBytes  = [BitConverter]::GetBytes([uint32]$jsonBytes.Length)

try {
    $pipe.Write($lenBytes, 0, 4)
    $pipe.Write($jsonBytes, 0, $jsonBytes.Length)
    $pipe.WaitForPipeDrain()
    $response = Read-JsonMessage $pipe
    $pipe.Close()
} catch {
    Write-Host "[FAIL] Launch request failed: $_" -ForegroundColor Red
    $pipe.Dispose()
    exit 1
}

$responseJson = $response | ConvertTo-Json -Compress
Write-Host ("[TEST] Response: $responseJson") -ForegroundColor Cyan

# ── Checks ─────────────────────────────────────────────────────────────────────

$passed = 0
$failed = 0

function Check($cond, $label) {
    if ($cond) {
        Write-Host "  [PASS] $label" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  [FAIL] $label" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host ""
Write-Host "[EVALUATE] Response checks:" -ForegroundColor Yellow
Check ($response.Ok -eq $true)        "response.Ok == true"
Check ($response.Pid -gt 0)           "response.Pid > 0  (pid=$($response.Pid))"

if (-not $response.Ok) {
    Write-Host ""
    Write-Host ("[FAIL] Launch failed: $($response.Error)") -ForegroundColor Red
    Write-Host "  Log: C:\ProgramData\nextGPU\logs\NextGPUService.log" -ForegroundColor Red
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ("  RESULT: $passed passed, $failed failed") -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit 1
}

$returnedPid = $response.Pid

Write-Host ""
Write-Host "[TEST] Waiting 3s for process $returnedPid to initialise..." -ForegroundColor Yellow
Start-Sleep -Seconds 3

Write-Host ""
Write-Host "[EVALUATE] Process $returnedPid checks:" -ForegroundColor Yellow

$proc = Get-Process -Id $returnedPid -ErrorAction SilentlyContinue
Check ($null -ne $proc)           "Process $returnedPid exists"

if ($null -eq $proc) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ("  RESULT: $passed passed, $failed failed") -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    exit 1
}

$procSession = Get-TokenSessionId -ProcessId $returnedPid
$procUser    = Get-ProcessUser    -ProcessId $returnedPid
Write-Host ("  Process session : $procSession  (console: $consoleSessionId)") -ForegroundColor Cyan
Write-Host ("  Process user    : $procUser") -ForegroundColor Cyan

Check ($procSession -eq $consoleSessionId)  "Process in console session ($procSession == $consoleSessionId)"
if ($consoleUsername -and $procUser) {
    Check ($procUser -eq $consoleUsername)  "Process as console user ($procUser == $consoleUsername)"
} else {
    Write-Host ("  [INFO] Console username unavailable - skipping user check (session={0}, procSession={1})" -f $consoleSessionId, $procSession) -ForegroundColor Cyan
}

# ── Window visibility ────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "[TEST] Waiting up to $TimeoutSeconds s for window to appear..." -ForegroundColor Yellow
$sw = [Diagnostics.Stopwatch]::StartNew()
$windowVisible = $false
$windowTitle   = ""

while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    try {
        $p = Get-Process -Id $returnedPid -ErrorAction SilentlyContinue
        if ($null -ne $p -and $p.MainWindowHandle -ne [IntPtr]::Zero) {
            $title = $p.MainWindowTitle
            if (-not [string]::IsNullOrEmpty($title)) {
                $windowVisible = $true
                $windowTitle   = $title
                break
            }
        }
    } catch { }
    Start-Sleep -Milliseconds 500
}

Write-Host ""
Write-Host "[EVALUATE] Window visibility:" -ForegroundColor Yellow
Check $windowVisible  "Window visible within ${TimeoutSeconds}s ($windowTitle)"
if ($windowTitle) { Write-Host ("  Title: $windowTitle") -ForegroundColor Cyan }

# ── Cleanup ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("[TEST] Closing test process $returnedPid...") -ForegroundColor Yellow
try {
    Stop-Process -Id $returnedPid -Force -ErrorAction SilentlyContinue
    Write-Host "[TEST] Process closed." -ForegroundColor Green
} catch {
    Write-Host "[WARN] Could not stop process: $_" -ForegroundColor DarkYellow
}

# ── Summary ───────────────────────────────────────────────────────────────────

$color = if ($failed -eq 0) { "Green" } else { "Red" }
Write-Host ""
Write-Host "========================================" -ForegroundColor $color
Write-Host ("  RESULT: $passed passed, $failed failed") -ForegroundColor $color
if ($failed -eq 0) {
    Write-Host "  Elevated launch pipeline is working correctly." -ForegroundColor Green
} else {
    Write-Host "  Some checks failed." -ForegroundColor Red
    Write-Host "  Log: Get-Content C:\ProgramData\nextGPU\logs\NextGPUService.log -Tail 40" -ForegroundColor Red
}
Write-Host "========================================" -ForegroundColor $color

exit $failed
