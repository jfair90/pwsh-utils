# Data Integrity Validation Scripts


Hash-manifest capture and offline comparison for verifying file data integrity
No file *content* is ever read
into any output — only path, size, timestamp and hash.

---

## Files

| File | Purpose | When to run |
|---|---|---|
| `_CaptureEngine.ps1` | Shared capture engine. **Not run directly.** | — |
| `01-capture-source-manifest.ps1` | Hash all files on the source VM | Before cutover |
| `02-capture-dest-manifest.ps1` | Hash all files on the dest VM | After cutover |
| `03-compare-manifests.ps1` | Compare the two manifests | After both CSVs exist |
| `04-robocopy-compare.ps1` | Fast size/timestamp pre-check | When both VMs are reachable |

> **Copy the whole folder** to each server, not individual scripts. `01` and `02`
> both depend on `_CaptureEngine.ps1` sitting next to them and will stop with a
> clear error if it is missing.

---

## Quick start

### Source manifest
```powershell
.\01-capture-source-manifest.ps1 -RootPath D:\ -OutputPath C:\manifests\
```
Copy the resulting CSV (and its `.summary.txt`) somewhere safe

### Destination manifest
```powershell
.\02-capture-dest-manifest.ps1 -RootPath D:\ -OutputPath C:\manifests\
```
Use the **same `-Algorithm`** as the source capture.

### Compare (anywhere with both CSVs)
```powershell
.\03-compare-manifests.ps1 `
    -SourceManifest .\source_manifest.csv `
    -DestManifest   .\destination_manifest.csv
```

### Optional pre-check (both VMs reachable at once)
```powershell
.\04-robocopy-compare.ps1 -Source "\\VM1\d$" -Destination "\\VM2\d$"
```

---

## Parameters worth knowing

| Parameter | Scripts | Notes |
|---|---|---|
| `-RootPath` | 01, 02 | Volume/folder to scan. Default `D:\`. |
| `-OutputPath` | 01–04 | Where outputs land. Default current dir. |
| `-Algorithm` | 01, 02 | `MD5` (default), `SHA1`, `SHA256`, `SHA384`, `SHA512`. **Must match** across source and dest. |
| `-ThreadCount` | 01, 02 | Parallel hashing threads. Default `4`. See tuning below. |
| `-NoLongPathSupport` | 01, 02 | Escape hatch to disable `\\?\` extended paths if they misbehave on a host. |
| `-FailuresOnly` | 03 | Skip the (huge) full comparison CSV; write only failures + summary. |

### Tuning `-ThreadCount`

Hashing a single volume is usually **I/O-bound, not CPU-bound** — the disk, not
the CPU, is the bottleneck. So more threads is *not* automatically faster:

- **Single spinning disk (HDD):** use `1`–`2`. Many threads cause seek
  thrashing and can be *slower* than one.
- **SSD / NVMe / multi-disk array:** `4`–`8` helps.
- **SMB / network share:** `4`–`8` helps hide network latency.

When unsure, start at the default `4` and adjust. The run prints a live
`files/s` rate, so you can compare a couple of settings on a sample folder.

---

## Outputs

### Capture (01, 02) — for each run
- `manifest_<ROLE>_<HOST>_<timestamp>.csv` — the manifest (path, size, mtime,
  hash, algorithm, host, captured-at). UTF-8 with BOM.
- `manifest_<ROLE>_<HOST>_<timestamp>.summary.txt` — file count, total bytes,
  duration, error/skip counts. **This is your sign-off evidence.**
- `manifest_<ROLE>_<HOST>_<timestamp>.skipped.txt` — only written if anything
  was skipped (reparse points, access-denied dirs, unreadable entries). If this
  file exists, coverage was **not** 100% — review it before sign-off.

### Compare (03)
- `comparison_full_<timestamp>.csv` — every file with its status (omitted with
  `-FailuresOnly`).
- `comparison_failures_<timestamp>.csv` — non-OK rows only. Should be empty.
- `comparison_summary_<timestamp>.txt` — PASS/FAIL, counts, byte totals.

### Pre-check (04)
- `robocopy_compare_<timestamp>.txt` — Robocopy log. PASS/FAIL is taken from the
  exit code, not the log text.

---

## Runtime estimates (2.8 TB data disk)

Dominated by disk read speed, since every byte is read once to hash it:
- Local NVMe / SSD: ~2–4 hours
- Network share (SMB): ~6–12 hours

Runs are unattended and print progress (files done, rate, ETA) every ~3s.

---

## Reliability behaviour (what these scripts handle)

- **Long paths (> 260 chars):** handled via `\\?\` extended-length paths.
- **Junctions / symlinks:** skipped (not followed) to avoid loops and
  double-counting; each one is logged to the `.skipped.txt` sidecar.
- **Access-denied / unreadable items:** logged to `.skipped.txt`, never silently
  dropped — so a coverage gap is always visible.
- **Locked / in-use files:** opened share-read and hashed where possible;
  genuine failures become `ERROR` rows in the manifest (visible), not omissions.
- **Crash mid-run:** results stream to disk continuously, so completed work is
  preserved.
- **Non-ASCII file names:** preserved (UTF-8 BOM) through capture and compare.
- **Worker failure:** if a hashing thread dies early, the run warns loudly that
  the manifest is incomplete.

---

## Sign-off evidence required

- [ ] Source `summary.txt`: file count + total bytes
- [ ] Destination `summary.txt`: file count + total bytes (must match source)
- [ ] Both `.skipped.txt` sidecars absent, or reviewed and explained
- [ ] `comparison_summary_*.txt` showing **PASS**
- [ ] `comparison_failures_*.csv` showing zero rows
- [ ] Confirmation that no file content was opened or displayed

---

## Notes

- Requires Windows PowerShell 5.1 — no third-party modules.
- MD5 is the default — fast and sufficient for integrity checking. It is **not**
  a security hash; use `-Algorithm SHA256` if policy requires it.
- Files legitimately modified between source capture and cutover will show as
  `HASH MISMATCH`. Use the `LastModifiedUtc` columns in the comparison to tell
  legitimate edits apart from corruption.
- `04` checks size/timestamp only and does not verify content — always finish
  with `03` before sign-off.
