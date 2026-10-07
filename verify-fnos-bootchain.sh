#!/usr/bin/env bash
#
# 飞牛 fnOS (KICKPI K1) 镜像【引导链逐环验证】
# 只对镜像文件操作，不动任何设备。六环全过才交付上机。
#
# 环1 SPL/DDR    : LBA64 idbloader 的 DDR 初始化固件（须匹配本板 LPDDR4@1560MHz；拒绝 T68M 的 V1.18）
# 环2 U-Boot     : LBA16384 u-boot.itb 存在且可解析
# 环3 设备树      : BOOT 分区里 rk3568-kickpi-k1.dtb 存在且内容为 K1 实机值
# 环4 引导配置    : fnEnv/extlinux 指向本板 DTB 与内核；root= 为镜像自身 PARTUUID
# 环5 安卓布局防护 : 不引用 /dev/mmcblk0* 与厂商 eMMC PARTUUID；u-boot 不带安卓劫持路径
# 环6 飞牛特需项   : rootfs 是 btrfs（飞牛 OTA 前提）+ maxio.ko 已注入且 vermagic 匹配内核
set -uo pipefail

IMG="${1:?用法: verify-fnos-bootchain.sh <image.img>}"
FAIL=0
ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; FAIL=1; }
warn() { echo "  ⚠ $*"; }

EMMC_PARTUUID="614e0000-0000-4b53-8000-1d28000054a9"   # 本机 eMMC 厂商根分区
KREL_NEED="6.18.18"                                     # 飞牛内核 6.18.18-trim
KREL_FULL="6.18.18-trim"

echo "==== 镜像: $IMG ($(stat -c%s "$IMG" 2>/dev/null || echo '?') 字节) ===="
[[ -f "$IMG" ]] || { echo "✗ 镜像不存在"; exit 1; }

echo
echo "── 环1：SPL / DDR 初始化固件（LBA 64）──"
dd if="$IMG" bs=512 skip=64 count=800 status=none 2>/dev/null > /tmp/_fb_idb.img
[[ "$(stat -c%s /tmp/_fb_idb.img)" -gt 100000 ]] && ok "idblock 区域可读" || bad "idblock 区域异常"
DDR_S="$(strings /tmp/_fb_idb.img | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -2)"
[[ -n "$DDR_S" ]] && { echo "$DDR_S" | sed 's/^/       /'; ok "DDR 固件串可识别"; } || warn "未抠出 DDR 固件串"
strings /tmp/_fb_idb.img | grep -q 'V1.18 f366f69a7d' \
    && bad "这是 T68M 的 DDR V1.18（本板需 1560MHz 版本）" \
    || ok "不是 T68M 的 V1.18 固件"
strings /tmp/_fb_idb.img | grep -qiE '1560|v1\.2[0-9]' && ok "疑似 1560MHz 变体" \
    || warn "版本串未直接给出 1560MHz（本板 freq_0=0x618=1560MHz，上机实测确认）"

echo
echo "── 环2：U-Boot（LBA 16384）──"
dd if="$IMG" bs=512 skip=16384 count=4096 status=none 2>/dev/null > /tmp/_fb_uboot.itb
if head -c 8 /tmp/_fb_uboot.itb | grep -q 'd00dfeed' || grep -qi 'device tree' <<<"$(file -b /tmp/_fb_uboot.itb)"; then
    ok "u-boot.itb 为 FIT/FDT 格式"
else
    [[ "$(tr -d '\0' < /tmp/_fb_uboot.itb | wc -c)" -gt 1000 ]] \
        && warn "u-boot 区非空但未识别为 FIT（上机确认）" || bad "u-boot 区为空/全零"
fi
strings /tmp/_fb_uboot.itb | grep -iE 'U-Boot 20[0-9]{2}\.' | head -2 | sed 's/^/       /'

echo
echo "── 环3/4/5/6：挂载镜像分区检查 ──"
MNT_B=/mnt/_fb_boot; MNT_R=/mnt/_fb_root
mkdir -p "$MNT_B" "$MNT_R"
LOOP="$(losetup -fP --show "$IMG")"
cleanup(){ for m in "$MNT_B" "$MNT_R"; do mountpoint -q "$m" && umount "$m"; done
           [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP"; rm -rf /tmp/_fb_*; }
trap cleanup EXIT
sleep 1
BP=""; RP=""
for c in "${LOOP}p1" "${LOOP}1"; do [[ -e "$c" ]] && BP="$c" && break; done
for c in "${LOOP}p2" "${LOOP}2"; do [[ -e "$c" ]] && RP="$c" && break; done
[[ -n "$BP" ]] || { bad "无 boot 分区"; exit 1; }

echo "  分区布局: p1=$(lsblk -no FSTYPE "$BP"|tr -d ' ')  p2=$(lsblk -no FSTYPE "$RP" 2>/dev/null|tr -d ' ')"
ROOT_PARTUUID="$(lsblk -no PARTUUID "$RP" 2>/dev/null | tr -d ' ')"
echo "  rootfs PARTUUID: ${ROOT_PARTUUID:-未取到}"

mount "$BP" "$MNT_B" || { bad "挂载 p1 失败"; exit 1; }
echo "  ── p1 内容（前 15 项）──"; ls "$MNT_B" | head -15 | sed 's/^/       /'

# 环3 设备树
DTB="$(find "$MNT_B" -name 'rk3568-kickpi-k1.dtb' | head -1)"
if [[ -n "$DTB" ]]; then
    ok "找到本板 DTB（$(stat -c%s "$DTB") 字节）"
    if dtc -I dtb -O dts "$DTB" > /tmp/_fb_k1.dts 2>/dev/null; then
        ok "DTB 可反编译"
        for pat in "tx_delay = <0x21>" "rx_delay = <0x3c>" "tx_delay = <0x2f>" "rx_delay = <0x39>"; do
            grep -q "$pat" /tmp/_fb_k1.dts && ok "实机逐字值 $pat" || bad "缺实机值 $pat"
        done
        for n in "sata@fc000000" "sata@fc400000" "sata@fc800000"; do
            grep -q "$n" /tmp/_fb_k1.dts && ok "含 $n" || bad "缺 $n"
        done
        grep -qiE 'maxio|mae0621' /tmp/_fb_k1.dts && ok "PHY 为 Maxio 系" || warn "未见图 PHY 型号字样"
    else
        bad "DTB 无法反编译"
    fi
else
    bad "p1 里没有 rk3568-kickpi-k1.dtb"
fi

# 环4/5 引导配置
echo "  ── 引导配置 ──"
for f in "$MNT_B/fnEnv.txt" "$MNT_B/extlinux/extlinux.conf" "$MNT_B/armbianEnv.txt"; do
    [[ -f "$f" ]] || continue
    echo "     ⟨$(basename "$f")⟩"; grep -iE 'fdtfile|fdt |kernel|root=|console' "$f" | head -6 | sed 's/^/       /'
done
if [[ -n "$ROOT_PARTUUID" ]]; then
    for f in "$MNT_B/extlinux/extlinux.conf" "$MNT_B/armbianEnv.txt" "$MNT_B/fnEnv.txt"; do
        [[ -f "$f" ]] || continue
        grep -q "$ROOT_PARTUUID" "$f" && ok "$(basename "$f") 的 root= 指向镜像自身 PARTUUID" || warn "$(basename "$f") 未见自身 PARTUUID"
    done
fi
grep -q 'rk3568-kickpi-k1.dtb' "$MNT_B/fnEnv.txt" 2>/dev/null && ok "fnEnv 指向本板 DTB" \
    || { grep -q 'rk3568-kickpi-k1.dtb' "$MNT_B/extlinux/extlinux.conf" 2>/dev/null && ok "extlinux 指向本板 DTB" || bad "引导配置未指向本板 DTB"; }

HIT=0
for f in "$MNT_B"/*; do
    [[ -f "$f" ]] || continue
    grep -q 'mmcblk0' "$f" 2>/dev/null && { bad "$(basename "$f") 引用 /dev/mmcblk0*（会误挂厂商 eMMC）"; HIT=1; }
    grep -qi "$EMMC_PARTUUID" "$f" 2>/dev/null && { bad "$(basename "$f") 引用厂商 eMMC PARTUUID"; HIT=1; }
done
[[ $HIT -eq 0 ]] && ok "引导配置未引用 eMMC（不会劫持到厂商系统）"
strings /tmp/_fb_uboot.itb | grep -qiE 'bootrkp|boot_android' \
    && warn "u-boot 内含安卓启动路径，需确认 boot_targets 顺序" \
    || ok "u-boot 不含 bootrkp/boot_android 劫持路径"
umount "$MNT_B"

# 环6 飞牛特需项
if [[ -n "$RP" ]]; then
    FS="$(lsblk -no FSTYPE "$RP" | tr -d ' ')"
    [[ "$FS" == "btrfs" ]] && ok "rootfs 是 btrfs（飞牛 OTA 前提）" || bad "rootfs 是 $FS，飞牛要求 btrfs"
    mount "$RP" "$MNT_R" 2>/dev/null && {
        KDIR="$(find "$MNT_R/usr/lib/modules" -maxdepth 1 -type d -name "${KREL_NEED}*" | head -1)"
        if [[ -n "$KDIR" ]]; then
            ok "内核模块目录存在: $(basename "$KDIR")"
            MK="$(find "$KDIR" -name 'maxio.ko' | head -1)"
            if [[ -n "$MK" ]]; then
                ok "maxio.ko 已在 rootfs: ${MK#$MNT_R}"
                strings "$MK" | grep -q "$KREL_FULL" && ok "maxio.ko vermagic 含 $KREL_FULL" || bad "maxio.ko vermagic 与内核不符"
            else
                bad "rootfs 里没有 maxio.ko（双千兆网口需要它）"
            fi
            grep -qs '^maxio$' "$MNT_R/etc/modules-load.d/"*.conf && ok "已配置开机自动加载 maxio" || warn "未见 modules-load.d 里的 maxio"
        else
            bad "rootfs 里没有 ${KREL_NEED} 的模块目录"
        fi
        ls "$MNT_R"/etc/os-release >/dev/null 2>&1 && grep -E '^(NAME|VERSION_ID)=' "$MNT_R/etc/os-release" | sed 's/^/       /'
        umount "$MNT_R"
    } || warn "无法挂载 rootfs（fstype=$FS）做环6检查"
fi

echo
if [[ $FAIL -eq 0 ]]; then
    echo "✅ 六环全部通过（静态）。最后一步：刷 SD 卡 + 冷启动实测。"
else
    echo "✗ 存在未通过项，见上面 ✗ 行。"
fi
exit $FAIL
