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

powershell -NoProfile -ExecutionPolicy Bypass -Command "& { $f='%~f0'; $n=(Select-String -LiteralPath $f -Encoding UTF8 -Pattern '^:##PS_START##$' | Select-Object -Last 1).LineNumber; $t=[IO.Path]::Combine($env:TEMP,'disk-repartition-tmp.ps1'); Get-Content -LiteralPath $f -Encoding UTF8 | Select-Object -Skip $n | Set-Content -Path $t -Encoding UTF8; & $t; Remove-Item $t -Force -ErrorAction SilentlyContinue }"
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
# Default password: admin
# To generate a new hash:
#   [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash(
#       [Text.Encoding]::UTF8.GetBytes('YourPassword'))).Replace('-','').ToLower()
$PASS_HASH    = 'ec8f5df50eaef3d3713968fd02fb1d0f746e50cde87b8160357de503fcb9c174'
$MIN_D_KEEP_GB = 2   # minimum GB that must remain on D: after shrinking
$LOG_DIR      = "$env:ProgramData\DiskRepartition\Logs"

# ── UI HELPERS ─────────────────────────────────────────────────────────────────
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║   DISK REPARTITION TOOL  v2.0            ║" -ForegroundColor Cyan
    Write-Host "  ║   Transfer free space from D: to C:      ║" -ForegroundColor Cyan
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

function Write-Line([string]$msg, [string]$color = 'White') {
    Write-Host "  │  $msg" -ForegroundColor $color
}
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

$partStyle  = $disk.PartitionStyle   # MBR or GPT
$totalBytes = $disk.Size

Write-OK "C: is on Disk $diskNum  |  Style: $partStyle  |  Total: $(Format-Size $totalBytes)"

$allParts = @(Get-Partition -DiskNumber $diskNum | Sort-Object Offset)

$dPart = $allParts | Where-Object { $_.DriveLetter -eq 'D' } | Select-Object -First 1
if (-not $dPart) {
    Write-Fail "D: not found on Disk $diskNum. This tool requires a D: partition to transfer space from."
    Stop-Log; Wait-Enter; exit 1
}
Write-OK "D: found on Disk $diskNum"

# Verify C: and D: are adjacent (D: immediately follows C: in partition table)
$cIdx = -1; $dIdx = -1
for ($i = 0; $i -lt $allParts.Count; $i++) {
    if ($allParts[$i].DriveLetter -eq 'C') { $cIdx = $i }
    if ($allParts[$i].DriveLetter -eq 'D') { $dIdx = $i }
}

if ($cIdx -lt 0) {
    Write-Fail "Could not locate C: in the partition table."
    Stop-Log; Wait-Enter; exit 1
}

if ($dIdx -ne ($cIdx + 1)) {
    Write-Fail "D: is not immediately adjacent to C: on disk (index C=$cIdx, D=$dIdx)."
    Write-Warn "This tool requires C: and D: to be consecutive partitions."
    Write-Warn "Check layout with Disk Management (diskmgmt.msc)."
    Stop-Log; Wait-Enter; exit 1
}
Write-OK "C: and D: are adjacent — layout is compatible with $partStyle disk."

# ── VOLUME USAGE ───────────────────────────────────────────────────────────────
$cUsage = Get-VolumeUsage 'C'
$dUsage = Get-VolumeUsage 'D'

$cUsedBytes = $cUsage.Used; $cFreeBytes = $cUsage.Free
$dUsedBytes = $dUsage.Used; $dFreeBytes = $dUsage.Free

# ── CURRENT LAYOUT ─────────────────────────────────────────────────────────────
Write-Section "CURRENT DISK LAYOUT"
Write-Host ""
Write-Host "  Disk $diskNum  [$partStyle]  $(Format-Size $totalBytes)" -ForegroundColor White
Write-Host ""
Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f "Drive","Total","Used","Free","Partition Type") -ForegroundColor DarkGray
Write-Host "  ───────────────────────────────────────────────────────────" -ForegroundColor DarkGray

foreach ($p in $allParts) {
    $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { " --" }
    $sz     = Format-Size $p.Size
    $pt     = $p.Type

    if ($p.DriveLetter -eq 'C') {
        $u = Format-Size $cUsedBytes; $fr = Format-Size $cFreeBytes
        Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f $letter,$sz,$u,$fr,$pt) -ForegroundColor Cyan
    } elseif ($p.DriveLetter -eq 'D') {
        $u = Format-Size $dUsedBytes; $fr = Format-Size $dFreeBytes
        $col = if ($dUsedBytes -gt 0) { 'Yellow' } else { 'Green' }
        Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f $letter,$sz,$u,$fr,$pt) -ForegroundColor $col
    } else {
        Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f $letter,$sz,"--","--",$pt) -ForegroundColor DarkGray
    }
}

# ── TRANSFER AMOUNT INPUT ──────────────────────────────────────────────────────
Write-Section "TRANSFER AMOUNT"

$dTotalGB = [Math]::Round($dPart.Size / 1GB, 2)
$dUsedGB  = [Math]::Round($dUsedBytes  / 1GB, 2)
$cTotalGB = [Math]::Round($cPart.Size  / 1GB, 2)
$cFreeGB  = [Math]::Round($cFreeBytes  / 1GB, 2)

Write-Line ""
Write-Line "C:  current size  $cTotalGB GB   (free: $cFreeGB GB)" "White"
Write-Line "D:  current size  $dTotalGB GB   (used: $dUsedGB GB)" "White"
Write-Line ""

$minDBytes     = $dUsedBytes + ([int64]$MIN_D_KEEP_GB * 1GB)
$maxTransBytes = $dPart.Size - $minDBytes

if ($maxTransBytes -lt 1GB) {
    Write-Fail "D: does not have enough free space. Need to keep $MIN_D_KEEP_GB GB minimum on D: after shrink."
    Write-Warn "D: used: $dUsedGB GB — try freeing space on D: first."
    Stop-Log; Wait-Enter; exit 1
}

$maxTransGB = [int][Math]::Floor($maxTransBytes / 1GB)
Write-Line "Maximum transferable: $maxTransGB GB  (D: keeps at least $MIN_D_KEEP_GB GB)" "White"
Write-Line ""

$transferGB = 0
do {
    $raw = Read-Host "  GB to transfer from D: to C: [1 - $maxTransGB]"
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

# ── OPERATION PLAN ─────────────────────────────────────────────────────────────
Write-Section "OPERATION PLAN"
Write-Host ""

if ($dUsedBytes -gt 0) {
    Write-Host "  ╔═══════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  WARNING: D: contains $([Math]::Round($dUsedBytes/1GB,2)) GB of DATA              " -ForegroundColor Red
    Write-Host "  ║  ALL DATA ON D: WILL BE PERMANENTLY DESTROYED     ║" -ForegroundColor Red
    Write-Host "  ║  BACK UP D: BEFORE PROCEEDING                     ║" -ForegroundColor Red
    Write-Host "  ╚═══════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
}

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

# ── CONFIRMATION ───────────────────────────────────────────────────────────────
Write-Section "CONFIRMATION"
Write-Host ""

if ($dUsedBytes -gt 0) {
    Write-Host "  D: has $dUsedGB GB of data that will be PERMANENTLY DELETED." -ForegroundColor Red
    Write-Host ""
    $ack = Read-Host "  Type exactly  DELETE D DATA  to acknowledge, or Enter to cancel"
    if ($ack.Trim() -ne 'DELETE D DATA') {
        Write-Host ""
        Write-Host "  Cancelled — no changes made." -ForegroundColor Yellow
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 0
    }
    Write-Host ""
}

$go = Read-Host "  Type  YES  to execute, anything else to cancel"
if ($go.Trim().ToUpper() -ne 'YES') {
    Write-Host ""
    Write-Host "  Cancelled — no changes made." -ForegroundColor Yellow
    Stop-Log; Wait-Enter "Press Enter to exit"
    exit 0
}

# ── EXECUTE ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║  EXECUTING — DO NOT CLOSE THIS WINDOW   ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan

try {

    # ── Step 1: Remove D:
    Write-Host ""
    Write-Host "  ── [1/4] Removing D: partition ($dTotalGB GB) ..." -ForegroundColor Cyan
    Remove-Partition -DiskNumber $diskNum -PartitionNumber $dPart.PartitionNumber -Confirm:$false -ErrorAction Stop
    Start-Sleep -Milliseconds 1500
    Write-OK "D: partition deleted."

    # ── Step 2: Extend C:
    Write-Host ""
    Write-Host "  ── [2/4] Extending C: to $newCGB GB ..." -ForegroundColor Cyan

    $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
    Write-Line "Windows C: limits — min: $(Format-Size $sup.SizeMin)  max: $(Format-Size $sup.SizeMax)" "DarkGray"

    $targetC = $newCBytes
    if ($targetC -gt $sup.SizeMax) {
        $targetC = $sup.SizeMax
        Write-Warn "Adjusted C: target down to max allowed by Windows: $(Format-Size $targetC)"
    }
    if ($targetC -lt $sup.SizeMin) {
        Write-Fail "Target C: size $(Format-Size $targetC) is below Windows minimum $(Format-Size $sup.SizeMin)."
        throw "C: resize target is below minimum supported size."
    }

    Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
    Start-Sleep -Milliseconds 1000
    Write-OK "C: extended to $(Format-Size $targetC)."

    # ── Step 3: Create new D:
    Write-Host ""
    Write-Host "  ── [3/4] Creating new D: partition ..." -ForegroundColor Cyan
    $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
    Start-Sleep -Milliseconds 1000
    Write-OK "New D: created: $(Format-Size $newD.Size)"

    # ── Step 4: Format D:
    Write-Host ""
    Write-Host "  ── [4/4] Formatting D: as NTFS (label: DATA) ..." -ForegroundColor Cyan
    Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'DATA' -Confirm:$false -ErrorAction Stop | Out-Null
    Write-OK "D: formatted as NTFS, label: DATA."

} catch {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║  OPERATION FAILED                        ║" -ForegroundColor Red
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Red
    Write-Fail "Error: $_"
    Write-Warn "Disk may be partially modified. Open Disk Management (diskmgmt.msc) to review."
    Write-Host "  Log saved to: $logFile" -ForegroundColor DarkGray
    Stop-Log; Wait-Enter "Press Enter to exit"
    exit 1
}

# ── RESULTS ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "  ║  ALL STEPS COMPLETED SUCCESSFULLY        ║" -ForegroundColor Green
Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

try {
    $finalParts = @(Get-Partition -DiskNumber $diskNum | Sort-Object Offset)
    Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f "Drive","Total","Used","Free","Partition Type") -ForegroundColor DarkGray
    Write-Host "  ───────────────────────────────────────────────────────────" -ForegroundColor DarkGray

    foreach ($p in $finalParts) {
        $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { " --" }
        $sz     = Format-Size $p.Size
        $u = "--"; $fr = "--"
        try {
            if ($p.DriveLetter) {
                $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
                if ($v) { $u = Format-Size ($v.Size - $v.SizeRemaining); $fr = Format-Size $v.SizeRemaining }
            }
        } catch {}
        $col = switch ($p.DriveLetter) {
            'C' { 'Cyan'    }
            'D' { 'Green'   }
            default { 'DarkGray' }
        }
        Write-Host ("  {0,-5}  {1,11}  {2,11}  {3,11}  {4}" -f $letter,$sz,$u,$fr,$p.Type) -ForegroundColor $col
    }
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

# Self-cleanup of temp script file
try { Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue } catch {}
