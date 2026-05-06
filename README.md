# Disk Repartition Tool

A single-file Windows utility that transfers free space from `D:` to `C:` — the common IT scenario where the OS drive is undersized and the data drive has room to spare. Supports both MBR and GPT (UEFI) disks with full pre-execution preview, password protection, and automatic logging.

---

## Features

- **Single file** — one `.bat` with embedded PowerShell, nothing to install
- **MBR and GPT support** — works with both legacy BIOS and modern UEFI partition layouts
- **Administrator check** — verifies elevation at runtime; shows a clear error and exits if not admin
- **Password protected** — SHA-256 hashed, plaintext zeroed from memory immediately after auth
- **Automatic logging** — every run is saved to a timestamped log file in `C:\ProgramData\DiskRepartition\Logs\`
- **Pre-execution plan** — shows every step and a before/after size table before touching the disk
- **Smart validation** — checks adjacency, Windows-enforced size limits, and available free space
- **Data-loss warning** — requires typing `DELETE D DATA` if D: contains files
- **Optional restart** — offers a 5-second countdown reboot on completion

---

## Requirements

| Requirement | Detail |
|---|---|
| OS | Windows 10 / Windows 11 |
| Privileges | Administrator (auto-requested via UAC) |
| Disk layout | C: and D: must be **consecutive** partitions on the same disk |
| D: free space | At least `transfer amount + 2 GB` must be free on D: |

---

## Quick Start

1. Copy `disk-repartition.bat` to any location on the target machine.
2. Double-click the file — UAC will prompt for elevation automatically.
3. Enter the password (default: **`admin`**).
4. Follow the on-screen prompts.

> **Important:** Back up D: before running if it contains data you want to keep.

---

## How It Works

The tool walks through six stages, making no changes until you explicitly confirm:

```
1. AUTHENTICATION     Admin check + password verification (SHA-256)
2. DISK DISCOVERY     Locates C: and D:, detects MBR/GPT, verifies adjacency
3. CURRENT LAYOUT     Displays all partitions with sizes and usage
4. TRANSFER AMOUNT    You choose how many GB to move (1 GB increments)
5. OPERATION PLAN     Full preview — before/after table, list of steps, data warnings
6. CONFIRMATION       Type YES (and DELETE D DATA if D: has files)
```

Once confirmed, four operations execute in sequence:

| Step | Action |
|------|--------|
| 1/4 | Delete D: partition |
| 2/4 | Extend C: into the freed space |
| 3/4 | Create new (smaller) D: partition from remaining space |
| 4/4 | Format new D: as NTFS with label `DATA` |

> **Why delete D: first?** Windows can only shrink a partition from its end, not its beginning. To give the space *between* C: and D: to C:, D: must be removed so C: can expand into it. A new D: is then created from whatever space remains.

---

## Logging

Every run is automatically recorded, regardless of outcome.

| Item | Detail |
|------|--------|
| Location | `C:\ProgramData\DiskRepartition\Logs\` |
| Filename | `disk-repartition-YYYYMMDD-HHmmss.log` |
| Content | Full console transcript with timestamps on each section header |
| When created | After successful authentication (failed password attempts are not logged) |
| On failure | Log path is printed in the error screen for easy retrieval |

Logs accumulate over time. Clean them up manually if needed.

---

## Supported Disk Layouts

### GPT / UEFI (typical modern system)

```
+-------------+--------------------------+----------------------+
| EFI (~100MB)| Windows C: (e.g. 80 GB)  | Data D: (e.g. 400 GB)|
+-------------+--------------------------+----------------------+
```

### MBR / BIOS (legacy system)

```
+------------------+----------------------+----------------------+
| System (~500 MB) | Windows C: (e.g. 80 GB)| Data D: (e.g. 400 GB)|
+------------------+----------------------+----------------------+
```

The tool aborts safely if any partition sits **between** C: and D: (e.g. a recovery partition in that position), as that layout cannot be handled without additional steps.

---

## Configuration

All settings are at the top of the PowerShell section in `disk-repartition.bat`:

### Change the password

1. Generate a SHA-256 hash of your new password:
   ```powershell
   [BitConverter]::ToString(
       [Security.Cryptography.SHA256]::Create().ComputeHash(
           [Text.Encoding]::UTF8.GetBytes('YourNewPassword')
       )
   ).Replace('-','').ToLower()
   ```
2. Replace the value of `$PASS_HASH` in the file with the output.

### Change the minimum D: reserve

Edit `$MIN_D_KEEP_GB` (default: `2`). Minimum GB that must remain on D: after shrinking, beyond whatever is currently used.

### Change the log directory

Edit `$LOG_DIR` (default: `C:\ProgramData\DiskRepartition\Logs`). The directory is created automatically if it does not exist.

---

## Safety

The tool will **abort without making any changes** if:

- Not running as Administrator
- The password is incorrect
- D: is not found on the same disk as C:
- D: is not the partition immediately after C:
- D: does not have enough free space to satisfy `transfer + MIN_D_KEEP_GB`
- The requested C: size would exceed Windows-enforced partition limits

If an error occurs **during** execution (after step 1 has already deleted D:), the tool reports the exact error, prints the log file path, and advises opening **Disk Management** (`diskmgmt.msc`) to review and manually complete the operation.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Not running as Administrator" | Script was launched without elevation | Right-click and choose **Run as administrator**, or let UAC prompt complete |
| "D: is not immediately adjacent to C:" | A recovery or other partition sits between C: and D: | Use Disk Management to check layout; manual repartition may be needed |
| "D: does not have enough free space" | D: is too full | Free up space on D: and retry |
| C: grows less than requested | Windows clamped to its maximum supported size | Normal — Windows enforces alignment and volume constraints |
| Tool window closes instantly | UAC was denied | Right-click the file and choose **Run as administrator** |
| Unicode box characters appear garbled | Terminal does not support UTF-8 | Run from Windows Terminal or PowerShell 7 instead of legacy CMD |

---

## File Structure

```
disk-tools/
├── disk-repartition.bat              <- the tool (single file, everything inside)
├── README.md
└── CLAUDE.md                         <- guidance for Claude Code

C:\ProgramData\DiskRepartition\Logs\  <- log output (created at runtime)
```

---

## License

Internal IT tool — not intended for public distribution.