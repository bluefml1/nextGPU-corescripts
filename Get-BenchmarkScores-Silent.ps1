# Silent Benchmark Script - Outputs: CPU_SCORE|GPU_SCORE
# For use in batch scripts - minimal output

$ErrorActionPreference = 'SilentlyContinue'

# Auto-detect CPU
$originalCPU = (Get-CimInstance -ClassName Win32_Processor).Name.Trim()
$cpuName = $originalCPU
$cpuName = $cpuName -replace '11th Gen ', '' -replace '12th Gen ', '' -replace '13th Gen ', '' -replace '14th Gen ', ''
$cpuName = $cpuName -replace '1st Gen ', '' -replace '2nd Gen ', '' -replace '3rd Gen ', '' -replace '4th Gen ', ''
$cpuName = $cpuName -replace '5th Gen ', '' -replace '6th Gen ', '' -replace '7th Gen ', '' -replace '8th Gen ', ''
$cpuName = $cpuName -replace '9th Gen ', '' -replace '10th Gen ', ''
$cpuName = $cpuName -replace '@.*', '' -replace '\(R\)', '' -replace '\(TM\)', ''
$cpuName = $cpuName.Trim() -replace '\s+', ' '

# Fetch CPU benchmark
$cpuUrl = "https://www.cpubenchmark.net/cpu_list.php"
$cpuBenchmark = 0

try {
    $response = Invoke-WebRequest -Uri $cpuUrl -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -UseBasicParsing -TimeoutSec 15
    $pattern = '<tr id="cpu\d+">\s*<td>\s*<a [^>]*?>(?<cpu>[^<]*?' + [regex]::Escape($cpuName) + '[^<]*?)</a>\s*</td>\s*<td>\s*(?<score>[\d,]+)\s*</td>'
    $allMatches = [regex]::Matches($response.Content, $pattern, 'IgnoreCase')
    
    if ($allMatches.Count -gt 0) {
        $bestMatch = $allMatches | Select-Object -First 1
        $cpuBenchmark = [int]($bestMatch.Groups['score'].Value -replace ',', '')
    }
} catch { }

# Auto-detect GPU
$gpuName = Get-CimInstance -ClassName Win32_VideoController | 
    Where-Object { $_.Name -like "*NVIDIA*" } | 
    Select-Object -First 1 -ExpandProperty Name

if (-not $gpuName) {
    $gpuName = Get-CimInstance -ClassName Win32_VideoController | 
        Where-Object { $_.Name -like "*AMD*" -or $_.Name -like "*Radeon*" } | 
        Select-Object -First 1 -ExpandProperty Name
}

if (-not $gpuName) {
    $gpuName = Get-CimInstance -ClassName Win32_VideoController | 
        Where-Object { $_.Name -notlike "*Microsoft*" -and $_.Name -notlike "*Basic*" } | 
        Select-Object -First 1 -ExpandProperty Name
}

$gpuBenchmark = 0

if ($gpuName) {
    $originalGPU = $gpuName.Trim()
    $gpuName = $gpuName -replace 'NVIDIA ', '' -replace 'AMD ', '' -replace 'Intel\(R\) ', ''
    $gpuName = $gpuName -replace 'GeForce ', '' -replace 'Radeon ', ''
    $gpuName = $gpuName -replace '\(TM\)', '' -replace '\(R\)', '' -replace 'Graphics', ''
    $gpuName = $gpuName -replace 'with \d+GB', '' -replace '\d+GB', ''
    $gpuName = $gpuName.Trim() -replace '\s+', ' '

    $gpuUrl = "https://www.videocardbenchmark.net/gpu_list.php"

    try {
        $response = Invoke-WebRequest -Uri $gpuUrl -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" -UseBasicParsing -TimeoutSec 15
        $pattern = '<tr[^>]*>\s*<td[^>]*>\s*<a[^>]*>(?<gpu>[^<]*?' + [regex]::Escape($gpuName) + '[^<]*?)</a>\s*</td>\s*<td[^>]*>\s*(?<score>[\d,]+)\s*</td>'
        $allMatches = [regex]::Matches($response.Content, $pattern, 'IgnoreCase')
        
        if ($allMatches.Count -gt 0) {
            $bestMatch = $allMatches | Select-Object -First 1
            $gpuBenchmark = [int]($bestMatch.Groups['score'].Value -replace ',', '')
        }
    } catch { }
}

# Output format: CPU_SCORE|GPU_SCORE
Write-Output "$cpuBenchmark|$gpuBenchmark"