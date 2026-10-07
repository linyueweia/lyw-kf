#!/usr/bin/env bash
#
# KICKPI K1 (RK3568) 飞牛 fnOS 镜像装配 —— 打通引导链
#
# 安全设计（重要，不可放宽）：
#   本脚本【只对镜像文件操作】，绝不写任何 /dev 设备节点。
#   刷写由用户对 SD 卡执行，eMMC 里正在运行的厂商系统全程只读、不受影响。
#
# 引导链三要素（缺一不可）：
#   1) idbloader.img + u-boot.itb：必须是【为本板编译】的那一对（内嵌 DDR 初始化固件）
#      - T68M 那份是 DDR V1.18，与本板 LPDDR4@1560MHz 不匹配 -> 拒绝
#      - 本板实机 DT: freq_0 = <0x618> = 1560MHz
#   2) DTB：/boot/dtb/rockchip/rk3568-kickpi-k1.dtb（本仓库 dts/ 编译产出）
#   3) root=：必须用【镜像自身 rootfs 分区的 PARTUUID】。
#      !!! 不能写 /dev/mmcblk0p2 —— 在 K1 上 mmcblk0 是 eMMC，
#          照抄 T68M 的配置会挂到厂商 eMMC 根分区（写入风险）。
#
# 用法:
#   BASE=/path/fnnas-base.img  UBOOT_DIR=uboot/rk3568/kickpi-k1  \
#   DTB=dist/rk3568-kickpi-k1.dtb  MODULES_DIR=modules  \
#   ./build-k1-fnos.sh
set -euo pipefail

BASE="${BASE:?需要 BASE=<飞牛基镜像 .img>}"
# UBOOT_DIR 可选：
#   留空 = 保留基镜像自带的引导件（飞牛基镜像本身就是可启动的 RK3568 镜像，
#          这是第一发最稳的打法：只换 DTB 与引导配置，不动 bootloader）
#   指定 = 用为本板编译的那一对覆盖（当基镜像的 DDR 初始化与本板不匹配时才需要）
UBOOT_DIR="${UBOOT_DIR:-}"
DTB="${DTB:?需要 DTB=<rk3568-kickpi-k1.dtb>}"
MODULES_DIR="${MODULES_DIR:-}"
DEVICE_LABEL="${DEVICE_LABEL:-KICKPI-K1}"
BUILD_NUM="${BUILD_NUM:-$(date +%Y%m%d)}"
OUT_DIR="${OUT_DIR:-$(pwd)/out}"

BOOT_MNT=/mnt/k1fnos_boot
ROOT_MNT=/mnt/k1fnos_root
KREL=6.18.18-trim

fail() { echo "✗ $*" >&2; exit 1; }

# ── 安全闸：禁止任何设备路径 ────────────────────────────────
case "$BASE" in /dev/*) fail "BASE 必须是镜像文件，不允许设备节点：$BASE";; esac
for p in "$UBOOT_DIR" "$DTB"; do
    case "$p" in /dev/*) fail "路径必须是文件：$p";; esac
done

echo "==== 0) 前置校验 ===="
[[ -f "$BASE" ]] || fail "基镜像不存在: $BASE"
[[ -f "$DTB" ]] || fail "缺少 DTB: $DTB"

if [[ -n "$UBOOT_DIR" ]]; then
    for f in idbloader.img u-boot.itb; do
        [[ -f "$UBOOT_DIR/$f" ]] || fail "缺少 $UBOOT_DIR/$f"
    done
    DDR_LINE="$(strings "$UBOOT_DIR/idbloader.img" | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -1 || true)"
    echo "  待注入 idbloader DDR 固件: ${DDR_LINE:-未识别}"
    if strings "$UBOOT_DIR/idbloader.img" | grep -q 'V1.18 f366f69a7d'; then
        fail "idbloader 是 T68M 的 DDR V1.18（与本板 1560MHz 不匹配），拒绝使用"
    fi
    echo "  → 将用该 u-boot 对覆盖基镜像自带的引导件"
else
    echo "  → 保留基镜像自带 bootloader（第一发最稳打法）；其 idbloader 的 DDR 固件为:"
    strings "$BASE" -n 8 2>/dev/null | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -2 | sed 's/^/       /' || true
fi
echo "  DTB sha256: $(sha256sum "$DTB" | cut -c1-16)…"

mkdir -p "$OUT_DIR"
IMG="$OUT_DIR/${DEVICE_LABEL}_${BUILD_NUM}.img"

echo
echo "==== 1) 复制基镜像 ===="
cp --reflink=auto "$BASE" "$IMG" || cp "$BASE" "$IMG"
chmod u+w "$IMG"
echo "  ✓ $IMG ($(stat -c%s "$IMG") 字节)"

echo
echo "==== 2) 引导件处理 ===="
if [[ -n "$UBOOT_DIR" ]]; then
    echo "  写入本板 u-boot 对（LBA 64 / 16384）"
    dd if="$UBOOT_DIR/idbloader.img" of="$IMG" bs=512 seek=64    conv=notrunc,fsync status=none
    dd if="$UBOOT_DIR/u-boot.itb"    of="$IMG" bs=512 seek=16384 conv=notrunc,fsync status=none
    sync
    echo "  ✓ 已覆盖写入"
else
    echo "  保留基镜像自带 bootloader（未做任何覆盖）"
    echo "     基镜像 LBA64 处的 DDR 固件:"
    dd if="$IMG" bs=512 skip=64 count=800 status=none 2>/dev/null > /tmp/_k1base_idb.img
    strings /tmp/_k1base_idb.img | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -2 | sed 's/^/       /'
fi

echo
echo "==== 3) 挂载镜像分区，取自身 PARTUUID 并配置引导 ===="
cleanup() {
    mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT" || true
    mountpoint -q "$ROOT_MNT" && umount "$ROOT_MNT" || true
    [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$BOOT_MNT" "$ROOT_MNT"
LOOP="$(losetup -fP --show "$IMG")"
sleep 1
BOOT_PART="${LOOP}p1"; ROOT_PART="${LOOP}p2"
[[ -e "$BOOT_PART" ]] || fail "镜像没有 boot 分区"
[[ -e "$ROOT_PART" ]] || fail "镜像没有 rootfs 分区"

ROOT_PARTUUID="$(lsblk -no PARTUUID "$ROOT_PART" | tr -d ' ')"
[[ -n "$ROOT_PARTUUID" ]] || fail "取不到 rootfs PARTUUID"
echo "  rootfs PARTUUID = $ROOT_PARTUUID  ← 用它引导（不使用 /dev/mmcblk0*）"

mount "$BOOT_PART" "$BOOT_MNT" || fail "挂载 boot 分区失败"
echo "  ── 基镜像 BOOT 分区原有内容（前 20 项）──"
ls "$BOOT_MNT" | head -20 | sed 's/^/     /'

DTB_NAME="$(basename "$DTB")"
mkdir -p "$BOOT_MNT/dtb/rockchip"
cp -f "$DTB" "$BOOT_MNT/dtb/rockchip/$DTB_NAME"

cat > "$BOOT_MNT/fnEnv.txt" <<EOF
verbosity=1
bootlogo=false
console=both
extraargs=cma=256M
fdtfile=rockchip/$DTB_NAME
EOF

mkdir -p "$BOOT_MNT/extlinux"
cat > "$BOOT_MNT/extlinux/extlinux.conf" <<EOF
label fnOS (KICKPI K1)
    kernel /vmlinuz
    fdt /dtb/rockchip/$DTB_NAME
    append earlycon=uart8250,mmio32,0xfe660000 console=ttyS2,1500000 splash=verbose cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory cma=256M root=PARTUUID=$ROOT_PARTUUID rw rootwait
EOF

echo "  ── 写入后的 extlinux.conf ──"
sed 's/^/     /' "$BOOT_MNT/extlinux/extlinux.conf"
sync
umount "$BOOT_MNT"

echo
echo "==== 4) rootfs 注入（模块/固件）===="
mount "$ROOT_PART" "$ROOT_MNT" || fail "挂载 rootfs 失败"
echo "  rootfs 类型: $(lsblk -no FSTYPE "$ROOT_PART")"

if [[ -n "$MODULES_DIR" && -d "$MODULES_DIR" ]]; then
    KDIR="$ROOT_MNT/usr/lib/modules/$KREL"
    [[ -d "$KDIR" ]] || fail "rootfs 里没有 /usr/lib/modules/$KREL（内核版本不符？）"
    mkdir -p "$KDIR/updates/kickpi-k1"
    n=0
    while IFS= read -r ko; do
        cp -f "$ko" "$KDIR/updates/kickpi-k1/"
        n=$((n+1))
        echo "     + $(basename "$ko")"
    done < <(find "$MODULES_DIR" -name '*.ko' | sort)
    echo "  ✓ 注入模块 $n 个"

    if [[ -n "$(ls -A "$MODULES_DIR"/firmware 2>/dev/null || true)" ]]; then
        mkdir -p "$ROOT_MNT/lib/firmware"
        cp -rf "$MODULES_DIR"/firmware/. "$ROOT_MNT/lib/firmware/"
        echo "  ✓ 注入固件 $(find "$MODULES_DIR"/firmware -type f | wc -l) 个"
    fi

    # 开机自动加载（网络依赖 PHY 驱动先就位）
    mkdir -p "$ROOT_MNT/etc/modules-load.d"
    cat > "$ROOT_MNT/etc/modules-load.d/kickpi-k1.conf" <<EOF
# KICKPI K1 板级模块：Maxio PHY 必须先于 dwmac 就位，否则网口会绑到通用 PHY
maxio
EOF
    # 不依赖 depmod 的保险：用一个 systemd oneshot 按【绝对路径】insmod。
    # 理由：depmod 需要在 chroot 里跑 arm64 二进制（要 qemu/binfmt）；
    #       万一环境不具备，这套按路径加载仍然有效。
    mkdir -p "$ROOT_MNT/etc/systemd/system"
    {
      echo "[Unit]"
      echo "Description=Load KICKPI K1 board modules (absolute-path insmod)"
      echo "DefaultDependencies=no"
      echo "Before=network-pre.target systemd-modules-load.service"
      echo "After=local-fs.target"
      echo ""
      echo "[Service]"
      echo "Type=oneshot"
      echo "RemainAfterExit=yes"
      echo "ExecStart=/bin/sh -c 'for m in maxio swt6621s_wifi skw_sdio_lite skwbt; do /sbin/insmod /usr/lib/modules/$KREL/updates/kickpi-k1/$m.ko 2>/dev/null || true; done'"
      echo ""
      echo "[Install]"
      echo "WantedBy=sysinit.target"
    } > "$ROOT_MNT/etc/systemd/system/kickpi-k1-modules.service"
    mkdir -p "$ROOT_MNT/etc/systemd/system/sysinit.target.wants"
    ln -sf ../kickpi-k1-modules.service "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/kickpi-k1-modules.service"
    echo "  ✓ 已装 systemd 绝对路径加载单元（不依赖 depmod）"

    # 能的话再刷新模块依赖（arm64 chroot 需要 qemu/binfmt）
    if [[ -x "$ROOT_MNT/usr/bin/depmod" ]] && command -v qemu-aarch64-static >/dev/null 2>&1; then
        cp -f "$(command -v qemu-aarch64-static)" "$ROOT_MNT/usr/bin/" 2>/dev/null || true
        chroot "$ROOT_MNT" depmod -a "$KREL" 2>/dev/null \
            && echo "  ✓ depmod 已刷新（qemu）" \
            || echo "  ⚠ depmod 未成功，已由上面的绝对路径单元兜底"
    else
        echo "  ℹ 无 qemu-aarch64-static，跳过 depmod（由绝对路径单元兜底）"
    fi
fi

# OTA 引导同步脚本（若基镜像自带则保留）
sync
umount "$ROOT_MNT"

echo
echo "==== 5) 产出校验 ===="
LOOP2="$(losetup -fP --show "$IMG")"
mount "${LOOP2}p1" "$BOOT_MNT"
V_DTB="$(sha256sum "$BOOT_MNT/dtb/rockchip/$DTB_NAME" | awk '{print $1}')"
V_SRC="$(sha256sum "$DTB" | awk '{print $1}')"
[[ "$V_DTB" == "$V_SRC" ]] && echo "  ✓ 镜像内 DTB sha256 与源一致（${V_SRC:0:16}…）" || fail "镜像内 DTB 与源不一致"
grep -q "root=PARTUUID=$ROOT_PARTUUID" "$BOOT_MNT/extlinux/extlinux.conf" \
    && echo "  ✓ 引导 root= 指向镜像自身 PARTUUID（不会误挂 eMMC）" || fail "root= 校验失败"
grep -q "fdtfile=rockchip/$DTB_NAME" "$BOOT_MNT/fnEnv.txt" \
    && echo "  ✓ fnEnv fdtfile 正确" || fail "fnEnv 校验失败"
umount "$BOOT_MNT"
losetup -d "$LOOP2"

echo
echo "==== 6) 压缩与摘要 ===="
xz -T0 -9 -c "$IMG" > "$IMG.xz"
( cd "$OUT_DIR" && sha256sum "$(basename "$IMG").xz" > SHA256SUMS )
echo "  ✓ $IMG.xz ($(stat -c%s "$IMG.xz") 字节)"
cat "$OUT_DIR/SHA256SUMS" | sed 's/^/     /'
echo
echo "🎉 完成。刷写（由用户对 SD 卡执行，例如 /dev/sdX 或 /dev/mmcblk1）："
echo "   xz -dc $(basename "$IMG").xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
