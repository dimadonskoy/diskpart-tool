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

**Execution flow:**
1. Batch checks for admin rights; if missing, re-launches itself elevated via `Start-Process -Verb RunAs`
2. Batch extracts everything after `##PS_START##` using `[IO.File]::ReadAllText` and runs it with `Invoke-Expression`
3. PowerShell takes over entirely

**PowerShell flow (in order):**
1. Password auth — SHA-256 hash comparison, plaintext zeroed immediately
2. Disk discovery — finds C:, finds D:, confirms they are on the same disk and are adjacent partitions (D: index = C: index + 1 in offset-sorted list)
3. Displays current layout table (MBR/GPT, sizes, used/free)
4. Prompts for GB to transfer; validates 1 ≤ input ≤ floor((D: size − used − 2 GB) / 1 GB)
5. Shows full operation plan (before/after table) — **no changes made yet**
6. Double-confirms if D: has data (requires typing `DELETE D DATA`)
7. Executes 4 steps: delete D: → extend C: → create new D: (UseMaximumSize) → format NTFS
8. Shows final layout, offers restart with 5-second countdown

## Key Design Decisions

- **Why delete D: then recreate**: Windows can only shrink partitions from their end. To give the space between C: and D: to C:, D: must be removed first so C: can expand into it, then a smaller D: is created from what remains.
- **Adjacency check**: If any partition sits between C: and D: in the offset-sorted list (e.g. a recovery partition), the tool aborts safely — it cannot repartition that layout.
- **`$MIN_D_KEEP_GB = 2`**: Hardcoded 2 GB buffer kept on D: beyond its used space. Adjust at top of PS section.
- **Password hash**: Change `$PASS_HASH` at the top of the PS section. Generate with: `[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('NewPass'))).Replace('-','').ToLower()`

## Testing

Always test on a VM snapshot. No automated tests — disk operations are irreversible.
