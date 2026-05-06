@echo off
setlocal enableextensions
title Disk Repartition Tool v2.0
chcp 65001 >nul 2>&1

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  ╔══════════════════════════════════════════════════════════════╗
    echo  ║   ERROR: Administrator privileges required                   ║
    echo  ║   Right-click the file and choose "Run as administrator".    ║
    echo  ╚══════════════════════════════════════════════════════════════╝
    echo.
    pause
    exit /b 1
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
    Write-Host "  ╔════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "  ║   ERROR: Administrator privileges required                  ║" -ForegroundColor Red
    Write-Host "  ╚════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
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
$BW = 60   # inner box width (chars between corner glyphs)

function Show-Banner {
    Clear-Host
    $bar   = '═' * $BW
    $title = '  DISK REPARTITION TOOL'
    $ver   = 'v2.0  '
    $tline = $title + (' ' * ($BW - $title.Length - $ver.Length)) + $ver
    Write-Host ""
    Write-Host "  ╔$bar╗" -ForegroundColor Cyan
    Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Cyan
    Write-Host ("  ║{0}║" -f $tline) -ForegroundColor Cyan
    Write-Host ("  ║{0}║" -f '  Windows C: / D: Partition Manager'.PadRight($BW)) -ForegroundColor DarkCyan
    Write-Host ("  ║{0}║" -f '  Supports MBR and GPT (UEFI) disks'.PadRight($BW)) -ForegroundColor DarkCyan
    Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Cyan
    Write-Host "  ╚$bar╝" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section([string]$title) {
    $ts      = Get-Date -Format 'HH:mm:ss'
    $label   = " $title "
    $right   = " $ts "
    $fillLen = [Math]::Max(4, $BW - $label.Length - $right.Length)
    $fill    = '─' * $fillLen
    Write-Host ""
    Write-Host "  ─$label$fill$right─" -ForegroundColor DarkCyan
}

function Write-Line([string]$msg, [string]$color = 'Gray') { Write-Host "        $msg" -ForegroundColor $color }
function Write-OK([string]$msg)   { Write-Host "  [ + ] $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  [ ! ] $msg" -ForegroundColor Yellow }
function Write-Fail([string]$msg) { Write-Host "  [ X ] $msg" -ForegroundColor Red }

function Write-Step([int]$n, [int]$total, [string]$msg) {
    $dashes = '─' * $BW
    $prefix = "  STEP $n/$total  —  "
    $rem    = $BW - $prefix.Length
    $body   = if ($msg.Length -le $rem) { $msg.PadRight($rem) } else { $msg.Substring(0, $rem) }
    Write-Host ""
    Write-Host "  ┌$dashes┐" -ForegroundColor DarkCyan
    Write-Host "  │$prefix$body│" -ForegroundColor Cyan
    Write-Host "  └$dashes┘" -ForegroundColor DarkCyan
}

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

function Get-UsageBar([int64]$used, [int64]$total, [int]$width = 12) {
    if ($total -le 0) { return '─' * $width }
    $pct    = [Math]::Min(1.0, $used / [double]$total)
    $filled = [Math]::Max(0, [Math]::Min($width, [int]($pct * $width + 0.5)))
    return ('█' * $filled) + ('░' * ($width - $filled))
}

function Show-LayoutTable([array]$parts, [string]$diskInfo) {
    Write-Host ""
    Write-Host "  $diskInfo" -ForegroundColor White
    Write-Host ""
    Write-Host ("  {0,-6}  {1,10}  {2,10}  {3,10}  {4,-12}  {5}" -f "Drive","Size","Used","Free","Usage","Type") -ForegroundColor DarkGray
    Write-Host "  $('─' * 64)" -ForegroundColor DarkGray
    foreach ($p in $parts) {
        $letter  = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { "──" }
        $sz      = Format-Size $p.Size
        $u = "──"; $fr = "──"; $bar = '─' * 12
        $usedRaw = [int64]0
        $col     = 'DarkGray'
        if ($p.DriveLetter) {
            try {
                $v = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
                if ($v) {
                    $usedRaw = $v.Size - $v.SizeRemaining
                    $u   = Format-Size $usedRaw
                    $fr  = Format-Size $v.SizeRemaining
                    $bar = Get-UsageBar $usedRaw $v.Size 12
                }
            } catch {}
            $col = if     ($p.DriveLetter -eq 'C') { 'Cyan' }
                   elseif ($p.DriveLetter -eq 'D') { if ($usedRaw -gt 0) { 'Yellow' } else { 'Green' } }
                   else                            { 'White' }
        }
        Write-Host ("  {0,-6}  {1,10}  {2,10}  {3,10}  {4,-12}  {5}" -f $letter,$sz,$u,$fr,$bar,$p.Type) -ForegroundColor $col
    }
    Write-Host ""
}

function Show-DataLossWarning([string]$drive, [double]$usedGB) {
    $bar = '═' * $BW
    Write-Host "  ╔$bar╗" -ForegroundColor Red
    Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Red
    Write-Host ("  ║{0}║" -f "  !!  CRITICAL WARNING  —  DATA LOSS  !!".PadRight($BW)) -ForegroundColor Red
    Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Red
    Write-Host ("  ║{0}║" -f "  ${drive}: contains $usedGB GB of data that CANNOT be preserved.".PadRight($BW)) -ForegroundColor Yellow
    Write-Host ("  ║{0}║" -f "  This tool MUST delete ${drive}: entirely to resize it.".PadRight($BW)) -ForegroundColor Yellow
    Write-Host ("  ║{0}║" -f "  This is a Windows limitation — no workaround exists.".PadRight($BW)) -ForegroundColor Yellow
    Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Red
    Write-Host ("  ║{0}║" -f "  BACK UP ${drive}: NOW before continuing.".PadRight($BW)) -ForegroundColor Red
    Write-Host ("  ║{0}║" -f "  Suggested backup command (run as admin in CMD):".PadRight($BW)) -ForegroundColor DarkGray
    Write-Host ("  ║{0}║" -f "    robocopy ${drive}:\ <backup-path>\ /E /COPYALL /R:1 /W:1".PadRight($BW)) -ForegroundColor Yellow
    Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Red
    Write-Host "  ╚$bar╝" -ForegroundColor Red
    Write-Host ""
}

function Confirm-Execute {
    $dashes = '─' * $BW
    Write-Host "  ┌$dashes┐" -ForegroundColor DarkGray
    Write-Host ("  │{0}│" -f "  Type  YES  to execute, or press Enter to cancel:".PadRight($BW)) -ForegroundColor White
    Write-Host "  └$dashes┘" -ForegroundColor DarkGray
    $go = Read-Host "  >"
    if ($go.Trim().ToUpper() -ne 'YES') {
        Write-Host ""
        Write-Host "  Cancelled — no changes made." -ForegroundColor Yellow
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 0
    }
    Write-Host ""
    Write-Host "  ╔$('═'*$BW)╗" -ForegroundColor Cyan
    Write-Host ("  ║{0}║" -f "  EXECUTING — DO NOT CLOSE THIS WINDOW".PadRight($BW)) -ForegroundColor Cyan
    Write-Host "  ╚$('═'*$BW)╝" -ForegroundColor Cyan
}

function Show-ExecuteError([string]$logFile) {
    Write-Host ""
    Write-Host "  ╔$('═'*$BW)╗" -ForegroundColor Red
    Write-Host ("  ║{0}║" -f "  OPERATION FAILED".PadRight($BW)) -ForegroundColor Red
    Write-Host "  ╚$('═'*$BW)╝" -ForegroundColor Red
    Write-Fail "Error: $_"
    Write-Warn "Disk may be partially modified — open diskmgmt.msc to review."
    Write-Line "Log: $logFile" "DarkGray"
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
Write-Host ""
$secPw = Read-Host "  Enter password" -AsSecureString
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
Write-Line "Log file: $logFile" "DarkGray"

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

Write-OK "C: is on Disk $diskNum  ·  Style: $partStyle  ·  Total: $(Format-Size $totalBytes)"

$allParts = @(Get-Partition -DiskNumber $diskNum | Sort-Object Offset)

# ── CURRENT LAYOUT ─────────────────────────────────────────────────────────────
Write-Section "CURRENT DISK LAYOUT"
Show-LayoutTable $allParts "Disk $diskNum  [$partStyle]  $(Format-Size $totalBytes)"

# ── MAIN MENU ──────────────────────────────────────────────────────────────────
Write-Section "SELECT OPERATION"
Write-Host ""
Write-Host "  ╔$('═'*$BW)╗" -ForegroundColor DarkCyan
Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor DarkCyan
Write-Host ("  ║{0}║" -f "  [ 1 ]  Partition disk    Create D: by shrinking C:".PadRight($BW)) -ForegroundColor White
Write-Host ("  ║{0}║" -f "  [ 2 ]  Increase C:       Take space from D:, give to C:".PadRight($BW)) -ForegroundColor White
Write-Host ("  ║{0}║" -f "  [ 3 ]  Increase D:       Take space from C:, give to D:".PadRight($BW)) -ForegroundColor White
Write-Host ("  ║{0}║" -f "  [ 4 ]  Delete D:         Delete D:, extend C: to maximum".PadRight($BW)) -ForegroundColor White
Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor DarkCyan
Write-Host "  ╚$('═'*$BW)╝" -ForegroundColor DarkCyan
Write-Host ""

$menuChoice = 0
do {
    $raw    = (Read-Host "  Enter choice [1-4]").Trim()
    $parsed = 0
    $valid  = [int]::TryParse($raw, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 4
    if ($valid) { $menuChoice = $parsed }
    else { Write-Warn "Enter 1, 2, 3, or 4." }
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
    Write-Host ""
    Write-Line "C:  current size $cTotalGB GB   (free: $cFreeGB GB)" "White"
    Write-Line "Maximum new D: size: $maxNewDGB GB" "White"
    Write-Host ""

    $newDGB = 0
    do {
        $raw    = Read-Host "  New D: size in GB [1 - $maxNewDGB]"
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $maxNewDGB
        if ($valid) { $newDGB = $parsed }
        else { Write-Warn "Enter a whole number between 1 and $maxNewDGB." }
    } while (-not $valid)

    $newDBytes = [int64]$newDGB * 1GB
    $newCBytes = $cPart.Size - $newDBytes
    $newCGB    = [Math]::Round($newCBytes / 1GB, 2)

    Write-Section "OPERATION PLAN"
    Write-Host ""
    Write-Host "  Steps that WILL be executed:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1/3  SHRINK  C: from $cTotalGB GB  →  $newCGB GB  (−$newDGB GB)" -ForegroundColor Yellow
    Write-Host "    2/3  CREATE  new D: partition  ($newDGB GB)" -ForegroundColor Green
    Write-Host "    3/3  FORMAT  D: as NTFS, label: DATA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬─────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE              AFTER           │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼─────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,8} GB   →   {1,8} GB  (−{2} GB){3}│" -f $cTotalGB, $newCGB, $newDGB, (' ' * [Math]::Max(0, 3 - "$newDGB".Length))) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,8}      →   {1,8} GB  (new)   {2}│" -f "--", $newDGB, '  ') -ForegroundColor Green
    Write-Host "  └──────────────┴─────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Line "Disk: $diskNum  ·  Style: $partStyle  ·  Total: $(Format-Size $totalBytes)" "DarkGray"

    Write-Section "CONFIRMATION"
    Write-Host ""
    Confirm-Execute

    try {
        Write-Step 1 3 "Shrinking C: to $newCGB GB ..."
        $targetC = $newCBytes
        if ($targetC -lt $sup.SizeMin) { throw "Target C: size is below Windows minimum. Choose a smaller D: size." }
        if ($targetC -gt $sup.SizeMax) { $targetC = $sup.SizeMax }
        Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "C: shrunk to $(Format-Size $targetC)."

        Write-Step 2 3 "Creating new D: partition ..."
        $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "New D: created: $(Format-Size $newD.Size)"

        Write-Step 3 3 "Formatting D: as NTFS (label: DATA) ..."
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
    Write-Host ""
    Write-Line "C:  current size $cTotalGB GB   (free: $cFreeGB GB)" "White"
    Write-Line "D:  current size $dTotalGB GB   (used: $dUsedGB GB)" "White"
    Write-Host ""

    $minDBytes     = $dUsedBytes + ([int64]$MIN_D_KEEP_GB * 1GB)
    $maxTransBytes = $dPart.Size - $minDBytes

    if ($maxTransBytes -lt 1GB) {
        Write-Fail "D: does not have enough free space. Need at least $MIN_D_KEEP_GB GB remaining on D: after transfer."
        Write-Warn "Free up space on D: first."
        Stop-Log; Wait-Enter; exit 1
    }

    $maxTransGB = [int][Math]::Floor($maxTransBytes / 1GB)
    Write-Line "Maximum transferable: $maxTransGB GB  (D: keeps at least $MIN_D_KEEP_GB GB)" "White"
    Write-Host ""

    $transferGB = 0
    do {
        $raw    = Read-Host "  GB to transfer from D: to C: [1 - $maxTransGB]"
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $maxTransGB
        if ($valid) { $transferGB = $parsed }
        else { Write-Warn "Enter a whole number between 1 and $maxTransGB." }
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
    Write-Host "    2/4  EXTEND  C: from $cTotalGB GB  →  $newCGB GB  (+$transferGB GB)" -ForegroundColor Green
    Write-Host "    3/4  CREATE  new D: partition ($newDGB GB, remaining space)" -ForegroundColor Green
    Write-Host "    4/4  FORMAT  D: as NTFS, label: DATA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬─────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE              AFTER           │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼─────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,8} GB   →   {1,8} GB  (+{2} GB){3}│" -f $cTotalGB, $newCGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,8} GB   →   {1,8} GB  (−{2} GB){3}│" -f $dTotalGB, $newDGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Yellow
    Write-Host "  └──────────────┴─────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Line "Disk: $diskNum  ·  Style: $partStyle  ·  Total: $(Format-Size $totalBytes)" "DarkGray"

    Write-Section "CONFIRMATION"
    Write-Host ""
    if ($dUsedBytes -gt 0) {
        Write-Host "  D: has $dUsedGB GB of data that will be PERMANENTLY DELETED." -ForegroundColor Red
        Write-Host "  There is NO undo. Back up D: before proceeding if needed." -ForegroundColor Yellow
        Write-Host ""
    }
    Confirm-Execute

    try {
        Write-Step 1 4 "Removing D: partition ($dTotalGB GB) ..."
        Remove-Partition -DiskNumber $diskNum -PartitionNumber $dPart.PartitionNumber -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "D: partition deleted."

        Write-Step 2 4 "Extending C: to $newCGB GB ..."
        $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        Write-Line "Windows C: limits — min: $(Format-Size $sup.SizeMin)  max: $(Format-Size $sup.SizeMax)" "DarkGray"
        $targetC = $newCBytes
        if ($targetC -gt $sup.SizeMax) { $targetC = $sup.SizeMax; Write-Warn "Adjusted C: target to max allowed: $(Format-Size $targetC)" }
        if ($targetC -lt $sup.SizeMin) { throw "C: resize target is below minimum $(Format-Size $sup.SizeMin)." }
        Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "C: extended to $(Format-Size $targetC)."

        Write-Step 3 4 "Creating new D: partition ..."
        $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "New D: created: $(Format-Size $newD.Size)"

        Write-Step 4 4 "Formatting D: as NTFS (label: DATA) ..."
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
    Write-Host ""
    Write-Line "C:  current size $cTotalGB GB   (used: $cUsedGB GB, free: $cFreeGB GB)" "White"
    Write-Line "D:  current size $dTotalGB GB   (used: $dUsedGB GB)" "White"
    Write-Host ""

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
    Write-Host ""

    $transferGB = 0
    do {
        $raw    = Read-Host "  GB to transfer from C: to D: [1 - $maxTransGB]"
        $parsed = 0
        $valid  = [int]::TryParse($raw.Trim(), [ref]$parsed) -and $parsed -ge 1 -and $parsed -le $maxTransGB
        if ($valid) { $transferGB = $parsed }
        else { Write-Warn "Enter a whole number between 1 and $maxTransGB." }
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
    Write-Host "    1/4  SHRINK  C: from $cTotalGB GB  →  $newCGB GB  (−$transferGB GB)" -ForegroundColor Yellow
    Write-Host "    2/4  DELETE  D: partition entirely ($dTotalGB GB)" -ForegroundColor Yellow
    Write-Host "    3/4  CREATE  new D: partition ($newDGB GB, all remaining space)" -ForegroundColor Green
    Write-Host "    4/4  FORMAT  D: as NTFS, label: DATA" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬─────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE              AFTER           │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼─────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,8} GB   →   {1,8} GB  (−{2} GB){3}│" -f $cTotalGB, $newCGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,8} GB   →   {1,8} GB  (+{2} GB){3}│" -f $dTotalGB, $newDGB, $transferGB, (' ' * [Math]::Max(0, 3 - "$transferGB".Length))) -ForegroundColor Yellow
    Write-Host "  └──────────────┴─────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Line "Disk: $diskNum  ·  Style: $partStyle  ·  Total: $(Format-Size $totalBytes)" "DarkGray"

    Write-Section "CONFIRMATION"
    Write-Host ""
    if ($dUsedBytes -gt 0) {
        Write-Host "  D: has $dUsedGB GB of data that will be PERMANENTLY DELETED." -ForegroundColor Red
        Write-Host "  There is NO undo. Back up D: before proceeding if needed." -ForegroundColor Yellow
        Write-Host ""
    }
    Confirm-Execute

    try {
        Write-Step 1 4 "Shrinking C: to $newCGB GB ..."
        $targetC = $newCBytes
        if ($targetC -lt $supC.SizeMin) { throw "C: resize target is below minimum $(Format-Size $supC.SizeMin)." }
        Resize-Partition -DriveLetter C -Size $targetC -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "C: shrunk to $(Format-Size $targetC)."

        Write-Step 2 4 "Removing D: partition ($dTotalGB GB) ..."
        Remove-Partition -DiskNumber $diskNum -PartitionNumber $dPart.PartitionNumber -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "D: partition deleted."

        Write-Step 3 4 "Creating new D: partition ..."
        $newD = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter D -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "New D: created: $(Format-Size $newD.Size)"

        Write-Step 4 4 "Formatting D: as NTFS (label: DATA) ..."
        Format-Volume -DriveLetter D -FileSystem NTFS -NewFileSystemLabel 'DATA' -Confirm:$false -ErrorAction Stop | Out-Null
        Write-OK "D: formatted as NTFS, label: DATA."

    } catch {
        Show-ExecuteError $logFile
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 1
    }

# ══════════════════════════════════════════════════════════════════════════════
# OPTION 4 — DELETE D: AND EXTEND C:
# ══════════════════════════════════════════════════════════════════════════════
} elseif ($menuChoice -eq 4) {

    Write-Section "DELETE D: AND EXTEND C:"

    $dPart = $allParts | Where-Object { $_.DriveLetter -eq 'D' } | Select-Object -First 1
    if (-not $dPart) {
        Write-Fail "D: not found on Disk $diskNum."
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

    $cUsage    = Get-VolumeUsage 'C'; $dUsage = Get-VolumeUsage 'D'
    $cTotalGB  = [Math]::Round($cPart.Size / 1GB, 2)
    $cFreeGB   = [Math]::Round($cUsage.Free / 1GB, 2)
    $dTotalGB  = [Math]::Round($dPart.Size / 1GB, 2)
    $dUsedGB   = [Math]::Round($dUsage.Used / 1GB, 2)
    $dUsedBytes = $dUsage.Used
    $newCGB    = [Math]::Round(($cPart.Size + $dPart.Size) / 1GB, 2)

    Write-Section "OPERATION PLAN"
    Write-Host ""
    if ($dUsedBytes -gt 0) { Show-DataLossWarning "D" $dUsedGB }

    Write-Host "  Steps that WILL be executed:" -ForegroundColor White
    Write-Host ""
    Write-Host "    1/2  DELETE  D: partition entirely ($dTotalGB GB)" -ForegroundColor Yellow
    Write-Host "    2/2  EXTEND  C: from $cTotalGB GB  →  ~$newCGB GB  (all available space)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ┌──────────────┬─────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │              │  BEFORE              AFTER           │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────┼─────────────────────────────────────┤" -ForegroundColor DarkGray
    Write-Host ("  │  C: drive    │  {0,8} GB   →  ~{1,8} GB  (+{2} GB)│" -f $cTotalGB, $newCGB, $dTotalGB) -ForegroundColor Cyan
    Write-Host ("  │  D: drive    │  {0,8} GB   →  {1,13}          │" -f $dTotalGB, "DELETED") -ForegroundColor Yellow
    Write-Host "  └──────────────┴─────────────────────────────────────┘" -ForegroundColor DarkGray
    Write-Host ""
    Write-Line "Disk: $diskNum  ·  Style: $partStyle  ·  Total: $(Format-Size $totalBytes)" "DarkGray"

    Write-Section "CONFIRMATION"
    Write-Host ""
    if ($dUsedBytes -gt 0) {
        Write-Host "  D: has $dUsedGB GB of data that will be PERMANENTLY DELETED." -ForegroundColor Red
        Write-Host "  There is NO undo. Back up D: before proceeding if needed." -ForegroundColor Yellow
        Write-Host ""
    }
    Confirm-Execute

    try {
        Write-Step 1 2 "Removing D: partition ($dTotalGB GB) ..."
        Remove-Partition -DiskNumber $diskNum -PartitionNumber $dPart.PartitionNumber -Confirm:$false -ErrorAction Stop
        Start-Sleep -Milliseconds 1500
        Write-OK "D: partition deleted."

        Write-Step 2 2 "Extending C: to maximum available size ..."
        $sup = Get-PartitionSupportedSize -DriveLetter C -ErrorAction Stop
        Write-Line "Windows C: limits — min: $(Format-Size $sup.SizeMin)  max: $(Format-Size $sup.SizeMax)" "DarkGray"
        Resize-Partition -DriveLetter C -Size $sup.SizeMax -ErrorAction Stop
        Start-Sleep -Milliseconds 1000
        Write-OK "C: extended to $(Format-Size $sup.SizeMax)."

    } catch {
        Show-ExecuteError $logFile
        Stop-Log; Wait-Enter "Press Enter to exit"
        exit 1
    }
}

# ── RESULTS ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ╔$('═'*$BW)╗" -ForegroundColor Green
Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Green
Write-Host ("  ║{0}║" -f "  ALL STEPS COMPLETED SUCCESSFULLY".PadRight($BW)) -ForegroundColor Green
Write-Host ("  ║{0}║" -f (' ' * $BW)) -ForegroundColor Green
Write-Host "  ╚$('═'*$BW)╝" -ForegroundColor Green

try {
    $finalParts = @(Get-Partition -DiskNumber $diskNum | Sort-Object Offset)
    Show-LayoutTable $finalParts "Disk $diskNum  [$partStyle]  $(Format-Size $totalBytes)  — FINAL LAYOUT"
} catch {
    Write-Warn "Could not read final partition layout: $_"
}

# ── RESTART ────────────────────────────────────────────────────────────────────
Write-Line "Log saved to: $logFile" "DarkGray"
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
