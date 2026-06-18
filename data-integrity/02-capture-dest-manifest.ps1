<#
.SYNOPSIS
    Captures a hash manifest of all files on the DESTINATION VM.
    Run this AFTER.

    This is a thin wrapper over the shared engine in _CaptureEngine.ps1 (which
    must sit in the same folder). All real logic lives there so the source and
    destination captures can never drift apart.

.PARAMETER RootPath
    The path to scan. Defaults to D:\

.PARAMETER OutputPath
    Where to save the manifest CSV (plus .summary.txt and, if anything was
    skipped, .skipped.txt). Defaults to the current directory.

.PARAMETER Algorithm
    Hash algorithm. MUST match the algorithm used in 01-capture-source-manifest.ps1.
    Default: MD5.

.PARAMETER ThreadCount
    Parallel hashing threads (default 4). Hashing is usually I/O-bound: use 1-2
    for a single spinning disk, 4-8 for SSD/NVMe or an SMB share. More is not
    always faster — see the README.

.PARAMETER NoLongPathSupport
    Disable \\?\ extended-length paths. Only use this if extended paths cause
    trouble on a particular host; without it, paths > 260 chars are handled.

.EXAMPLE
    .\02-capture-dest-manifest.ps1 -RootPath D:\ -OutputPath C:\manifests\

.EXAMPLE
    .\02-capture-dest-manifest.ps1 -RootPath D:\ -ThreadCount 8 -Algorithm SHA256
#>

param(
    [string]$RootPath   = 'D:\',
    [string]$OutputPath = '.\',
    [string]$Algorithm  = 'MD5',
    [int]$ThreadCount   = 4,
    [switch]$NoLongPathSupport
)

$ErrorActionPreference = 'Stop'

$enginePath = Join-Path $PSScriptRoot '_CaptureEngine.ps1'
if (-not (Test-Path -LiteralPath $enginePath)) {
    throw "Cannot find _CaptureEngine.ps1 next to this script ($enginePath). Copy the whole folder, not just this file."
}
. $enginePath

Invoke-ManifestCapture -Role DEST `
    -RootPath $RootPath `
    -OutputPath $OutputPath `
    -Algorithm $Algorithm `
    -ThreadCount $ThreadCount `
    -NoLongPathSupport:$NoLongPathSupport
