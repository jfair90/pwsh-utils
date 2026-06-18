<#
.SYNOPSIS
    Shared manifest-capture engine used by 01-capture-source-manifest.ps1 and
    02-capture-dest-manifest.ps1. Dot-source this file, then call
    Invoke-ManifestCapture.

    This file is not run directly. Keep it in the same folder as scripts 01-04.

.DESCRIPTION
    Captures a hash manifest of every file under a root path. Designed for
    large (multi-TB), unattended, overnight runs on Windows Server / PowerShell 5.1.

    Reliability features (see README for the rationale behind each):
      * Parallel hashing via a runspace pool (no PS7 'ForEach-Object -Parallel'
        dependency). One thread is the sole CSV writer, so there are no shared
        counters to race on.
      * Long-path (> 260 char) support via \\?\ extended-length paths.
      * Reparse points (junctions / symlinks) are skipped to avoid loops and
        double-counting — and every skip is logged, never silent.
      * Per-directory access errors are recorded to a *_skipped.txt sidecar
        instead of being swallowed, so coverage gaps are visible for sign-off.
      * Results stream to disk as they complete (incremental flush), so a crash
        at hour 5 does not throw away the first 5 hours of work.
      * Files locked by another process are opened with FileShare.ReadWrite and
        still hashed where possible; genuine failures are recorded as ERROR rows
        (visible) rather than dropped.
      * Output is UTF-8 (with BOM) so non-ASCII file names survive the round trip
        through Import-Csv. No file *content* is ever read into output — only
        path, size, timestamp and hash.

    NOTE on parallelism: hashing a single volume is usually I/O-bound, not
    CPU-bound. More threads help on NVMe/SSD, multi-spindle arrays and SMB
    shares (where they hide latency), but can HURT on a single spinning disk by
    causing seek thrashing. Tune -ThreadCount to the storage. Default is 4.
#>

Set-StrictMode -Version 2.0

function ConvertTo-ExtendedPath {
    # Map a normal absolute path to a \\?\ extended-length path so the Win32
    # file APIs accept paths longer than MAX_PATH (260).
    param([string]$Path, [bool]$Enabled = $true)
    if (-not $Enabled)            { return $Path }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path.StartsWith('\\'))   { return '\\?\UNC\' + $Path.Substring(2) }
    return '\\?\' + $Path
}

function ConvertFrom-ExtendedPath {
    # Strip the \\?\ prefix so stored/relative paths stay clean and human-readable.
    param([string]$Path)
    if ($Path.StartsWith('\\?\UNC\')) { return '\\' + $Path.Substring(8) }
    if ($Path.StartsWith('\\?\'))     { return $Path.Substring(4) }
    return $Path
}

function ConvertTo-CsvLine {
    # Always-quote every field and double embedded quotes. Robust for file names
    # that contain commas or quotes (both legal on NTFS).
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

function Format-Duration {
    param([TimeSpan]$Span)
    return ('{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours, $Span.Minutes, $Span.Seconds)
}

function Get-FilesToHash {
    # Iterative (stack-based) directory walk. Returns total count/bytes and fills
    # $Queue with clean absolute file paths. Records every skipped directory or
    # entry into $Skipped instead of failing or silently continuing.
    param(
        [string]$Root,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$Queue,
        [System.Collections.Generic.List[string]]$Skipped,
        [bool]$UseExt
    )

    $count = 0
    $bytes = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $dir    = $stack.Pop()
        $extDir = ConvertTo-ExtendedPath $dir $UseExt

        $enum = $null
        try {
            $di   = New-Object System.IO.DirectoryInfo($extDir)
            $enum = $di.EnumerateFileSystemInfos().GetEnumerator()
        } catch {
            $Skipped.Add(("DIR`t{0}`t{1}" -f $dir, ($_.Exception.Message -replace '[\r\n]+', ' ')))
            continue
        }

        while ($true) {
            # MoveNext can throw mid-enumeration (e.g. permission change). Catch
            # per directory so one bad entry doesn't abort the whole subtree.
            try {
                if (-not $enum.MoveNext()) { break }
            } catch {
                $Skipped.Add(("ITER`t{0}`t{1}" -f $dir, ($_.Exception.Message -replace '[\r\n]+', ' ')))
                break
            }

            $info = $enum.Current
            try {
                $attr = $info.Attributes

                if (($attr -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $Skipped.Add(("REPARSE`t{0}`t(junction/symlink not traversed)" -f (ConvertFrom-ExtendedPath $info.FullName)))
                    continue
                }

                if (($attr -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $stack.Push((ConvertFrom-ExtendedPath $info.FullName))
                } else {
                    $Queue.Enqueue((ConvertFrom-ExtendedPath $info.FullName))
                    $count++
                    $bytes += $info.Length
                }
            } catch {
                $Skipped.Add(("ENTRY`t{0}`t{1}" -f $dir, ($_.Exception.Message -replace '[\r\n]+', ' ')))
            }
        }
    }

    return [PSCustomObject]@{ Count = $count; Bytes = $bytes }
}

function Invoke-ManifestCapture {
    [CmdletBinding()]
    param(
        [ValidateSet('SOURCE', 'DEST')]
        [string]$Role,
        [string]$RootPath   = 'D:\',
        [string]$OutputPath = '.\',
        [ValidateSet('MD5', 'SHA1', 'SHA256', 'SHA384', 'SHA512')]
        [string]$Algorithm  = 'MD5',
        [ValidateRange(1, 64)]
        [int]$ThreadCount   = 4,
        [switch]$NoLongPathSupport
    )

    $useExt = -not $NoLongPathSupport.IsPresent

    if (-not (Test-Path -LiteralPath $RootPath)) {
        throw "RootPath not found: $RootPath"
    }

    $startedAt  = Get-Date
    $timestamp  = $startedAt.ToString('yyyyMMdd_HHmmss')
    $capturedAt = $startedAt.ToString('yyyy-MM-dd HH:mm:ss')
    $hostname   = $env:COMPUTERNAME
    $rootLen    = $RootPath.TrimEnd('\').Length

    New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
    $outputFile  = Join-Path $OutputPath ("manifest_{0}_{1}_{2}.csv"         -f $Role, $hostname, $timestamp)
    $summaryFile = Join-Path $OutputPath ("manifest_{0}_{1}_{2}.summary.txt" -f $Role, $hostname, $timestamp)
    $skippedFile = Join-Path $OutputPath ("manifest_{0}_{1}_{2}.skipped.txt" -f $Role, $hostname, $timestamp)

    Write-Host "============================================"
    Write-Host "$Role manifest capture"
    Write-Host "Host        : $hostname"
    Write-Host "Root path   : $RootPath"
    Write-Host "Algorithm   : $Algorithm"
    Write-Host "Threads     : $ThreadCount"
    Write-Host "Long paths  : $(if ($useExt) { 'enabled (\\?\)' } else { 'disabled' })"
    Write-Host "Output      : $outputFile"
    Write-Host "Started     : $startedAt"
    Write-Host "============================================"
    Write-Host ""

    # ---- Phase 1: enumerate -------------------------------------------------
    Write-Host "Enumerating files (this can take a few minutes on large volumes)..."
    $workQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $skipped   = New-Object 'System.Collections.Generic.List[string]'
    $enumStart = Get-Date
    $totals    = Get-FilesToHash -Root $RootPath -Queue $workQueue -Skipped $skipped -UseExt $useExt
    $total     = $totals.Count

    Write-Host ("Files found : {0:N0}" -f $total)
    Write-Host ("Total size  : {0}"    -f (Format-Bytes $totals.Bytes))
    Write-Host ("Skipped     : {0} (see {1} if > 0)" -f $skipped.Count, (Split-Path $skippedFile -Leaf))
    Write-Host ("Enumerated in {0}" -f (Format-Duration ((Get-Date) - $enumStart)))
    Write-Host ""

    if ($total -eq 0) {
        Write-Warning "No files found under $RootPath. Nothing to hash. Check the path and permissions."
    }

    # ---- Phase 2: parallel hash, single-writer ------------------------------
    $resultQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string[]]'

    $worker = {
        param($WorkQueue, $ResultQueue, $Algorithm, $RootLen, $UseExt)

        $algo = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
        $clean = $null
        while ($WorkQueue.TryDequeue([ref]$clean)) {
            $rel = $clean.Substring($RootLen)
            if ($UseExt) {
                if ($clean.StartsWith('\\')) { $open = '\\?\UNC\' + $clean.Substring(2) }
                else                         { $open = '\\?\' + $clean }
            } else {
                $open = $clean
            }

            try {
                $fi    = New-Object System.IO.FileInfo($open)
                $size  = $fi.Length
                $mtime = $fi.LastWriteTimeUtc.ToString('yyyy-MM-dd HH:mm:ss')

                $fs = New-Object System.IO.FileStream(
                    $open,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite,
                    1048576,
                    [System.IO.FileOptions]::SequentialScan)
                try {
                    $hashBytes = $algo.ComputeHash($fs)
                } finally {
                    $fs.Dispose()
                }
                $hash = [System.BitConverter]::ToString($hashBytes).Replace('-', '')
                $ResultQueue.Enqueue([string[]]@($rel, "$size", $mtime, $hash, ''))
            } catch {
                $msg = $_.Exception.Message -replace '[\r\n]+', ' '
                $ResultQueue.Enqueue([string[]]@($rel, '', '', 'ERROR', $msg))
            }
        }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $ThreadCount)
    $pool.Open()

    $workers = New-Object 'System.Collections.Generic.List[object]'
    for ($t = 0; $t -lt $ThreadCount; $t++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker.ToString()).
            AddArgument($workQueue).
            AddArgument($resultQueue).
            AddArgument($Algorithm).
            AddArgument($rootLen).
            AddArgument($useExt)
        $workers.Add([PSCustomObject]@{ PS = $ps; Handle = $ps.BeginInvoke() })
    }

    # UTF-8 *with* BOM so Import-Csv reliably reads non-ASCII file names back.
    $enc    = New-Object System.Text.UTF8Encoding($true)
    $writer = New-Object System.IO.StreamWriter($outputFile, $false, $enc)
    $writer.WriteLine((ConvertTo-CsvLine @(
        'RelativePath', 'SizeBytes', 'LastModifiedUtc', 'Hash',
        'Algorithm', 'CapturedFrom', 'CapturedAt', 'Error')))

    Write-Host "Hashing with $ThreadCount thread(s). Progress every ~3s..."
    Write-Host ""

    $written    = 0
    $errors     = 0
    $bytesDone  = [long]0
    $lastReport = Get-Date
    $row        = $null

    while ($true) {
        $drained = $false
        while ($resultQueue.TryDequeue([ref]$row)) {
            $drained = $true
            $writer.WriteLine((ConvertTo-CsvLine @(
                $row[0], $row[1], $row[2], $row[3],
                $Algorithm, $hostname, $capturedAt, $row[4])))
            $written++
            if ($row[3] -eq 'ERROR') { $errors++ }
            elseif ($row[1]) { $bytesDone += [long]$row[1] }
        }

        $now = Get-Date
        if (($now - $lastReport).TotalSeconds -ge 3) {
            $writer.Flush()
            $elapsed = ($now - $startedAt).TotalSeconds
            $rate    = if ($elapsed -gt 0) { $written / $elapsed } else { 0 }
            $pct     = if ($total -gt 0) { [math]::Round($written / $total * 100, 1) } else { 100 }
            $etaTxt  = if ($rate -gt 0 -and $total -gt $written) {
                Format-Duration ([TimeSpan]::FromSeconds(($total - $written) / $rate))
            } else { '--:--:--' }
            Write-Host ("  {0,7:N0}/{1,-7:N0} ({2,5}%)  {3,6:N0} files/s  {4,9}  ETA {5}" -f `
                $written, $total, $pct, $rate, (Format-Bytes $bytesDone), $etaTxt)
            $lastReport = $now
        }

        $allDone = $true
        foreach ($w in $workers) {
            if (-not $w.Handle.IsCompleted) { $allDone = $false; break }
        }
        if ($allDone -and $resultQueue.Count -eq 0) { break }

        if (-not $drained) { Start-Sleep -Milliseconds 150 }
    }

    # Final drain (anything enqueued between the last drain and the exit check).
    while ($resultQueue.TryDequeue([ref]$row)) {
        $writer.WriteLine((ConvertTo-CsvLine @(
            $row[0], $row[1], $row[2], $row[3],
            $Algorithm, $hostname, $capturedAt, $row[4])))
        $written++
        if ($row[3] -eq 'ERROR') { $errors++ }
        elseif ($row[1]) { $bytesDone += [long]$row[1] }
    }

    foreach ($w in $workers) {
        try { $w.PS.EndInvoke($w.Handle) } catch {
            Write-Warning "A hashing worker faulted: $($_.Exception.Message)"
        }
        $w.PS.Dispose()
    }
    $pool.Close()
    $pool.Dispose()
    $writer.Flush()
    $writer.Close()

    # Safety net: if a worker died early, items remain unprocessed. Make it loud.
    $unprocessed = $workQueue.Count
    if ($unprocessed -gt 0) {
        Write-Warning ("{0:N0} files were NOT hashed (a worker stopped early). Manifest is INCOMPLETE." -f $unprocessed)
    }

    # ---- Sidecars + summary -------------------------------------------------
    if ($skipped.Count -gt 0) {
        $sw = New-Object System.IO.StreamWriter($skippedFile, $false, $enc)
        $sw.WriteLine("# Entries skipped during capture. Kind`tPath`tReason")
        foreach ($s in $skipped) { $sw.WriteLine($s) }
        $sw.Flush(); $sw.Close()
    }

    $completedAt = Get-Date
    $duration    = $completedAt - $startedAt
    $summary = @"
Role             : $Role
Host             : $hostname
RootPath         : $RootPath
Algorithm        : $Algorithm
ThreadCount      : $ThreadCount
LongPathSupport  : $useExt
Started          : $startedAt
Completed        : $completedAt
Duration         : $(Format-Duration $duration)
FilesEnumerated  : $total
FilesHashed      : $($written - $errors)
HashErrors       : $errors
FilesUnprocessed : $unprocessed
SkippedEntries   : $($skipped.Count)
TotalBytesHashed : $bytesDone ($(Format-Bytes $bytesDone))
ManifestFile     : $outputFile
"@
    Set-Content -LiteralPath $summaryFile -Value $summary -Encoding UTF8

    Write-Host ""
    Write-Host "============================================"
    Write-Host "Complete    : $completedAt"
    Write-Host ("Duration    : {0}" -f (Format-Duration $duration))
    Write-Host ("Files       : {0:N0} hashed, {1:N0} errors, {2:N0} skipped" -f ($written - $errors), $errors, $skipped.Count)
    Write-Host ("Total bytes : {0}" -f (Format-Bytes $bytesDone))
    Write-Host "Manifest    : $outputFile"
    Write-Host "Summary     : $summaryFile"
    if ($skipped.Count -gt 0) { Write-Host "Skipped     : $skippedFile" }
    Write-Host "============================================"
    if ($Role -eq 'SOURCE') {
        Write-Host ""
        Write-Host "Copy the manifest to a safe location before cutover."
        Write-Host "You will need it for post-migration comparison."
    }

    return $outputFile
}
