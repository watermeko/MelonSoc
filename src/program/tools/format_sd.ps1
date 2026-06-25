<#
.SYNOPSIS
    MelonSoc SD Card Formatter — MBR + FAT32 (512-byte sectors)
.DESCRIPTION
    Lists all disks, asks user to select one, erases it and formats as
    MBR + FAT32 with 512-byte sectors (8 sectors/cluster = 4096 bytes).
    Must be run as Administrator.
#>

#Requires -RunAsAdministrator
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# ── Helpers ──────────────────────────────────────────
function Write-Header {
    Clear-Host
    Write-Host @"
╔══════════════════════════════════════════════════════════╗
║         MelonSoc SD 卡格式化工具                          ║
║  将磁盘清理并格式化为 MBR + FAT32 （扇区大小 512 字节） ║
║                                                          ║
║  ⚠ 警告：此操作将清除磁盘上的所有数据！                  ║
╚══════════════════════════════════════════════════════════╝
"@
}

function Confirm-OrExit {
    param([string]$Prompt)
    $reply = Read-Host "`n$Prompt [y/N]"
    if ($reply -notmatch '^(y|yes)$') {
        throw "已取消。"
    }
}

# ── Main ──────────────────────────────────────────────
try {
    Write-Header

    # ── List disks ───────────────────────────────────
    Write-Host "`n正在扫描磁盘..." -ForegroundColor Cyan
    $disks = Get-Disk | Sort-Object Number

    if (-not $disks) {
        throw "未检测到任何磁盘，请确认 SD 卡已连接。"
    }

    Write-Host "`n${('-'*60)}"
    Write-Host "  编号  大小        类型          名称" -ForegroundColor Cyan
    Write-Host "${('-'*60)}"
    foreach ($d in $disks) {
        $sizeStr = if ($d.Size -gt 1TB) { "{0:N1} TB" -f ($d.Size / 1TB) }
                   elseif ($d.Size -gt 1GB) { "{0:N0} GB" -f ($d.Size / 1GB) }
                   else { "{0:N0} MB" -f ($d.Size / 1MB) }
        $friendly = if ($d.FriendlyName) { $d.FriendlyName.Trim() } else { "(未知)" }
        $bus = $d.BusType
        Write-Host "  $($d.Number.ToString().PadRight(5)) $($sizeStr.PadRight(11)) $($bus.ToString().PadRight(10)) $friendly"
    }
    Write-Host "${('-'*60)}"

    # ── Select disk ─────────────────────────────────
    $diskNum = Read-Host "`n请输入要格式化的磁盘编号"
    if ($diskNum -notmatch '^\d+$') {
        throw "输入无效，请输入数字。"
    }

    $disk = $null
    foreach ($d in $disks) {
        if ($d.Number -eq [int]$diskNum) { $disk = $d; break }
    }
    if (-not $disk) {
        throw "未找到 Disk $diskNum，请重新运行并选择正确的编号。"
    }

    # ── Extra guard for Disk 0 ──────────────────────
    if ($disk.Number -eq 0) {
        Write-Host "`n" -NoNewline
        Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Yellow
        Write-Host "║  ⚠ 你选择了 Disk 0（通常是系统盘）！         " -ForegroundColor Yellow
        Write-Host "║  格式化系统盘会导致系统崩溃。                 " -ForegroundColor Yellow
        Write-Host "║  除非你确定这是 SD 卡，否则请取消操作。      " -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Yellow
        Confirm-OrExit "确认 Disk 0 是你的 SD 卡（非系统盘）？"
    }

    # ── Confirmation ────────────────────────────────
    $sizeStr = if ($disk.Size -gt 1TB) { "{0:N1} TB" -f ($disk.Size / 1TB) }
               elseif ($disk.Size -gt 1GB) { "{0:N0} GB" -f ($disk.Size / 1GB) }
               else { "{0:N0} MB" -f ($disk.Size / 1MB) }
    $friendly = if ($disk.FriendlyName) { $disk.FriendlyName.Trim() } else { "(未知)" }
    $bus = $disk.BusType

    Write-Host "`n" -NoNewline
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  即将格式化以下磁盘：                         " -ForegroundColor Yellow
    Write-Host "║                                              " -ForegroundColor Yellow
    Write-Host "║     编号: Disk $($disk.Number)"                               -ForegroundColor Yellow
    Write-Host "║     容量: $sizeStr"                                          -ForegroundColor Yellow
    Write-Host "║     名称: $friendly"                                         -ForegroundColor Yellow
    Write-Host "║     接口: $bus"                                              -ForegroundColor Yellow
    Write-Host "║     当前: $($disk.PartitionStyle)"                           -ForegroundColor Yellow
    Write-Host "║                                              " -ForegroundColor Yellow
    Write-Host "║  ⚠ 磁盘上所有分区和数据将被永久删除！        " -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Yellow

    Confirm-OrExit "确认格式化 Disk $($disk.Number)？"

    # ── Execute ─────────────────────────────────────
    Write-Host "`n正在格式化 Disk $($disk.Number)，请勿拔出 SD 卡..." -ForegroundColor Cyan

    # 1. Clean (remove all partitions and data)
    Write-Host "  → 清理磁盘..." -ForegroundColor Cyan
    Clear-Disk -Number $disk.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop

    # 2. Initialize as MBR if needed (Clear-Disk 可能已经清除了分区表但磁盘仍处于已初始化状态)
    $diskAfter = Get-Disk -Number $disk.Number
    if ($diskAfter.PartitionStyle -eq 'RAW') {
        Write-Host "  → 初始化为 MBR 分区表..." -ForegroundColor Cyan
        Initialize-Disk -Number $disk.Number -PartitionStyle MBR -Confirm:$false -ErrorAction Stop
    } else {
        Write-Host "  → 磁盘已就绪（$($diskAfter.PartitionStyle)）" -ForegroundColor Cyan
    }

    # 3. Create primary FAT32 partition (active/bootable)
    Write-Host "  → 创建主分区并标记为活动..." -ForegroundColor Cyan
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -IsActive -AssignDriveLetter -ErrorAction Stop
    $driveLetter = $partition.DriveLetter

    # 4. Format as FAT32
    Write-Host "  → 格式化为 FAT32..." -ForegroundColor Cyan
    Format-Volume -DriveLetter $driveLetter -FileSystem FAT32 -NewFileSystemLabel "MELONSOC" -Confirm:$false -ErrorAction Stop

    # ── Done ────────────────────────────────────────
    Write-Host "`n" -NoNewline
    Write-Host "操作完成！" -ForegroundColor Green
    Write-Host "`n${('─'*60)}" -ForegroundColor Cyan
    Write-Host "  盘符: ${driveLetter}:\" -ForegroundColor Cyan
    Write-Host "  格式: FAT32 (512 字节扇区)" -ForegroundColor Cyan
    Write-Host "  标签: MELONSOC" -ForegroundColor Cyan
    Write-Host "`n  请将 BOOT.BIN 复制到 ${driveLetter}:\ 根目录后使用。" -ForegroundColor Cyan
    Write-Host "${('─'*60)}" -ForegroundColor Cyan

    pause
}
catch {
    Write-Host "`n错误: $_" -ForegroundColor Red
    pause
    exit 1
}
