@echo off
setlocal enableextensions
title Disk Repartition Tool v2.0
chcp 65001 >nul 2>&1

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo  Requesting Administrator privileges...
    powershell -NoProfile -WindowStyle Hidden -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $f='%~f0'; $n=(Select-String -LiteralPath $f -Encoding UTF8 -Pattern '^:##PS_START##$' | Select-Object -Last 1).LineNumber; $env:DREPT_DIR=Split-Path $f; $t=[IO.Path]::Combine($env:TEMP,'disk-repartition-tmp.ps1'); Get-Content -LiteralPath $f -Encoding UTF8 | Select-Object -Skip $n | Set-Content -Path $t -Encoding UTF8; & $t; Remove-Item $t -Force -ErrorAction SilentlyContinue }"
exit /b %errorlevel%
:##PS_START##
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try { $Host.UI.RawUI.WindowTitle = 'Disk Repartition Tool v2.0' } catch {}

# ── ADMINISTRATOR CHECK ────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  ERROR: Not running as Administrator     ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    Write-Host "  This tool requires Administrator privileges." -ForegroundColor Yellow
    Write-Host "  Right-click the file and choose 'Run as administrator'." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "  Press Enter to exit" | Out-Null
    exit 1
}

# ── CONFIGURATION ──────────────────────────────────────────────────────────────
$PASS_HASH     = 'ec8f5df50eaef3d3713968fd02fb1d0f746e50cde87b8160357de503fcb9c174'
$MIN_D_KEEP_GB = 2
$LOG_DIR       = if ($env:DREPT_DIR) { $env:DREPT_DIR } else { "$env:ProgramData\DiskRepartition\Logs" }

# ── UI HELPERS ─────────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   DISK REPARTITION TOOL  v2.0            ║" -ForegroundColor Cyan
    Write-Host "  ║   Supports MBR and GPT (UEFI) disks      ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section([string]$title) {
    $ts  = Get-Date -Format 'HH:mm:ss'
    $pad = [string]('─' * [Math]::Max(2, 46 - $title.Length))
    Write-Host ""
    Write-Host "  ┌─ [$ts] $title $pad" -ForegroundColor DarkCyan
}

function Write-Line([string]$msg, [string]$color = 'White') { Write-Host "  │  $msg" -ForegroundColor $color }
function Write-OK([string]$msg)   { Write-Host "  │  [OK] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  │  [!!] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "  │  [XX] $msg" -ForegroundColor Red }

function Wait-Enter([string]$prompt = 'Press Enter to exit') {
    Write-Host ""
    Read-Host "  $prompt" | Out-Null
}

function Stop-Log {
    try { Stop-Transcript -ErrorAction SilentlyContinue } catch {}
}

function Format-Size([int64]$b) {
    if ($b -ge 1TB) { return "$([Math]::Round($b/1TB,2)) TB" }
    if ($b -ge 1GB) { return "$([Math]::Round($b/1GB,2)) GB" }
    if ($b -ge 1MB) { return "$([Math]::Round($b/1MB,1)) MB" }
    return "$b B"
}

function Get-VolumeUsage([string]$letter) {
    try {
        $v = Get-Volume -DriveLetter $letter -ErrorAction Stop
        return @{ Used = $v.Size - $v.SizeRemaining; Free = $v.SizeRemaining }
    } catch {
        return @{ Used = 0; Free = 0 }
    }
}

function Show-LayoutTable([array]$parts, [string]$diskInfo) {
    Write-Host ""
    Write-Host "  $diskInfo" -ForegroundColor White
    Write-Host ""
    Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f "Drive","Total","Used","Free","Partition Type") -ForegroundColor DarkGray
    Write-Host "  ───────────────────────────────────────────────────────────" -ForegroundColor DarkGray
    foreach ($p in $parts) {
        $letter  = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { " --" }
        $sz      = Format-Size $p.Size
        $u       = "--"; $fr = "--"
        $usedRaw = [int64]0
        $col     = 'DarkGray'
        if ($p.DriveLetter) {
            try {
                $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
                if ($v) {
                    $usedRaw = $v.Size - $v.SizeRemaining
                    $u  = Format-Size $usedRaw
                    $fr = Format-Size $v.SizeRemaining
                }
            } catch {}
            if ($p.DriveLetter -eq 'C')     { $col = 'Cyan' }
            elseif ($p.DriveLetter -eq 'D') { $col = if ($usedRaw -gt 0) { 'Yellow' } else { 'Green' } }
            else                            { $col = 'White' }
        }
        Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f $letter,$sz,$u,$fr,$p.Type) -ForegroundColor $col
    }
}

function Show-DataLossWarning([string]$drive, [double]$usedGB) {
    Write-Host "  ╔═══════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║   !! CRITICAL WARNING — DATA LOSS !!                      ║" -ForegroundColor Red
    Write-Host "  ║                                                           ║" -ForegroundColor Red
    Write-Host "  ║   ${drive}: contains $usedGB GB of data that CANNOT be preserved.  ║" -ForegroundColor Red
    Write-Host "  ║                                                           ║" -ForegroundColor Red
    Write-Host "  ║   To resize, this tool MUST delete ${drive}: entirely.          ║" -ForegroundColor Red
    Write-Host "  ║   This is a Windows limitation — no workaround exists.    ║" -ForegroundColor Red
    Write-Host "  ║                                                           ║" -ForegroundColor Red
    Write-Host "  ║   BACK UP ${drive}: NOW before continuing.                      ║" -ForegroundColor Red
    Write-Host "  ║   Suggested command (run as admin in CMD):                ║" -ForegroundColor Red
    Write-Host "  ║     robocopy ${drive}:\ <backup-path>\ /E /COPYALL /R:1 /W:1   ║" -ForegroundColor Yellow
    Write-Host "  ╚═══════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
}

function Confirm-Execute {
    $go = Read-Host "  Type  YES  to execute, anything else to cancel"
    if ($go.Trim().ToUpper() -ne 'YES') {
        Write-Host ""
        Write-Host "  Cancelled — no changes made." -ForegroundColor Yellow
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 0
    }
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║  EXECUTING — DO NOT CLOSE THIS WINDOW   ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
}

function Show-ExecuteError([string]$logFile) {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  OPERATION FAILED                        ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Red
    Write-Fail "Error: $_"
    Write-Warn "Disk may be partially modified. Open Disk Management (diskmgmt.msc) to review."
    Write-Host "  Log saved to: $logFile" -ForegroundColor DarkGray
}

function Check-Adjacency([array]$parts) {
    $cIdx = -1; $dIdx = -1
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i].DriveLetter -eq 'C') { $cIdx = $i }
        if ($parts[$i].DriveLetter -eq 'D') { $dIdx = $i }
    }
    if ($cIdx -lt 0) { return $false }
    return ($dIdx -eq ($cIdx + 1))
}

# ── BANNER + AUTH ──────────────────────────────────────────────────────────────
Show-Banner
Write-Section "AUTHENTICATION"
Write-Line ""
Write-Host "  " -NoNewline
$secPw = Read-Host "Enter password" -AsSecureString
$bstr  = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPw)
try   { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

$sha  = [Security.Cryptography.SHA256]::Create()
$hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($plain))).Replace('-','').ToLower()
$sha.Dispose()
$plain = $null

if ($hash -ne $PASS_HASH) {
    Write-Host ""
    Write-Fail "Incorrect password. Access denied."
    Write-Host ""
    Start-Sleep -Seconds 2
    exit 1
}
Write-OK "Authenticated."

# ── LOGGING ────────────────────────────────────────────────────────────────────
if (-not (Test-Path $LOG_DIR)) { New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null }
$logFile = Join-Path $LOG_DIR ("disk-repartition-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Start-Transcript -Path $logFile -NoClobber | Out-Null
Write-Host ""
Write-Host "  Log file: $logFile" -ForegroundColor DarkGray

# ── DISK DISCOVERY ─────────────────────────────────────────────────────────────
Write-Section "DISK DISCOVERY"

try {
    $cPart = Get-Partition -DriveLetter C -ErrorAction Stop
} catch {
    Write-Fail "Cannot locate C: partition: $_"
    Stop-Log; Wait-Enter; exit 1
}

$diskNum = $cPart.DiskNumber

try {
    $disk = Get-Disk -Number $diskNum -ErrorAction Stop
} catch {
    Write-Fail "Cannot access Disk $diskNum`: $_"
    Stop-Log; Wait-Enter; exit 1
}

$partStyle  = $disk.PartitionStyle
$totalBytes = $disk.Size

Write-OK "C: is on Disk $diskNum  |  Style: $partStyle  |  Total: $(Format-Size $totalBytes)"

$allParts = @(Get-Partition -DiskNumber $diskNum | Sort-Object Offset)

# ── CURRENT LAYOUT ─────────────────────────────────────────────────────────────
Write-Section "CURRENT DISK LAYOUT"
Show-LayoutTable $allParts "Disk $diskNum  [$partStyle]  $(Format-Size $totalBytes)"

# ── MAIN MENU ──────────────────────────────────────────────────────────────────
Write-Section "SELECT OPERATION"
Write-Host ""
Write-Host "    1  —  Partition disk    Create D: by shrinking C:" -ForegroundColor White
Write-Host "    2  —  Increase C:       Take space from D:, give to C:" -ForegroundColor White
Write-Host "    3  —  Increase D:       Take space from C:, give to D:" -ForegroundColor White
Write-Host ""

$menuChoice = 0
do {
    $raw    = (Read-Host "  Enter choice [1-3]").Trim()
    $parsed = 0
    $valid  = [int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 3
    if ($valid) { $menuChoice = $parsed }
    else { Write-Host "  [!!] Enter 1, 2, or 3." -ForegroundColor Yellow }
} while (-not $valid)

# ══════════════════════════════════════════════════════════════════════════════
# OPTION 1 — CREATE D: FROM C:
# ══════════════════════════════════════════════════════════════════════════════
if ($menuChoice -eq 1) {

    Write-Section "CREATE D: PARTITION"

    $dPart = $allParts | Where-Object { $_.DriveLetter -eq 'D' } | Select-Object -First 1
    if ($dPart) {
        Write-Fail "D: already exists on Disk $diskNum. Use option 2 or 3 to resize existing partitions."
        Stop-Log; Wait-Enter; exit 1
    }

    $cTotalGB = [Math]::Round($cPart.Size / 1GB, 2)
    $cFreeGB  = [Math]::Round((Get-VolumeUsage 'C').Free / 1GB, 2)

    try {
        $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    } catch {
        Write-Fail "Cannot determine C: resize limits: $_"
        Stop-Log; Wait-Enter; exit 1
    }

    $maxShrinkBytes = $cPart.Size - $sup.SizeMin
    if ($maxShrinkBytes -lt 1GB) {
        Write-Fail "C: cannot be shrunk enough to create a usable D: partition."
        Write-Warn "Free up space on C: first, then retry."
        Stop-Log; Wait-Enter; exit 1
    }

    $maxNewDGB = [int][Math]::Floor($maxShrinkBytes / 1GB)
    Write-Line ""
    Write-Line "C:  current size  $cTotalGB GB   (free: $cFreeGB GB)" "White"
    Write-Line "Maximum new D: size: $maxNewDGB GB" "White"
    Write-Line ""

    $newDGB = 0
    do {
        $raw    = Read-Host "  New D: size in GB [1 - $maxNewDGB]"
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $maxNewDGB
        if ($valid) { $newDGB = $parsed }
        else { Write-Host "  [!!] Enter a whole number between 1 and $maxNewDGB." -ForegroundColor Yellow }
    } while (-not $valid)

    $newDBytes = [int64]$newDGB * 1GB
    $newCBytes = $cPart.Size - $newDBytes
    $newCGB    = [Math]::Round($newCBytes / 1GB, 2)

    Write-Section "OPERATION PLAN"
    Write-Host ""
    Write-Host "  Steps that WILL be executed:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1/3  SHRINK  C: from $cTotalGB GB  to  $newCGB GB  (-$newDGB GB)" -ForegroundColor Yellow
    Write-Host "    2/3  CREATE  new D: partition ($newDGB GB)" -ForegroundColor Green
    Write-Host "    3/3  FORMAT  new D: as NTFS, label: DATA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE             AFTER          │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,7} GB   →   {1,7} GB  (-{2} GB){3}│" -f $cTotalGB, $newCGB, $newDGB, (' ' * [Math]::Max(0, 3 - "$newDGB".Length))) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,7}      →   {1,7} GB  (new)  {2}│" -f "--", $newDGB, '   ') -ForegroundColor Green
    Write-Host "  └──────────────┴────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Disk: $diskNum  |  Partition style: $partStyle  |  Total: $(Format-Size $totalBytes)" -ForegroundColor DarkGray

    Write-Section "CONFIRMATION"
    Write-Host ""
    Confirm-Execute

    try {
        Write-Host ""
        Write-Host "  ── [1/3] Shrinking C: to $newCGB GB ..." -ForegroundColor Cyan
        $targetC = $newCBytes
        if ($targetC -lt $sup.SizeMin) { throw "Target C: size is below Windows minimum. Choose a smaller D: size." }
        if ($targetC -gt $sup.SizeMax) { $targetC = $sup.SizeMax }
        Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "C: shrunk to $(Format-Size $targetC)."

        Write-Host ""
        Write-Host "  ── [2/3] Creating new D: partition ..." -ForegroundColor Cyan
        $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "New D: created: $(Format-Size $newD.Size)"

        Write-Host ""
        Write-Host "  ── [3/3] Formatting D: as NTFS (label: DATA) ..." -ForegroundColor Cyan
        Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'DATA' -Confirm:$false -ErrorAction Stop | Out-Null
        Write-OK "D: formatted as NTFS, label: DATA."

    } catch {
        Show-ExecuteError $logFile
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 1
    }

# ══════════════════════════════════════════════════════════════════════════════
# OPTION 2 — INCREASE C: FROM D:
# ══════════════════════════════════════════════════════════════════════════════
} elseif ($menuChoice -eq 2) {

    Write-Section "INCREASE C: PARTITION"

    $dPart = $allParts | Where-Object { $_.DriveLetter -eq 'D' } | Select-Object -First 1
    if (-not $dPart) {
        Write-Fail "D: not found on Disk $diskNum. Use option 1 to create D: first."
        Stop-Log; Wait-Enter; exit 1
    }
    Write-OK "D: found on Disk $diskNum"

    if (-not (Check-Adjacency $allParts)) {
        Write-Fail "D: is not immediately adjacent to C: on disk."
        Write-Warn "This tool requires C: and D: to be consecutive partitions."
        Write-Warn "Check layout with Disk Management (diskmgmt.msc)."
        Stop-Log; Wait-Enter; exit 1
    }
    Write-OK "C: and D: are adjacent — layout is compatible with $partStyle disk."

    $cUsage = Get-VolumeUsage 'C'; $dUsage = Get-VolumeUsage 'D'
    $cUsedBytes = $cUsage.Used; $cFreeBytes = $cUsage.Free
    $dUsedBytes = $dUsage.Used
    $cTotalGB   = [Math]::Round($cPart.Size / 1GB, 2)
    $cFreeGB    = [Math]::Round($cFreeBytes / 1GB, 2)
    $dTotalGB   = [Math]::Round($dPart.Size / 1GB, 2)
    $dUsedGB    = [Math]::Round($dUsedBytes / 1GB, 2)

    Write-Section "TRANSFER AMOUNT"
    Write-Line ""
    Write-Line "C:  current size  $cTotalGB GB   (free: $cFreeGB GB)" "White"
    Write-Line "D:  current size  $dTotalGB GB   (used: $dUsedGB GB)" "White"
    Write-Line ""

    $minDBytes     = $dUsedBytes + ([int64]$MIN_D_KEEP_GB * 1GB)
    $maxTransBytes = $dPart.Size - $minDBytes

    if ($maxTransBytes -lt 1GB) {
        Write-Fail "D: does not have enough free space. Need at least $MIN_D_KEEP_GB GB remaining on D: after transfer."
        Write-Warn "Free up space on D: first."
        Stop-Log; Wait-Enter; exit 1
    }

    $maxTransGB = [int][Math]::Floor($maxTransBytes / 1GB)
    Write-Line "Maximum transferable: $maxTransGB GB  (D: keeps at least $MIN_D_KEEP_GB GB)" "White"
    Write-Line ""

    $transferGB = 0
    do {
        $raw    = Read-Host "  GB to transfer from D: to C: [1 - $maxTransGB]"
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $maxTransGB
        if ($valid) { $transferGB = $parsed }
        else { Write-Host "  [!!] Enter a whole number between 1 and $maxTransGB." -ForegroundColor Yellow }
    } while (-not $valid)

    $transferBytes = [int64]$transferGB * 1GB
    $newCBytes     = $cPart.Size + $transferBytes
    $newDBytes     = $dPart.Size - $transferBytes
    $newCGB        = [Math]::Round($newCBytes / 1GB, 2)
    $newDGB        = [Math]::Round($newDBytes / 1GB, 2)

    Write-Section "OPERATION PLAN"
    Write-Host ""
    if ($dUsedBytes -gt 0) { Show-DataLossWarning "D" $dUsedGB }

    Write-Host "  Steps that WILL be executed:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1/4  DELETE  D: partition entirely ($dTotalGB GB)" -ForegroundColor Yellow
    Write-Host "    2/4  EXTEND  C: from $cTotalGB GB  to  $newCGB GB  (+$transferGB GB)" -ForegroundColor Green
    Write-Host "    3/4  CREATE  new D: partition ($newDGB GB, remaining space)" -ForegroundColor Green
    Write-Host "    4/4  FORMAT  new D: as NTFS, label: DATA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE             AFTER          │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,7} GB   →   {1,7} GB  (+{2} GB){3}│" -f $cTotalGB, $newCGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,7} GB   →   {1,7} GB  (-{2} GB){3}│" -f $dTotalGB, $newDGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Yellow
    Write-Host "  └──────────────┴────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Disk: $diskNum  |  Partition style: $partStyle  |  Total: $(Format-Size $totalBytes)" -ForegroundColor DarkGray

    Write-Section "CONFIRMATION"
    Write-Host ""
    if ($dUsedBytes -gt 0) {
        Write-Host "  D: has $dUsedGB GB of data that will be PERMANENTLY DELETED." -ForegroundColor Red
        Write-Host "  There is NO undo. Back up D: before proceeding if needed." -ForegroundColor Yellow
        Write-Host ""
    }
    Confirm-Execute

    try {
        Write-Host ""
        Write-Host "  ── [1/4] Removing D: partition ($dTotalGB GB) ..." -ForegroundColor Cyan
        Remove-Partition -DiskNumber $diskNum -PartitionNumber $dPart.PartitionNumber -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "D: partition deleted."

        Write-Host ""
        Write-Host "  ── [2/4] Extending C: to $newCGB GB ..." -ForegroundColor Cyan
        $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        Write-Line "Windows C: limits — min: $(Format-Size $sup.SizeMin)  max: $(Format-Size $sup.SizeMax)" "DarkGray"
        $targetC = $newCBytes
        if ($targetC -gt $sup.SizeMax) { $targetC = $sup.SizeMax; Write-Warn "Adjusted C: target to max allowed: $(Format-Size $targetC)" }
        if ($targetC -lt $sup.SizeMin) { throw "C: resize target is below minimum $(Format-Size $sup.SizeMin)." }
        Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "C: extended to $(Format-Size $targetC)."

        Write-Host ""
        Write-Host "  ── [3/4] Creating new D: partition ..." -ForegroundColor Cyan
        $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "New D: created: $(Format-Size $newD.Size)"

        Write-Host ""
        Write-Host "  ── [4/4] Formatting D: as NTFS (label: DATA) ..." -ForegroundColor Cyan
        Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'DATA' -Confirm:$false -ErrorAction Stop | Out-Null
        Write-OK "D: formatted as NTFS, label: DATA."

    } catch {
        Show-ExecuteError $logFile
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 1
    }

# ══════════════════════════════════════════════════════════════════════════════
# OPTION 3 — INCREASE D: FROM C:
# ══════════════════════════════════════════════════════════════════════════════
} elseif ($menuChoice -eq 3) {

    Write-Section "INCREASE D: PARTITION"

    $dPart = $allParts | Where-Object { $_.DriveLetter -eq 'D' } | Select-Object -First 1
    if (-not $dPart) {
        Write-Fail "D: not found on Disk $diskNum. Use option 1 to create D: first."
        Stop-Log; Wait-Enter; exit 1
    }
    Write-OK "D: found on Disk $diskNum"

    if (-not (Check-Adjacency $allParts)) {
        Write-Fail "D: is not immediately adjacent to C: on disk."
        Write-Warn "This tool requires C: and D: to be consecutive partitions."
        Write-Warn "Check layout with Disk Management (diskmgmt.msc)."
        Stop-Log; Wait-Enter; exit 1
    }
    Write-OK "C: and D: are adjacent — layout is compatible with $partStyle disk."

    $cUsage = Get-VolumeUsage 'C'; $dUsage = Get-VolumeUsage 'D'
    $cUsedBytes = $cUsage.Used; $cFreeBytes = $cUsage.Free
    $dUsedBytes = $dUsage.Used
    $cTotalGB   = [Math]::Round($cPart.Size / 1GB, 2)
    $cUsedGB    = [Math]::Round($cUsedBytes / 1GB, 2)
    $cFreeGB    = [Math]::Round($cFreeBytes / 1GB, 2)
    $dTotalGB   = [Math]::Round($dPart.Size / 1GB, 2)
    $dUsedGB    = [Math]::Round($dUsedBytes / 1GB, 2)

    Write-Section "TRANSFER AMOUNT"
    Write-Line ""
    Write-Line "C:  current size  $cTotalGB GB   (used: $cUsedGB GB, free: $cFreeGB GB)" "White"
    Write-Line "D:  current size  $dTotalGB GB   (used: $dUsedGB GB)" "White"
    Write-Line ""

    try {
        $supC = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    } catch {
        Write-Fail "Cannot determine C: resize limits: $_"
        Stop-Log; Wait-Enter; exit 1
    }

    $maxShrinkBytes = $cPart.Size - $supC.SizeMin
    if ($maxShrinkBytes -lt 1GB) {
        Write-Fail "C: cannot be shrunk. Not enough free space on C: to give to D:."
        Write-Warn "Free up space on C: first."
        Stop-Log; Wait-Enter; exit 1
    }

    $maxTransGB = [int][Math]::Floor($maxShrinkBytes / 1GB)
    Write-Line "Maximum transferable from C: to D:: $maxTransGB GB" "White"
    Write-Line ""

    $transferGB = 0
    do {
        $raw    = Read-Host "  GB to transfer from C: to D: [1 - $maxTransGB]"
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $maxTransGB
        if ($valid) { $transferGB = $parsed }
        else { Write-Host "  [!!] Enter a whole number between 1 and $maxTransGB." -ForegroundColor Yellow }
    } while (-not $valid)

    $transferBytes = [int64]$transferGB * 1GB
    $newCBytes     = $cPart.Size - $transferBytes
    $newDBytes     = $dPart.Size + $transferBytes
    $newCGB        = [Math]::Round($newCBytes / 1GB, 2)
    $newDGB        = [Math]::Round($newDBytes / 1GB, 2)

    Write-Section "OPERATION PLAN"
    Write-Host ""
    if ($dUsedBytes -gt 0) { Show-DataLossWarning "D" $dUsedGB }

    Write-Host "  Steps that WILL be executed:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1/4  SHRINK  C: from $cTotalGB GB  to  $newCGB GB  (-$transferGB GB)" -ForegroundColor Yellow
    Write-Host "    2/4  DELETE  D: partition entirely ($dTotalGB GB)" -ForegroundColor Yellow
    Write-Host "    3/4  CREATE  new D: partition ($newDGB GB, all remaining space)" -ForegroundColor Green
    Write-Host "    4/4  FORMAT  new D: as NTFS, label: DATA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE             AFTER          │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,7} GB   →   {1,7} GB  (-{2} GB){3}│" -f $cTotalGB, $newCGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,7} GB   →   {1,7} GB  (+{2} GB){3}│" -f $dTotalGB, $newDGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Yellow
    Write-Host "  └──────────────┴────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Disk: $diskNum  |  Partition style: $partStyle  |  Total: $(Format-Size $totalBytes)" -ForegroundColor DarkGray

    Write-Section "CONFIRMATION"
    Write-Host ""
    if ($dUsedBytes -gt 0) {
        Write-Host "  D: has $dUsedGB GB of data that will be PERMANENTLY DELETED." -ForegroundColor Red
        Write-Host "  There is NO undo. Back up D: before proceeding if needed." -ForegroundColor Yellow
        Write-Host ""
    }
    Confirm-Execute

    try {
        Write-Host ""
        Write-Host "  ── [1/4] Shrinking C: to $newCGB GB ..." -ForegroundColor Cyan
        $targetC = $newCBytes
        if ($targetC -lt $supC.SizeMin) { throw "C: resize target is below minimum $(Format-Size $supC.SizeMin)." }
        Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "C: shrunk to $(Format-Size $targetC)."

        Write-Host ""
        Write-Host "  ── [2/4] Removing D: partition ($dTotalGB GB) ..." -ForegroundColor Cyan
        Remove-Partition -DiskNumber $diskNum -PartitionNumber $dPart.PartitionNumber -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "D: partition deleted."

        Write-Host ""
        Write-Host "  ── [3/4] Creating new D: partition ..." -ForegroundColor Cyan
        $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "New D: created: $(Format-Size $newD.Size)"

        Write-Host ""
        Write-Host "  ── [4/4] Formatting D: as NTFS (label: DATA) ..." -ForegroundColor Cyan
        Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'DATA' -Confirm:$false -ErrorAction Stop | Out-Null
        Write-OK "D: formatted as NTFS, label: DATA."

    } catch {
        Show-ExecuteError $logFile
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 1
    }
}

# ── RESULTS ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  ALL STEPS COMPLETED SUCCESSFULLY        ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Green

try {
    $finalParts = @(Get-Partition -DiskNumber $diskNum | Sort-Object Offset)
    Show-LayoutTable $finalParts "Disk $diskNum  [$partStyle]  $(Format-Size $totalBytes)  — FINAL LAYOUT"
} catch {
    Write-Warn "Could not read final partition layout: $_"
}

# ── RESTART ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  Log saved to: $logFile" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  A restart is recommended for all changes to take full effect." -ForegroundColor Yellow
Write-Host ""
$rst = Read-Host "  Restart computer now? [Y/N]"

Stop-Log

if ($rst.Trim().ToUpper() -eq 'Y') {
    Write-Host ""
    Write-Host "  Restarting in 5 seconds ..." -ForegroundColor Cyan
    for ($t = 5; $t -ge 1; $t--) {
        Write-Host "  $t..." -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    Restart-Computer -Force
} else {
    Write-Host ""
    Write-OK "Done. Please restart manually when convenient."
    Wait-Enter "Press Enter to exit"
}
