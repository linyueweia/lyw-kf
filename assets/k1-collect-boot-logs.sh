#!/bin/bash
# KICKPI K1：把本次开机的【全部错误/诊断信息】收集到 /boot/k1logs/，便于离线精读与精确修复。
# 用法: k1-collect-boot-logs.sh <标签>   例: early / late
# 设计: 绝不因个别命令失败而中断；结尾 sync；自动只保留最近 8 组。
LABEL="${1:-boot}"
OUT="/boot/k1logs"
TS="$(date +%Y%m%d-%H%M%S)"
BOOTID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | cut -c1-8)"
BASE="$OUT/${TS}-${LABEL}-${BOOTID}"
mkdir -p "$OUT" 2>/dev/null || exit 0

r() { "$@" 2>&1; }                      # 收集时带上 stderr
sec() { echo ""; echo "===== $* ====="; }

{
  sec "基本信息"
  echo "时间: $(date -Is)"
  echo "运行时长: $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
  echo "boot_id: $BOOTID"
  echo "内核: $(uname -a)"
  echo "cmdline: $(cat /proc/cmdline 2>/dev/null)"
  echo "机型: $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0')"
  echo "系统: $(grep -h PRETTY_NAME /etc/os-release 2>/dev/null)"

  sec "dmesg（完整）"
  r dmesg

  sec "dmesg（错误/警告/失败）"
  r dmesg | grep -iE 'error|fail|warn|denied|timeout|not found|cannot|unable|invalid|-E[A-Z]+|\[FAILED\]'

  sec "journalctl 本次启动（完整，最多 30000 行）"
  r journalctl -b --no-pager -o short-monotonic | head -30000

  sec "journalctl 本次启动（warning 及以上）"
  r journalctl -b -p warning --no-pager -o short-monotonic

  sec "失败的单元"
  r systemctl --failed --no-pager -l

  sec "关键服务状态（网口/风扇/模块/磁盘）"
  for u in systemd-modules-load pwm-fancontrol smartmontools NetworkManager systemd-networkd kickpi-k1-modules resize-rootfs; do
    echo "--- $u ---"
    r systemctl status "$u" --no-pager -l
  done

  sec "网络接口"
  r ip -d link
  r ip -s addr
  for i in /sys/class/net/*; do
    n="$(basename "$i")"
    echo "--- $n ---"
    echo "driver: $(basename "$(readlink -f "$i/device/driver" 2>/dev/null)" 2>/dev/null)"
    echo "carrier=$(cat "$i/carrier" 2>/dev/null) operstate=$(cat "$i/operstate" 2>/dev/null) speed=$(cat "$i/speed" 2>/dev/null) duplex=$(cat "$i/duplex" 2>/dev/null) mtu=$(cat "$i/mtu" 2>/dev/null) addr=$(cat "$i/address" 2>/dev/null)"
    r ethtool "$n"
    r ethtool -i "$n"
    r ethtool -S "$n"
  done

  sec "MDIO 总线与 PHY"
  for d in /sys/bus/mdio_bus/devices/*; do
    [ -e "$d" ] || continue
    echo "$(basename "$d") driver=$(basename "$(readlink -f "$d/driver" 2>/dev/null)" 2>/dev/null) phy_id=$(cat "$d/phy_id" 2>/dev/null)"
  done

  sec "设备树里的网口节点"
  for e in /proc/device-tree/ethernet@*; do
    [ -d "$e" ] || continue
    echo "--- $e ---"
    ls "$e"
    for p in status phy-mode tx_delay rx_delay clock_in_out compatible; do
      [ -f "$e/$p" ] && echo "$p = $(tr -d '\0' < "$e/$p" | head -c 200)"
    done
    [ -d "$e/mdio" ] && { echo "mdio:"; ls "$e/mdio"; }
  done

  sec "模块"
  r lsmod
  r modinfo maxio
  grep -iE 'maxio|stmmac|dwmac|mae0621' /proc/modules 2>/dev/null

  sec "块设备 / 文件系统"
  r lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,PARTUUID,MOUNTPOINT
  r blkid
  r df -h

  sec "PCIe"
  r lspci -nn
  r lspci -vv -nn

  sec "启动相关内核子系统（逐个抓）"
  for k in gmac stmmac dwmac phy mdio vop hdmi rga gpu pcie sata nvme mmc reg; do
    echo "--- 关键字: $k ---"
    r dmesg | grep -i "$k"
  done

  sec "syslog 尾部"
  r tail -n 300 /var/log/syslog
  r tail -n 200 /var/log/messages
} > "$BASE-full.txt" 2>&1

# 精简版：只看错误，方便快速定位
{
  echo "时间: $(date -Is)  标签: $LABEL  内核: $(uname -r)"
  echo ""
  echo "===== dmesg 错误/警告 ====="
  dmesg 2>&1 | grep -iE 'error|fail|warn|denied|timeout|cannot|unable|invalid|-E[A-Z]+|\[FAILED\]'
  echo ""
  echo "===== 失败单元 ====="
  systemctl --failed --no-pager -l 2>&1
  echo ""
  echo "===== journal 错误 ====="
  journalctl -b -p err --no-pager -o short-monotonic 2>&1 | head -800
} > "$BASE-errors.txt" 2>&1

# 只保留最近 8 组，避免塞满 /boot
ls -1t "$OUT"/*-full.txt  2>/dev/null | tail -n +9 | while read -r f; do
  rm -f "$f" "${f%-full.txt}-errors.txt" 2>/dev/null
done

sync
echo "[k1-collect] 已写出 $BASE-full.txt ($(wc -l < "$BASE-full.txt" 2>/dev/null) 行) 与 -errors.txt"
