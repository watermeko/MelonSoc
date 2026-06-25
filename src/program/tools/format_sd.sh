#!/usr/bin/env bash
# MelonSoc SD Card Formatter — MBR + FAT32 (512-byte sectors)
# Usage:  sudo ./format_sd.sh
# WARNING: Erases ALL data on the selected device!

set -euo pipefail

# ── Colors ─────────────────────────────────────────
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
NC='\033[0m' # No Color

# ── Helper functions ────────────────────────────────
die() {
    echo -e "${RED}错误: $*${NC}" >&2
    exit 1
}

info()  { echo -e "${CYAN}$*${NC}"; }
warn()  { echo -e "${YELLOW}$*${NC}"; }
ok()    { echo -e "${GREEN}$*${NC}"; }

confirm_or_die() {
    local prompt="$1"
    local reply
    echo -en "${YELLOW}${prompt} [y/N] ${NC}"
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) die "已取消。" ;;
    esac
}

# ── Root check ──────────────────────────────────────
[[ $EUID -eq 0 ]] || die "需要 root 权限。请使用 sudo 运行。\n   sudo $0"

# ── Header ──────────────────────────────────────────
cat <<EOF
╔══════════════════════════════════════════════════════════╗
║         MelonSoc SD 卡格式化工具                          ║
║  将磁盘清理并格式化为 MBR + FAT32 （扇区大小 512 字节） ║
║                                                          ║
║  ⚠ 警告：此操作将清除磁盘上的所有数据！                  ║
╚══════════════════════════════════════════════════════════╝
EOF

# ── Check for required tools ─────────────────────────
for cmd in lsblk fdisk mkfs.fat wipefs; do
    command -v "$cmd" >/dev/null 2>&1 || die "未找到 '$cmd'，请先安装。"
done

# ── List block devices ────────────────────────────────
echo
info "系统中检测到的块设备："
echo
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL
echo

# ── Ask for device ────────────────────────────────────
echo -en "请输入要格式化的设备名（如 ${YELLOW}sdb${NC}、${YELLOW}mmcblk0${NC}，不含 /dev/）: "
read -r DEVICE
DEVICE_PATH="/dev/${DEVICE}"

[[ -b "$DEVICE_PATH" ]] || die "'${DEVICE_PATH}' 不是有效的块设备。"

# ── Gather info for confirmation ──────────────────────
SIZE=$(lsblk -b -d -o SIZE "$DEVICE_PATH" 2>/dev/null | tail -n +2 | tr -d ' ')
MODEL=$(lsblk -d -o MODEL "$DEVICE_PATH" 2>/dev/null | tail -n +2 | tr -s ' ')
[[ -z "$MODEL" ]] && MODEL="(未知)"

echo
warn "╔══════════════════════════════════════════════╗"
warn "║  即将格式化以下设备：                         ║"
warn "║                                              ║"
warn "║     设备: ${DEVICE_PATH}"
warn "║     容量: $(numfmt --to=iec "$SIZE" 2>/dev/null || echo "${SIZE} 字节")"
warn "║     型号: ${MODEL}"
warn "║                                              ║"
warn "║  ⚠ 该设备上所有数据将被永久删除！            ║"
warn "╚══════════════════════════════════════════════╝"
echo

confirm_or_die "确认格式化 ${DEVICE_PATH}？"

# ── Double-check: any mounted partitions? ────────────
MOUNTED=$(lsblk -o MOUNTPOINT "${DEVICE_PATH}" 2>/dev/null | tail -n +2 | grep -v '^$' || true)
if [[ -n "$MOUNTED" ]]; then
    warn "以下分区当前已挂载："
    echo "$MOUNTED"
    confirm_or_die "即将卸载并格式化，继续？"
    # unmount them
    for part in /dev/${DEVICE}?*; do
        [[ -e "$part" ]] || continue
        umount "$part" 2>/dev/null || true
    done
fi

# ── Execute ──────────────────────────────────────────
echo
info "正在清理 ${DEVICE_PATH}..."

# 1. Wipe filesystem signatures
wipefs -a "$DEVICE_PATH" || die "wipefs 失败。"

# 2. Create MBR partition table + one FAT32 partition
info "创建 MBR 分区表和 FAT32 分区..."
parted -s "$DEVICE_PATH" mklabel msdos || die "创建 MBR 分区表失败。"
parted -s "$DEVICE_PATH" mkpart primary fat32 0% 100% || die "创建 FAT32 分区失败。"
parted -s "$DEVICE_PATH" set 1 boot on || true  # non-critical

# 3. Wait for kernel to re-read partition table
sleep 1
partprobe "$DEVICE_PATH" 2>/dev/null || udevadm settle 2>/dev/null || true
sleep 1

# 4. Determine the partition device name
if echo "$DEVICE" | grep -q 'mmcblk\|nvme'; then
    PART="${DEVICE_PATH}p1"
else
    PART="${DEVICE_PATH}1"
fi

[[ -b "$PART" ]] || die "分区 ${PART} 未出现。"

# 5. Format as FAT32
info "格式化为 FAT32（簇大小 = 4096 字节，即 8 扇区/簇）..."
mkfs.fat -F32 -s 8 -n "MELONSOC" "$PART" || die "mkfs.fat 失败。"

# ── Done ──────────────────────────────────────────────
ok "操作完成！"
echo
info "┌─────────────────────────────────────────────┐"
info "│  将 BOOT.BIN 复制到 SD 卡根目录后使用。      │"
info "│                                               │"
info "│  挂载后复制:                                   │"
info "│    cp BOOT.BIN /media/用户名/MELONSOC/         │"
info "└─────────────────────────────────────────────┘"
