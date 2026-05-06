# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Windows disk repartitioning tool that takes space from D: and gives it to C:. Targets the common IT scenario where C: is too small and D: has plenty of free space. Supports both MBR and GPT (UEFI) disks.

## Running the Tool

```
disk-repartition.bat
```
Double-click or run from CMD. Auto-elevates via UAC if not already Administrator.
Default password: `admin`

## Architecture

Single `.bat` file — batch header + embedded PowerShell, separated by the marker `##PS_START##`.

**Batch portion (lines 1–16):**
1. Sets UTF-8 code page, window title, stores own path in `$env:_self`
2. Checks admin via `net session`; if not admin, re-launches elevated with `Start-Process -Verb RunAs`
3. Extracts PowerShell code after `##PS_START##` using `[IO.File]::ReadAllText` + `Invoke-Expression`

**PowerShell portion (in order):**
1. Admin re-check — `WindowsPrincipal.IsInRole(Administrator)`; exits with clear error if not elevated
2. Password auth — SHA-256 hash comparison, plaintext zeroed from memory immediately
3. Logging starts — `Start-Transcript` to `C:\ProgramData\DiskRepartition\Logs\disk-repartition-YYYYMMDD-HHmmss.log`
4. Disk discovery — finds C:, finds D:, confirms they are on the same disk and adjacent (D: index = C: index + 1 in offset-sorted list)
5. Displays current layout table (MBR/GPT, sizes, used/free)
6. Prompts for GB to transfer; validates 1 ≤ input ≤ floor((D: size − used − 2 GB) / 1 GB)
7. Shows full operation plan (before/after table) — **no changes made yet**
8. Double-confirms if D: has data (requires typing `DELETE D DATA`)
9. Executes 4 steps: delete D: → extend C: → create new D: (`UseMaximumSize`) → format NTFS
10. Shows final layout, log path, offers restart with 5-second countdown
11. `Stop-Transcript` called at every exit point (success, cancel, error, restart)

## Key Design Decisions

- **Why delete D: then recreate**: Windows can only shrink partitions from their end. To give the space between C: and D: to C:, D: must be removed first so C: can expand into it, then a smaller D: is created from what remains.
- **Adjacency check**: If any partition sits between C: and D: in the offset-sorted list (e.g. a recovery partition), the tool aborts safely — it cannot repartition that layout.
- **Double admin check**: The batch layer uses `net session` for fast elevation detection; the PS layer uses `WindowsPrincipal.IsInRole` for a reliable runtime check — covers edge cases where UAC was partially bypassed.
- **Logging after auth only**: Failed password attempts are not written to the log file, avoiding noise from accidental runs.
- **`$MIN_D_KEEP_GB = 2`**: 2 GB buffer kept on D: beyond its used space. Adjust at top of PS section.
- **`$LOG_DIR`**: Defaults to `C:\ProgramData\DiskRepartition\Logs`. Created automatically if missing.
- **Password hash**: Change `$PASS_HASH` at the top of the PS section. Generate with: `[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('NewPass'))).Replace('-','').ToLower()`

## Testing

Always test on a VM snapshot. No automated tests — disk operations are irreversible.
