# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Windows disk repartitioning tool with a 4-option menu: create D:, grow C: from D:, grow D: from C:, delete D:. Targets common IT scenarios (undersized C:, unneeded D:, etc.). Supports both MBR and GPT (UEFI) disks.

## Running the Tool

```
disk-repartition.bat
```
Right-click → **Run as administrator**. The tool does NOT auto-elevate — if not admin, it shows an error and exits.
Password is stored as a SHA-256 hash in `$PASS_HASH` at the top of the PowerShell section.

## Architecture

Single `.bat` file — batch header + embedded PowerShell, separated by the label `:##PS_START##`.

**Batch portion (lines 1–17):**
1. Sets UTF-8 code page (`chcp 65001`), window title
2. Checks admin via `net session`; if not admin, shows a clear error box and exits with code 1 — no auto-elevation
3. Sets `$env:DREPT_DIR` to the bat file's own directory; extracts the PowerShell section after `:##PS_START##` using `Get-Content -Encoding UTF8`; writes it to a temp `.ps1` in `$env:TEMP`; runs it with `& $t`. Uses a temp file instead of `Invoke-Expression` to avoid UTF-8 parsing failures on systems with non-UTF-8 default codepages.

**PowerShell portion (in order):**
1. Admin check — `WindowsPrincipal.IsInRole(Administrator)`; exits with clear error if not elevated (secondary check, primary is in batch)
2. Configuration — `$PASS_HASH`, `$MIN_D_KEEP_GB`, `$LOG_DIR`
3. UI helper functions — `Show-Banner`, `Write-Section`, `Write-OK/Warn/Fail`, `Show-LayoutTable`, `Show-DataLossWarning`, `Confirm-Execute`
4. Banner + password auth — SHA-256 hash comparison, plaintext zeroed from memory immediately
5. Logging starts — `Start-Transcript` to `disk-repartition-YYYYMMDD-HHmmss.log` in the same directory as the bat file (via `$env:DREPT_DIR`; fallback to `C:\ProgramData\DiskRepartition\Logs\`)
6. Disk discovery — finds C:, confirms disk number and partition style (MBR/GPT)
7. Displays current layout table
8. Main menu — user picks 1 of 4 operations:
   - **1** Create D: — shrinks C: by chosen GB, creates new D:, formats NTFS
   - **2** Increase C: — deletes D:, extends C: by chosen GB, recreates D: (smaller), formats NTFS
   - **3** Increase D: — shrinks C: by chosen GB, deletes D:, recreates D: (larger), formats NTFS
   - **4** Delete D: — deletes D: entirely, extends C: to maximum available size
9. For options 2/3/4: verifies D: exists and is adjacent to C:
10. Shows full operation plan (before/after table) — **no changes made yet**; if D: has data, shows a prominent warning with a `robocopy` backup suggestion
11. Single confirmation: type `YES` to proceed
12. Executes steps (varies by option — see menu above)
13. Shows final layout, log path, offers restart with 5-second countdown
14. `Stop-Transcript` called at every exit point (success, cancel, error, restart)

## Key Design Decisions

- **No auto-elevation**: The batch layer shows an error and exits if `net session` fails. The PS layer has a secondary check via `WindowsPrincipal.IsInRole`. Users must explicitly launch as administrator.
- **Why no auto-elevation**: Silent UAC re-launch in a new window caused confusion — users saw the password prompt without understanding the admin check had already passed in the elevated instance.
- **Why delete D: then recreate**: Windows can only shrink partitions from their end. To give the space between C: and D: to C:, D: must be removed first so C: can expand into it, then a smaller D: is created from what remains. There is no native Windows way to preserve D: data through this operation.
- **Adjacency check**: If any partition sits between C: and D: in the offset-sorted list (e.g. a recovery partition), the tool aborts safely — it cannot repartition that layout.
- **Logging after auth only**: Failed password attempts are not written to the log file, avoiding noise from accidental runs.
- **Log in tool directory**: Log is written next to the bat file via `$env:DREPT_DIR` so it's easy to find after deployment to a target machine.
- **Temp file execution**: The PS section is written to `$env:TEMP\disk-repartition-tmp.ps1` and run with `& $t`. This avoids `iex` UTF-8 parsing failures that occur when the system default codepage is not UTF-8 (common on POS/enterprise machines).
- **CRLF line endings**: `disk-repartition.bat` must have CRLF (`\r\n`) line endings. With LF-only endings, Windows CMD misreads line boundaries and executes the PS section as batch commands, ignoring `exit /b`. A `.gitattributes` file enforces `eol=crlf` for all `.bat` files. After any edit, verify with: `python -c "open('disk-repartition.bat','rb').read().count(b'\r\n')"` (should match total line count).
- **`chcp 65001` known limitation**: The `chcp 65001` in the batch header changes the console code page but does NOT affect PowerShell's file reading (handled explicitly via `-Encoding UTF8`). On systems where `chcp 65001` causes CMD to mishandle batch parsing, the CRLF line endings are the critical safeguard — CMD relies on `\r\n` to correctly identify `exit /b` as a separate line.
- **`$MIN_D_KEEP_GB = 2`**: 2 GB buffer kept on D: beyond its used space. Adjust at top of PS section.
- **Password hash**: Change `$PASS_HASH` at the top of the PS section. Generate with: `[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('NewPass'))).Replace('-','').ToLower()`

## Testing

Always test on a VM snapshot. No automated tests — disk operations are irreversible.
