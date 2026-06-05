# Measures realistic SMB latency for small-file sequential access

param(
    [string]$SharePath    = "",
    [int]   $SampleFiles  = 500,       # files to test against
    [int]   $ReadBytes    = 8192,      # bytes to read per file
    [string]$OutputCsv    = "smb_latency_$(hostname)_$(Get-Date -f yyyyMMddHHmm).csv"
)

Write-Host "Discovering files in $SharePath..."
$files = Get-ChildItem -Path $SharePath -Recurse -File -ErrorAction SilentlyContinue |
         Select-Object -First $SampleFiles

if ($files.Count -eq 0) {
    Write-Error "No files found at $SharePath"
    exit 1
}

Write-Host "Testing $($files.Count) files from $(hostname). This may take a few minutes..."

$results = foreach ($file in $files) {

    # --- Round trip 1: directory entry / attribute fetch (FindFirstFile equivalent)
    $t1 = [System.Diagnostics.Stopwatch]::StartNew()
    $info = Get-Item -Path $file.FullName -ErrorAction SilentlyContinue
    $t1.Stop()
    $attrMs = $t1.Elapsed.TotalMilliseconds

    # --- Round trips 2-4: open, read signature bytes, close
    $t2 = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $stream = [System.IO.File]::OpenRead($file.FullName)
        $buffer = New-Object byte[] $ReadBytes
        $stream.Read($buffer, 0, [Math]::Min($ReadBytes, $stream.Length)) | Out-Null
        $stream.Close()
        $readOk = $true
    } catch {
        $readOk = $false
    }
    $t2.Stop()
    $readMs = $t2.Elapsed.TotalMilliseconds

    # --- Total per-file cost
    $totalMs = $attrMs + $readMs

    [PSCustomObject]@{
        FileName      = $file.Name
        FileSizeBytes = $file.Length
        AttrFetchMs   = [math]::Round($attrMs, 2)
        OpenReadCloseMs = [math]::Round($readMs, 2)
        TotalPerFileMs  = [math]::Round($totalMs, 2)
        ReadOk          = $readOk
        TestedFrom      = hostname
        SharePath       = $SharePath
        Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }
}

# Summary stats
$times    = $results | Where-Object {$_.ReadOk} | Select-Object -ExpandProperty TotalPerFileMs
$avgMs    = [math]::Round(($times | Measure-Object -Average).Average, 2)
$medianMs = [math]::Round(($times | Sort-Object)[[math]::Floor($times.Count/2)], 2)
$p95Ms    = [math]::Round(($times | Sort-Object)[[math]::Floor($times.Count * 0.95)], 2)
$maxMs    = [math]::Round(($times | Measure-Object -Maximum).Maximum, 2)
$errorCt  = ($results | Where-Object {-not $_.ReadOk}).Count

$projectedSeconds = ($avgMs / 1000) * 10000
$projectedMins    = [math]::Round($projectedSeconds / 60, 1)

Write-Host ""
Write-Host "===== Results from $(hostname) =====" -ForegroundColor Cyan
Write-Host "Files tested   : $($results.Count)"
Write-Host "Errors         : $errorCt"
Write-Host "Avg per file   : $avgMs ms"
Write-Host "Median         : $medianMs ms"
Write-Host "95th pctile    : $p95Ms ms"
Write-Host "Max            : $maxMs ms"
Write-Host ""
Write-Host "--- Projection for 10,000 files at avg rate ---" -ForegroundColor Yellow
Write-Host "Estimated time : $projectedMins minutes"
Write-Host ""

# Export for comparison
$results | Export-Csv -Path $OutputCsv -NoTypeInformation
Write-Host "Raw results saved to $OutputCsv"