<#
.SYNOPSIS
    Compares source and destination manifests produced by scripts 01 and 02.
    Run this anywhere both CSV files are available — it needs no access to the
    file servers and reads no file content, only the manifests.

.DESCRIPTION
    For every source file it reports one of:
        OK / MISSING / HASH MISMATCH / SIZE MISMATCH / HASH ERROR
    and it separately reports any file that exists on the destination but not
    the source (UNEXPECTED IN DEST).

    Memory: the destination manifest is indexed in memory; the source manifest
    is streamed past it. Only one side is ever fully resident, so this scales to
    multi-million-row manifests.

.PARAMETER SourceManifest
    Path to the CSV produced by 01-capture-source-manifest.ps1

.PARAMETER DestManifest
    Path to the CSV produced by 02-capture-dest-manifest.ps1

.PARAMETER OutputPath
    Where to write results. Defaults to the current directory.

.PARAMETER FailuresOnly
    Skip writing the (potentially huge) full comparison CSV; write only the
    failures CSV and the summary. The summary still reports the OK count.

.EXAMPLE
    .\03-compare-manifests.ps1 `
        -SourceManifest .\source-manifest.csv `
        -DestManifest   .\destination-manifest.csv
#>

param(
    [Parameter(Mandatory)][string]$SourceManifest,
    [Parameter(Mandatory)][string]$DestManifest,
    [string]$OutputPath = '.\',
    [switch]$FailuresOnly
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourceManifest)) { throw "Source manifest not found: $SourceManifest" }
if (-not (Test-Path -LiteralPath $DestManifest))   { throw "Dest manifest not found: $DestManifest" }

function ConvertTo-CsvLine {
    param([string[]]$Fields)
    $sb = New-Object System.Text.StringBuilder
    for ($k = 0; $k -lt $Fields.Length; $k++) {
        if ($k -gt 0) { [void]$sb.Append(',') }
        $f = $Fields[$k]
        if ($null -eq $f) { $f = '' }
        [void]$sb.Append('"')
        [void]$sb.Append($f.Replace('"', '""'))
        [void]$sb.Append('"')
    }
    return $sb.ToString()
}

function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [long]$Bytes)
}

Write-Host "============================================"
Write-Host "Manifest comparison"
Write-Host "Source : $SourceManifest"
Write-Host "Dest   : $DestManifest"
Write-Host "Started: $(Get-Date)"
Write-Host "============================================"
Write-Host ""

# ---- Index the destination (streamed in, held in memory) --------------------
# PowerShell hashtables are case-insensitive, matching NTFS path semantics.
Write-Host "Indexing destination manifest..."
$destIndex   = @{}
$destAlgo    = $null
$destBytes   = [long]0
$destCount   = 0
Import-Csv -LiteralPath $DestManifest -Encoding UTF8 | ForEach-Object {
    if ($null -eq $destAlgo) { $destAlgo = $_.Algorithm }
    $destCount++
    if ($_.SizeBytes) { $destBytes += [long]$_.SizeBytes }
    $destIndex[$_.RelativePath] = [PSCustomObject]@{
        Size     = $_.SizeBytes
        Hash     = $_.Hash
        Modified = $_.LastModifiedUtc
        Matched  = $false
    }
}
Write-Host ("Destination files indexed: {0:N0}" -f $destCount)

# ---- Peek source algorithm and warn on mismatch -----------------------------
$srcAlgo = (Import-Csv -LiteralPath $SourceManifest -Encoding UTF8 | Select-Object -First 1).Algorithm
if ($srcAlgo -and $destAlgo -and ($srcAlgo -ne $destAlgo)) {
    Write-Warning "Algorithm mismatch: source used '$srcAlgo', destination used '$destAlgo'."
    Write-Warning "Every file will report HASH MISMATCH. Re-capture one side with a matching -Algorithm."
}

# ---- Output writers ---------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$allFile     = Join-Path $OutputPath "comparison_full_$timestamp.csv"
$failFile    = Join-Path $OutputPath "comparison_failures_$timestamp.csv"
$summaryFile = Join-Path $OutputPath "comparison_summary_$timestamp.txt"

$enc    = New-Object System.Text.UTF8Encoding($true)
$header = ConvertTo-CsvLine @(
    'Status', 'RelativePath', 'SourceSize', 'DestSize',
    'SourceHash', 'DestHash', 'SourceModifiedUtc', 'DestModifiedUtc')

$failWriter = New-Object System.IO.StreamWriter($failFile, $false, $enc)
$failWriter.WriteLine($header)

$allWriter = $null
if (-not $FailuresOnly) {
    $allWriter = New-Object System.IO.StreamWriter($allFile, $false, $enc)
    $allWriter.WriteLine($header)
}

# ---- Stream the source past the destination index ---------------------------
Write-Host "Comparing..."
$ok = 0; $missing = 0; $mismatch = 0; $sizeMiss = 0; $hashErr = 0
$srcCount = 0; $srcBytes = [long]0

Import-Csv -LiteralPath $SourceManifest -Encoding UTF8 | ForEach-Object {
    $s = $_
    $srcCount++
    if ($s.SizeBytes) { $srcBytes += [long]$s.SizeBytes }

    $d = $destIndex[$s.RelativePath]

    if (-not $d) {
        $status = 'MISSING'; $missing++
    } else {
        $d.Matched = $true
        if ($s.Hash -eq 'ERROR' -or $d.Hash -eq 'ERROR') {
            $status = 'HASH ERROR'; $hashErr++
        } elseif ($s.Hash -ne $d.Hash) {
            $status = 'HASH MISMATCH'; $mismatch++
        } elseif ($s.SizeBytes -ne $d.Size) {
            $status = 'SIZE MISMATCH'; $sizeMiss++
        } else {
            $status = 'OK'; $ok++
        }
    }

    $line = ConvertTo-CsvLine @(
        $status, $s.RelativePath,
        $s.SizeBytes, $(if ($d) { $d.Size } else { '-' }),
        $s.Hash,      $(if ($d) { $d.Hash } else { '-' }),
        $s.LastModifiedUtc, $(if ($d) { $d.Modified } else { '-' }))

    if ($allWriter) { $allWriter.WriteLine($line) }
    if ($status -ne 'OK') { $failWriter.WriteLine($line) }
}

# ---- Files on the destination that were never matched by a source file ------
# (This is the check that was dead code in the original script.)
$unexpected = 0
foreach ($key in $destIndex.Keys) {
    $d = $destIndex[$key]
    if (-not $d.Matched) {
        $unexpected++
        $line = ConvertTo-CsvLine @(
            'UNEXPECTED IN DEST', $key,
            '-', $d.Size, '-', $d.Hash, '-', $d.Modified)
        if ($allWriter) { $allWriter.WriteLine($line) }
        $failWriter.WriteLine($line)
    }
}

if ($allWriter) { $allWriter.Flush(); $allWriter.Close() }
$failWriter.Flush(); $failWriter.Close()

$totalChecked = $srcCount + $unexpected
$totalIssues  = $missing + $mismatch + $sizeMiss + $hashErr + $unexpected
$verdict      = if ($totalIssues -eq 0 -and $srcCount -gt 0) { 'PASS' } else { 'FAIL' }

# ---- Summary file (sign-off evidence) ---------------------------------------
$summary = @"
Result               : $verdict
Compared             : $(Get-Date)
SourceManifest       : $SourceManifest
DestManifest         : $DestManifest
SourceAlgorithm      : $srcAlgo
DestAlgorithm        : $destAlgo
SourceFileCount      : $srcCount
DestFileCount        : $destCount
SourceTotalBytes     : $srcBytes ($(Format-Bytes $srcBytes))
DestTotalBytes       : $destBytes ($(Format-Bytes $destBytes))
OK                   : $ok
MissingInDest        : $missing
HashMismatch         : $mismatch
SizeMismatch         : $sizeMiss
HashErrors           : $hashErr
UnexpectedInDest     : $unexpected
TotalIssues          : $totalIssues
FullReport           : $(if ($FailuresOnly) { '(skipped: -FailuresOnly)' } else { $allFile })
FailuresReport       : $failFile
"@
Set-Content -LiteralPath $summaryFile -Value $summary -Encoding UTF8

# ---- Console summary --------------------------------------------------------
Write-Host ""
Write-Host "============================================"
Write-Host "RESULTS"
Write-Host "============================================"
Write-Host ("Source files       : {0:N0}" -f $srcCount)
Write-Host ("Dest files         : {0:N0}" -f $destCount)
Write-Host ("Total checked      : {0:N0}" -f $totalChecked)
Write-Host ""
Write-Host ("  OK               : {0:N0}" -f $ok)
Write-Host ("  Missing in dest  : {0:N0}" -f $missing)
Write-Host ("  Hash mismatch    : {0:N0}" -f $mismatch)
Write-Host ("  Size mismatch    : {0:N0}" -f $sizeMiss)
Write-Host ("  Hash errors      : {0:N0}" -f $hashErr)
Write-Host ("  Unexpected in dest: {0:N0}" -f $unexpected)
Write-Host ""

if ($verdict -eq 'PASS') {
    Write-Host "PASS - all files matched" -ForegroundColor Green
} else {
    if ($srcCount -eq 0) {
        Write-Host "FAIL - source manifest had zero files. Check inputs." -ForegroundColor Red
    } else {
        Write-Host "FAIL - $totalIssues issue(s) found" -ForegroundColor Red
        Write-Host "See: $failFile"
    }
}

Write-Host ""
if (-not $FailuresOnly) { Write-Host "Full results : $allFile" }
Write-Host "Failures only: $failFile"
Write-Host "Summary      : $summaryFile"
Write-Host "Completed    : $(Get-Date)"
Write-Host "============================================"
