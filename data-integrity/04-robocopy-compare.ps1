<#
.SYNOPSIS
    Fast pre-check using Robocopy in list-only mode. Compares source and
    destination by size and timestamp only — no hashing, no copying.
    Use it as a quick first pass before the full hash comparison (script 03).
    Requires both source and destination to be reachable at the same time.

.DESCRIPTION
    PASS/FAIL is decided from Robocopy's exit code (a bitmask), NOT by parsing
    log text. Log wording is localised and changes between Windows versions, so
    text parsing is unreliable; the exit code is stable and language-independent.

    Robocopy exit-code bits:
        1  some files would be copied (new/changed on source vs dest)
        2  extra files/dirs exist on the destination (not on source)
        4  mismatched files/dirs (e.g. file on one side, folder on the other)
        8  some files/dirs could NOT be accessed  -> check is incomplete
       16  fatal error                            -> check did not run properly
    Bits 1/2/4 = differences found. Bits 8/16 = the check itself had problems.
    Exit code 0 = source and destination are in sync (size/timestamp).

.PARAMETER Source
    UNC or local path of the source share/directory, e.g. \\onpremserver\d$

.PARAMETER Destination
    UNC or local path of the destination share/directory, e.g. \\azurevm\d$

.PARAMETER OutputPath
    Where to write the Robocopy log. Defaults to the current directory.

.EXAMPLE
    .\04-robocopy-compare.ps1 -Source "\\onpremserver\d$" -Destination "\\azurevm\d$"
#>

param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [string]$OutputPath = '.\'
)

$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
$logFile   = Join-Path $OutputPath "robocopy_compare_$timestamp.txt"

Write-Host "Running Robocopy list-only comparison..."
Write-Host "Source      : $Source"
Write-Host "Destination : $Destination"
Write-Host "Log         : $logFile"
Write-Host ""

# /E    recurse incl. empty dirs      /L     list only (copy nothing)
# /R:0  no retries  /W:0 no waits      -> never hang unattended on a locked file
# /XJ   skip junctions (matches the capture scripts' reparse-point handling)
# /NP   no per-file % (small log)      /NDL   no dir list
# /BYTES sizes in bytes                /FP    full path in log
robocopy $Source $Destination /E /L /R:0 /W:0 /XJ /NP /NDL /BYTES /FP /LOG:$logFile | Out-Null
$code = $LASTEXITCODE

# Decode the bitmask.
$diffs  = @()
if ($code -band 1) { $diffs += 'files would be copied (new/changed on source)' }
if ($code -band 2) { $diffs += 'extra files/dirs on destination' }
if ($code -band 4) { $diffs += 'mismatched files/dirs' }

$problems = @()
if ($code -band 8)  { $problems += 'some files/dirs could not be accessed (check is INCOMPLETE)' }
if ($code -band 16) { $problems += 'fatal error (check did not run properly)' }

Write-Host ""
Write-Host "============================================"
Write-Host "Robocopy exit code: $code"

if ($problems.Count -gt 0) {
    Write-Host "ERROR - the comparison could not complete reliably:" -ForegroundColor Red
    foreach ($p in $problems) { Write-Host "  - $p" }
    if ($diffs.Count -gt 0) {
        Write-Host "Differences also reported:"
        foreach ($d in $diffs) { Write-Host "  - $d" }
    }
    Write-Host "See $logFile for detail."
} elseif ($diffs.Count -gt 0) {
    Write-Host "DIFFERENCES found:" -ForegroundColor Yellow
    foreach ($d in $diffs) { Write-Host "  - $d" }
    Write-Host "See $logFile for the affected files."
} else {
    Write-Host "PASS - Robocopy found no size/timestamp differences" -ForegroundColor Green
}
Write-Host "============================================"
Write-Host ""
Write-Host "Note: Robocopy checks size and timestamp only - it does NOT verify"
Write-Host "content. Always follow up with 03-compare-manifests.ps1 for"
Write-Host "hash-level verification before sign-off."
