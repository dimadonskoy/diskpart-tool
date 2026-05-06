# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Windows disk repartitioning tool that takes space from D: and gives it to C:. Targets the common IT scenario where C: is too small and D: has plenty of free space. Supports both MBR and GPT (UEFI) disks.

## Running the Tool

```
disk-repartition.bat
```
Double-click or run from CMD as Administrator. Auto-elevates via UAC if not already Administrator.
Password is stored as a SHA-256 hash in `$PASS_HASH` at the top of the PowerShell section.

## Architecture

Single `.bat` file — batch header + embedded PowerShell, separated by the marker `##PS_START##`.

**Batch portion (lines 1–16):**
1. Sets UTF-8 code page, window title
2. Checks admin via `net session`; if not admin, re-launches elevated with `Start-Process -Verb RunAs`
3. Sets `$env:DREPT_DIR` to the bat file's own directory; extracts the PowerShell section after `##PS_START##` using `Get-Content -Encoding UTF8`; writes it to a temp `.ps1` in `$env:TEMP`; runs it with `& $t`. Uses a temp file instead of `Invoke-Expression` to avoid UTF-8 parsing failures on systems with non-UTF-8 default codepages.

**PowerShell portion (in order):**
1. Admin re-check — `WindowsPrincipal.IsInRole(Administrator)`; exits with clear error if not elevated
2. Password auth — SHA-256 hash comparison, plaintext zeroed from memory immediately
3. Logging starts — `Start-Transcript` to `disk-repartition-YYYYMMDD-HHmmss.log` in the same directory as the bat file (via `$env:DREPT_DIR`; fallback to `C:\ProgramData\DiskRepartition\Logs\`)
4. Disk discovery — finds C:, finds D:, confirms they are on the same disk and adjacent (D: index = C: index + 1 in offset-sorted list)
5. Displays current layout table (MBR/GPT, sizes, used/free)
6. Prompts for GB to transfer; validates 1 ≤ input ≤ floor((D: size − used − 2 GB) / 1 GB)
7. Shows full operation plan (before/after table) — **no changes made yet**; if D: has data, shows a prominent warning with a `robocopy` backup suggestion
8. Single confirmation: type `YES` to proceed (one prompt regardless of whether D: has data)
9. Executes 4 steps: delete D: → extend C: → create new D: (`UseMaximumSize`) → format NTFS
10. Shows final layout, log path, offers restart with 5-second countdown
11. `Stop-Transcript` called at every exit point (success, cancel, error, restart)

## Key Design Decisions

- **Why delete D: then recreate**: Windows can only shrink partitions from their end. To give the space between C: and D: to C:, D: must be removed first so C: can expand into it, then a smaller D: is created from what remains. There is no native Windows way to preserve D: data through this operation.
- **Adjacency check**: If any partition sits between C: and D: in the offset-sorted list (e.g. a recovery partition), the tool aborts safely — it cannot repartition that layout.
- **Double admin check**: The batch layer uses `net session` for fast elevation detection; the PS layer uses `WindowsPrincipal.IsInRole` for a reliable runtime check — covers edge cases where UAC was partially bypassed.
- **Logging after auth only**: Failed password attempts are not written to the log file, avoiding noise from accidental runs.
- **Log in tool directory**: Log is written next to the bat file via `$env:DREPT_DIR` so it's easy to find after deployment to a target machine.
- **Temp file execution**: The PS section is written to `$env:TEMP\disk-repartition-tmp.ps1` and run with `& $t`. This avoids `iex` UTF-8 parsing failures that occur when the system default codepage is not UTF-8 (common on POS/enterprise machines).
- **`$MIN_D_KEEP_GB = 2`**: 2 GB buffer kept on D: beyond its used space. Adjust at top of PS section.
- **Password hash**: Change `$PASS_HASH` at the top of the PS section. Generate with: `[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('NewPass'))).Replace('-','').ToLower()`

## Testing

Always test on a VM snapshot. No automated tests — disk operations are irreversible.
