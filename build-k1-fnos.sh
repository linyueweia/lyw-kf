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
#   BASE=/path/fnnas-base.img  DTB=dist/rk3568-kickpi-k1.dtb  \
#   MODULES_DIR=modules  ./build-k1-fnos.sh
set -euo pipefail

# umount 加固：实测出现过 "target is busy" 让 set -e 直接退出（该做的都做完了却判失败）。
# 先 sync 落盘，再重试，最后惰性卸载兜底；任何情况下都不因此中断构建。
umount_safe() {
    local mnt="$1" i
    sync
    for i in 1 2 3; do
        umount "$mnt" 2>/dev/null && return 0
        sleep 2
    done
    umount -l "$mnt" 2>/dev/null && echo "  ⚠ $mnt 忙，已惰性卸载（数据已 sync）" && return 0
    return 0
}

BASE="${BASE:?需要 BASE=<飞牛基镜像 .img>}"
# u-boot：默认用 uboot/k1-ki-first32m.bin（由 lyw-ki 仓构建的 K1 iStoreOS 引导件，
#   U-Boot 2025.10-OpenWrt-r33609 + ddr-v1.23-03ea844c5d，boot_targets 本就 mmc 优先），
#   由 workflow 通过 UBOOT= 传入；不传则保留基镜像自带前导区（v1.0.0 回滚场景）。
#   注入只写载荷区 [17408, 32MiB)，GPT 必保留。
DTB="${DTB:?需要 DTB=<rk3568-kickpi-k1.dtb>}"
MODULES_DIR="${MODULES_DIR:-}"
# 产物命名（2026-10-15 用户定案）：fnos_<地区>_<架构>_<Debian主版本>_<板型>.img
#   例：fnos_Mainland-PE_arm_12_Kickpi-k1.img —— 一眼对齐飞牛官方镜像风格。
#   分段可用环境变量覆盖；IMG_NAME 可整体覆盖（CI/本地都不再依赖旧 DEVICE_LABEL_<num> 名）。
OS_NAME="${OS_NAME:-fnos}"
IMG_REGION="${IMG_REGION:-Mainland-PE}"
IMG_ARCH="${IMG_ARCH:-arm}"
IMG_DEBIAN_MAJOR="${IMG_DEBIAN_MAJOR:-12}"
IMG_BOARD="${IMG_BOARD:-Kickpi-k1}"
IMG_NAME="${IMG_NAME:-${OS_NAME}_${IMG_REGION}_${IMG_ARCH}_${IMG_DEBIAN_MAJOR}_${IMG_BOARD}.img}"
BUILD_NUM="${BUILD_NUM:-$(date +%Y%m%d)}"   # 仅留作构建日志追溯，不再进产物名（release tag + SHA256SUMS 可追溯）
OUT_DIR="${OUT_DIR:-$(pwd)/out}"

BOOT_MNT=/mnt/k1fnos_boot
ROOT_MNT=/mnt/k1fnos_root
# 内核版本不写死：从基镜像 BOOT 分区里的 vmlinuz-* / config-* 自动探测。
# 教训：社区内核包是 6.18.18-trim，而飞牛基镜像自带的是 6.18.18.cNNN-trim
#       （v1.1.0 = c1145；c951 是上一版基镜像），两者的 vermagic 不同，
#       用错版本编出的 .ko 一个都加载不了。
KREL="${KREL:-}"

fail() { echo "✗ $*" >&2; exit 1; }

# ── fnEnv 改键的唯一实现（原子、无固定临时文件名）────────────────────────────
# 教训（2026-10-27 CI run#69）：旧写法用固定 /tmp/_fnenv.keep，在共享 /tmp 上撞到
# 「Permission denied」直接把装配打断（同名文件属主/属性不可控，并发构建还会互相覆盖）。
# 现在临时文件建在 BOOT 分区内：同文件系统、名字唯一（mktemp），失败即硬失败。
fnenv_set() {   # fnenv_set <key> <完整新行>
    local key="$1" line="$2" tmp
    [[ -f "$BOOT_MNT/fnEnv.txt" ]] || fail "fnEnv.txt 不存在（$BOOT_MNT）"
    tmp="$(mktemp "$BOOT_MNT/.fnenv.XXXXXX")" || fail "无法在 BOOT 分区建临时文件（分区只读？）"
    grep -v "^${key}=" "$BOOT_MNT/fnEnv.txt" > "$tmp" || true
    printf '%s\n' "$line" >> "$tmp"
    cat "$tmp" > "$BOOT_MNT/fnEnv.txt" || { rm -f "$tmp"; fail "写回 fnEnv.txt 失败"; }
    rm -f "$tmp"
    grep -q "^${key}=" "$BOOT_MNT/fnEnv.txt" || fail "fnEnv.txt 里 ${key}= 没写进去（写回异常）"
}

# ── 安全闸：禁止任何设备路径 ────────────────────────────────
case "$BASE" in /dev/*) fail "BASE 必须是镜像文件，不允许设备节点：$BASE";; esac
for p in "$DTB"; do
    case "$p" in /dev/*) fail "路径必须是文件：$p";; esac
done

echo "==== 0) 前置校验 ===="
[[ -f "$BASE" ]] || fail "基镜像不存在: $BASE"
[[ -f "$DTB" ]] || fail "缺少 DTB: $DTB"

# 保留基镜像自带 bootloader（2026-10-08 实测：自建 v1.26 SPL 断，
# 基镜像 v1.23 与本板 eMMC 原厂同哈希）；同时断言其 DDR 不是已知坏值。
echo "  → 使用基镜像自带 bootloader；其 idbloader 的 DDR 固件为:"
strings "$BASE" -n 8 2>/dev/null | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -2 | sed 's/^/       /' || true
if strings "$BASE" -n 8 2>/dev/null | grep -q 'V1.18 f366f69a7d'; then
    fail "基镜像 idbloader 是 T68M 的 DDR V1.18（与本板 1560MHz 不匹配），拒绝使用"
fi
echo "  DTB sha256: $(sha256sum "$DTB" | cut -c1-16)…"

mkdir -p "$OUT_DIR"
IMG="$OUT_DIR/$IMG_NAME"

echo
echo "==== 1) 复制基镜像 ===="
cp --reflink=auto "$BASE" "$IMG" || cp "$BASE" "$IMG"
chmod u+w "$IMG"
echo "  ✓ $IMG ($(stat -c%s "$IMG") 字节)"

# ── U-Boot 注入（本板引导件）────────────────────────────────────────
# 基镜像 v1.1.0 起前导区为零（3568/3588 无法共用一份 U-Boot）。
# K1 用 uboot/k1-ki-first32m.bin —— 由【lyw-ki（K1 iStoreOS）仓库构建】的 U-Boot：
#   U-Boot 2025.10-OpenWrt-r33609-283d02639c + ddr-v1.23-03ea844c5d（与本板 eMMC 原厂同版本）
#   内置 boot_targets=mmc1 mmc0 nvme scsi usb …（本来就是 mmc 优先，无需就地改字节）
#   内置 fdtfile=rockchip/rk3568-easepi.dtb（非本板，由 p1/fnEnv.txt 覆盖，官方机制）
#   取法：gzip -dc istoreos-*-kickpi_k1-squashfs-sysupgrade.img.gz | head -c 32M
# 原注释：
# 与本板 eMMC 原厂同哈希）。注入只写 [17408, 32MiB) 载荷区，镜像 GPT 保留。
# 基镜像若自带前导区（v1.0.0 回滚场景）则不注入、原样保留 —— 行为与历史版本一致。
if [[ -n "${UBOOT:-}" ]]; then
    [[ -f "$UBOOT" ]] || fail "UBOOT 文件不存在: $UBOOT"
    [[ "$(stat -c%s "$UBOOT")" -eq 33554432 ]] || fail "UBOOT 必须是 32MiB 提取件"
    python3 - "$IMG" "$UBOOT" <<'PYEOF'
import sys, hashlib, struct
img, ub = sys.argv[1], sys.argv[2]
d0 = open(img, 'rb').read(32*1024*1024)
# 只看载荷区 [17408:]：GPT（前17408字节）本来就非零，整段判零会永远误判不注入
if sum(1 for b in d0[17408:] if b) > 0:
    print("  （载荷区非零 —— 基镜像自带 U-Boot，保留原样不注入）")
    sys.exit(0)
u = open(ub, 'rb').read()
with open(img, 'r+b') as f:
    f.seek(17408)
    f.write(u[17408:])
d = open(img, 'rb').read(0x800010)
assert d[0x8000:0x8004] == b'RKNS', "idbloader 魔数不对"
assert d[0x800000:0x800004] == bytes.fromhex('d00dfeed'), "FIT 魔数不对"
assert d[512:520] == b'EFI PART', "镜像 GPT 头丢失"
f = open(img, 'rb'); f.seek(512); h = f.read(92)
pl, = struct.unpack('<Q', h[72:80])
f.seek(pl*512); e = f.read(128)
s, = struct.unpack('<Q', e[32:40])
assert s == 65536, f"p1 起始 LBA 变了: {s}"
print("  ✓ U-Boot 注入断言通过（RKNS + FIT + GPT 保留 + p1@65536）")
PYEOF
    echo "  ✓ 已注入 K1 本板 U-Boot（载荷区 [17408,32MiB)）"
else
    echo "  （未传 UBOOT —— 前导区保持基镜像原样）"
fi


echo
echo "==== 2) 引导件处理 ===="
echo "  引导件已就位（注入件或基镜像原生，见上方注入日志）"
echo "     产物 LBA64 处的 DDR 固件:"
IDB_TMP="$(mktemp)"
dd if="$IMG" bs=512 skip=64 count=800 status=none 2>/dev/null > "$IDB_TMP"
strings "$IDB_TMP" | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -2 | sed 's/^/       /' || echo "       （无 DDR 串 —— 前导区待注入或已清零）"
rm -f "$IDB_TMP"

echo
echo "==== 2b) 断言 U-Boot 内置默认 env 的 boot_targets 是 mmc 优先（必要时就地改写）===="
# 历史背景：早期注入的是基镜像自带的 armbian U-Boot（2026.04-TRIM-c218），
#   内置 boot_targets=usb mmc1 mmc0 … 且 fdtfile=rk3568-nanopi-r5s.dtb（别板）。
#   bootflow scan 扫到第一个有效 bootflow 就启动 → 开机前插着 USB 盘会先枚举 USB，
#   在轮到 SD/eMMC 之前卡住，表现就是"起不来"。
# 现状：改用【lyw-ki 仓库构建】的 U-Boot（2025.10-OpenWrt），内置 boot_targets 本身就是
#   mmc1 mmc0 nvme scsi usb …（mmc 优先），本步骤退化为"断言 + 必要时改写"：
#   · 已是 mmc 优先 → patch 工具打印"已是新值"，不做任何写入（也就不需要重签 FIT）
#   · 仍是 usb 优先 → 等长就地改写 36 字节 + 2c 重签 FIT（缺一不可，见 2c 的血泪史）
if python3 "$(dirname "$0")/tools/patch-uboot-boot-targets.py" "$IMG"; then
    echo "  ✓ boot_targets 已为 mmc 优先"
else
    echo "  ⚠ patch-uboot-boot-targets 未成功（可能已改过，或写入的是自有 u-boot）"
    echo "     若使用自有 u-boot，请确认其内置 env 的 boot_targets 也是 mmc1 在前"
fi

echo
echo "==== 2c) FIT 哈希重签（必做门禁）===="
# ⚠ 血的教训（2026-10-12 实机）：2b 就地改写了 FIT 内 u-boot 负载的 13 字节，
# 但 FIT 里 u-boot 节点的 sha256 没重算 → SPL 校验：
#     ## Checking hash(es) for Image u-boot ... sha256 error!
#     SPL: failed to boot from all boot devices
# 也就是【镜像刷进 eMMC 必然起不来】，TF 卡同样起不来。任何对 FIT 内负载的
# 就地改写之后，都必须用 tools/fit-resign.py 重签并复核，这里做成硬门禁。
FIT_TOOL="$(dirname "$0")/tools/fit-resign.py"
if [[ -f "$FIT_TOOL" ]]; then
    python3 "$FIT_TOOL" --fix "$IMG" || true
    python3 "$FIT_TOOL" "$IMG" \
        || fail "FIT 哈希校验未通过（u-boot/atf/fdt 节点 sha256 与负载不符 → SPL 必然拒载）"
    echo "  ✓ FIT 全部 image 节点哈希自洽"
else
    fail "缺少 tools/fit-resign.py：改写 FIT 内负载后不重签，SPL 会拒绝启动"
fi

echo
echo "==== 3) 挂载镜像分区，取自身 PARTUUID 并配置引导 ===="
cleanup() {
    mountpoint -q "$BOOT_MNT" && umount_safe "$BOOT_MNT" || true
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

# 探测内核版本（vmlinuz-<rel> 或 config-<rel>）
if [[ -z "$KREL" ]]; then
    KREL="$(ls "$BOOT_MNT" 2>/dev/null | sed -n 's/^vmlinuz-//p' | head -1)"
    [[ -z "$KREL" ]] && KREL="$(ls "$BOOT_MNT" 2>/dev/null | sed -n 's/^config-//p' | head -1)"
fi
[[ -n "$KREL" ]] || fail "无法从 BOOT 分区探测内核版本"
echo "  内核版本(KREL) = $KREL"
echo "  BOOT 分区里的内核/配置: $(ls "$BOOT_MNT" | grep -E '^(vmlinuz|config|System.map)' | tr '\n' ' ')"

DTB_NAME="$(basename "$DTB")"
mkdir -p "$BOOT_MNT/dtb/rockchip"
cp -f "$DTB" "$BOOT_MNT/dtb/rockchip/$DTB_NAME"

# 保留基镜像原有 fnEnv.txt 的字段（kernelfile= 等），只改/增 fdtfile。
# 理由：飞牛的 boot.scr 依赖 fnEnv 里的 kernelfile 等键，整份覆盖会把引导搞坏
#      （xck-nas 2026-10-27 实测：整份覆盖把 kernelfile 钉死在旧内核名上 → 刷进去必黑）。
if [[ -f "$BOOT_MNT/fnEnv.txt" ]]; then
    echo "  ── 基镜像原有 fnEnv.txt（保留其字段）──"
    sed 's/^/     /' "$BOOT_MNT/fnEnv.txt"
    fnenv_set fdtfile "fdtfile=rockchip/$DTB_NAME"
else
    cat > "$BOOT_MNT/fnEnv.txt" <<EOF
verbosity=1
bootlogo=false
console=both
extraargs=cma=256M
fdtfile=rockchip/$DTB_NAME
EOF
fi

# ── 引导：完全按飞牛官方做法走 boot.scr 链路（不生成 extlinux.conf）────────────
# 官方基镜像 BOOT 分区里只有 boot.cmd / boot.scr / fnEnv.txt / grub，没有 extlinux/。
# 官方 boot.cmd 每次启动【现场】取分区身份，从不写死：
#     part uuid ${devtype} ${devnum}:${distro_bootpart} bootuuid
#     part uuid ${devtype} ${devnum}:${distro_rootpart} rootuuid
#     setenv bootargs "root=PARTUUID=${rootuuid} … ubootpart=PARTUUID=${bootuuid} …"
# 内核用 kernelfile=vmlinuz（软链）跟随最新内核 → 在线更新天然兼容；
# 要回退旧内核时改 fnEnv.txt 的 kernelfile=/vmlinuz-<旧内核> 即可（官方键）。
# 之前仓库自造的 extlinux.conf 是静态 root=PARTUUID=（构建期读到的值，继承自官方
# 基镜像、所有产物都一样），u-boot 又优先走 extlinux → TF 卡与 eMMC 双介质并存会串盘。
# CMA 与官方 R5S 对齐 = **256M**（2026-10-27 定案）：官方 R5S 的 fnEnv.txt 就是
# extraargs=cma=256M，官方 DTB 里也没有 reserved-memory CMA 区 —— cmdline 的 cma= 是
# 唯一决定因素。历史 1G 只是绕开相册 AI 的 339MB 连续申请，不是官方形态，不要放大回去。
K1_EXTRAARGS="cma=256M"
fnenv_set extraargs "extraargs=$K1_EXTRAARGS"

# ── 硬门禁 1：kernelfile 必须指向真实存在、且确是 arm64 内核的文件 ─────────────
# 这是"刷进去必黑"的真实事故类（xck-nas 2026-10-27：fnEnv 被整份覆盖成旧内核名 →
# boot.scr 按名取不到内核 → 黑屏、串口零输出、无任何报错）。规则：
#   · 缺 kernelfile= → 补 vmlinuz（官方软链）；没有软链就取唯一的 vmlinuz-*；
#   · 指向的文件不存在 → 自动改成本板唯一的 vmlinuz-*，一个都没有则硬失败；
#   · 目标必须 >5MB，且是 ARM64 Image（偏移 0x38 = "ARM\x64"）或 gzip。
KF_LINE="$(grep -m1 '^kernelfile=' "$BOOT_MNT/fnEnv.txt" || true)"
KF_NAME="${KF_LINE#kernelfile=}"; KF_NAME="${KF_NAME#/}"
if [[ -z "$KF_NAME" ]]; then
    if [[ -e "$BOOT_MNT/vmlinuz" ]]; then
        KF_NAME="vmlinuz"
    else
        KF_NAME="$(cd "$BOOT_MNT" && ls -1 vmlinuz-* 2>/dev/null | head -1 || true)"
        [[ -n "$KF_NAME" ]] || fail "BOOT 分区没有任何内核文件（fnEnv 也没写 kernelfile）→ 刷进去必黑"
    fi
    echo "kernelfile=$KF_NAME" >> "$BOOT_MNT/fnEnv.txt"
    echo "  ✓ fnEnv 缺 kernelfile，已补 $KF_NAME"
fi
if [[ ! -e "$BOOT_MNT/$KF_NAME" ]]; then
    ALT="$(cd "$BOOT_MNT" && ls -1 vmlinuz-* 2>/dev/null | head -1 || true)"
    [[ -n "$ALT" ]] || fail "fnEnv 的 kernelfile=$KF_NAME 不存在，且 BOOT 分区没有 vmlinuz-* 可替换 → 刷进去必黑"
    fnenv_set kernelfile "kernelfile=$ALT"
    echo "  ⚠ fnEnv 的 kernelfile=$KF_NAME 不存在，已自动改为 $ALT（基镜像换版后未同步）"
    KF_NAME="$ALT"
fi
KF_REAL="$(readlink -f "$BOOT_MNT/$KF_NAME")"
KF_SIZE="$(stat -c%s "$KF_REAL" 2>/dev/null || echo 0)"
[[ "$KF_SIZE" -gt 5242880 ]] || fail "kernelfile=$KF_NAME 只有 $KF_SIZE 字节（<5MB），不是完整内核 → 刷进去必黑"
KF_KIND="$(python3 - "$KF_REAL" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read(0x10000)
if d[:2] == b'\x1f\x8b':
    print('gzip')
elif d[0x38:0x3c] == b'ARM\x64':
    print('arm64-Image')
else:
    print('unknown')
PY
)"
[[ "$KF_KIND" != "unknown" ]] || fail "kernelfile=$KF_NAME 既不是 arm64 Image 也不是 gzip → 不是内核（刷进去必黑）"
echo "  ✓ kernelfile=$KF_NAME（$KF_KIND，$KF_SIZE 字节）"

# ── 硬门禁 2：extraargs 的 CMA 必须与官方 R5S 口径一致（256M），且**不得夹带调试参数** ──
# 旧写法只 grep '.*cma=256M'，于是 "cma=256M loglevel=7 ignore_loglevel" 也算通过 ——
# 实机取证过：设备 fnEnv 正是这串，开机全程刷屏。现在改成整行精确匹配。
EX_LINE="$(grep '^extraargs=' "$BOOT_MNT/fnEnv.txt" | head -1 || true)"
[[ "$EX_LINE" == "extraargs=cma=256M" ]] \
    || fail "fnEnv extraargs 必须是 'extraargs=cma=256M'（不得含 loglevel/ignore_loglevel 等调试参数，官方 R5S 口径）：$EX_LINE"
echo "  ✓ extraargs = extraargs=cma=256M（与官方 R5S 对齐、无调试参数）"
# 历史构建残留/回退用的 extlinux.conf：改名即不参与引导（u-boot 只认该文件名）
if [[ -f "$BOOT_MNT/extlinux/extlinux.conf" ]]; then
    mv -f "$BOOT_MNT/extlinux/extlinux.conf" "$BOOT_MNT/extlinux/extlinux.conf.k1-off"
    echo "  ✓ 已停用 extlinux.conf →（.k1-off），引导交回官方 boot.scr"
fi
# 留一份静态配置当回退材料（u-boot 不识别这个名字，不参与引导）
mkdir -p "$BOOT_MNT/extlinux"
cat > "$BOOT_MNT/extlinux/extlinux.conf.k1-static" <<EOF
label fnOS (KICKPI K1)
    kernel /vmlinuz
    fdt /dtb/rockchip/$DTB_NAME
    append earlycon=uart8250,mmio32,0xfe660000 console=ttyS2,1500000 splash=verbose cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory cma=256M root=PARTUUID=$ROOT_PARTUUID rw rootwait
EOF

echo "  ── 引导配置（官方 fnEnv.txt，boot.scr 现场取 PARTUUID）──"
sed 's/^/     /' "$BOOT_MNT/fnEnv.txt"
sync
umount_safe "$BOOT_MNT"

echo
echo "==== 4) rootfs 注入（模块/固件）===="
mount "$ROOT_PART" "$ROOT_MNT" || fail "挂载 rootfs 失败"
echo "  rootfs 类型: $(lsblk -no FSTYPE "$ROOT_PART")"

if [[ -n "$MODULES_DIR" && -d "$MODULES_DIR" ]]; then
    KDIR="$ROOT_MNT/usr/lib/modules/$KREL"
    if [[ ! -d "$KDIR" ]]; then
        echo "  rootfs 里现有的模块目录:"
        ls "$ROOT_MNT/usr/lib/modules" 2>/dev/null | sed 's/^/     /'
        fail "rootfs 里没有 /usr/lib/modules/$KREL"
    fi
    # vermagic 硬闸：模块必须与镜像内核 release 完全一致，否则加载不了（本次已实际踩到）
    for ko in $(find "$MODULES_DIR" -name '*.ko'); do
        vm="$(strings "$ko" | grep -oE 'vermagic=[^\"]*' | head -1)"
        case "$vm" in
            *"$KREL"*) echo "     ✓ $(basename "$ko") vermagic 匹配 ($vm)";;
            *) fail "$(basename "$ko") 的 vermagic 与镜像内核不符：$vm（镜像要求含 $KREL）";;
        esac
    done
    mkdir -p "$KDIR/updates/kickpi-k1"
    n=0
    while IFS= read -r ko; do
        cp -f "$ko" "$KDIR/updates/kickpi-k1/"
        n=$((n+1))
        echo "     + $(basename "$ko")"
    done < <(find "$MODULES_DIR" -name '*.ko' | sort)
    echo "  ✓ 注入模块 $n 个"

    # 固件一律从【仓库自带】modules/firmware 取（15 个，实机同款）——
    # 旧逻辑只认 $MODULES_DIR/firmware，而 CI 用 built-modules 目录（没有 firmware）
    # → 15 个 SWT6621S_* 一个都没进镜像且完全无提示（取证 A3：6 次 CI 均如此）。
    REPO_FW="$(dirname "$(readlink -f "$0")")/modules/firmware"
    FW_SRC=""
    if compgen -G "$REPO_FW/SWT6621S_*" >/dev/null; then FW_SRC="$REPO_FW"
    elif compgen -G "$MODULES_DIR/firmware/SWT6621S_*" >/dev/null; then FW_SRC="$MODULES_DIR/firmware"
    fi
    [[ -n "$FW_SRC" ]] || fail "找不到 SWT6621S 固件（$REPO_FW 与 $MODULES_DIR/firmware 均无）"
    mkdir -p "$ROOT_MNT/lib/firmware"
    cp -rf "$FW_SRC"/. "$ROOT_MNT/lib/firmware/"
    FW_N=$(find "$ROOT_MNT/lib/firmware" -maxdepth 1 -name 'SWT6621S_*' | wc -l)
    # ≥15：v1.1.0 起 fnOS 官方 rootfs 自带 seekwave 官方固件，注入后会多出几个（无害）；
    # 少于 15 = 仓库固件没进镜像（取证 A3 的回归），照炸。
    [[ "$FW_N" -ge 15 ]] || fail "镜像内 SWT6621S 固件 $FW_N 个 < 15（仓库实机同款必须全在位）"
    # ★2026-10-12 实机修复：seekwave 驱动请求的路径带子目录前缀，
    #   如 seekwave/SWT6621S_SEEKWAVE_R00001.bin、seekwave/swt6621s_wifi.dat。
    #   只装根目录 → 驱动 -2 找不到 → skw_calib_download 失败 → wifi service 中止 →
    #   没有 wlan0（实机复现：卡识别成功、boot 成功、卡在 calib 固件）。
    #   /lib/firmware/seekwave/ 原有 8 月手放的旧文件且缺 3 个关键 .bin，同样会踩坑。
    mkdir -p "$ROOT_MNT/lib/firmware/seekwave"
    cp -rf "$FW_SRC"/. "$ROOT_MNT/lib/firmware/seekwave/"
    FW_S=$(find "$ROOT_MNT/lib/firmware/seekwave" -maxdepth 1 -name 'SWT6621S_*' | wc -l)
    [[ "$FW_S" -ge 15 ]] || fail "seekwave/ 子目录固件 $FW_S 个 < 15（驱动实际请求该路径，仓库15个必须全在位）"
    echo "  ✓ 注入固件 15 个（$FW_SRC）→ /lib/firmware/ 与 /lib/firmware/seekwave/ 双路径（seekwave/ 现共 $FW_S 个）"

    # 开机自动加载（网络依赖 PHY 驱动先就位）
    mkdir -p "$ROOT_MNT/etc/modules-load.d"
    cat > "$ROOT_MNT/etc/modules-load.d/kickpi-k1.conf" <<EOF
# KICKPI K1 板级网络模块：开机【显式】加载，绝不依赖 udev 自动加载。
#   maxio     Maxio MAE0621A PHY 驱动，必须先于 MAC 驱动注册
#   stmmac    GMAC 公共层
#   dwmac_rk  两个 GMAC 的平台驱动。本内核 CONFIG_DWMAC_ROCKCHIP=m：
#             不加载 → 不 probe → 不输出 RGMII 参考时钟(clock_in_out="output")
#             → PHY 无时钟 → 链路灯全灭、两口起不来（实机症状）。
# 顺序由本文件逐行执行 + modprobe.d 的 softdep 双重保证。
maxio
stmmac
dwmac_rk
EOF
    # 顺序的第二重保障：modprobe 走 softdep，保证 maxio 先于 stmmac/dwmac_rk 注册。
    # 否则 netdev 首次 up 时 phy_attach_direct() 先绑 Generic PHY，晚到的 maxio 被
    # __device_attach 跳过 → 必须 ifdown/ifup 才可能换绑（取证 A1 的 driver-core 依据）。
    # （历史教训：此前只放 maxio、把 dwmac_rk 完全交给 udev 冷插拔，实机就是开机不加载。）
    mkdir -p "$ROOT_MNT/etc/modprobe.d"
    cat > "$ROOT_MNT/etc/modprobe.d/kickpi-k1.conf" <<'SOFTEOF'
# KICKPI K1: Maxio MAE0621A PHY 驱动必须先于 stmmac/dwmac 注册
softdep dwmac_rk pre: maxio
softdep stmmac pre: maxio
# KICKPI K1: WiFi/BT 有符号依赖，modprobe 必须先拉公共层
#   swt6621s_wifi 未定义 cfg80211_* / rfkill_* → 不先装 cfg80211+rfkill 就是 err -2
#   skwbt        未定义 hci_*                → 不先装 bluetooth+rfkill 就是符号缺失
# （modules.dep 已由 depmod -b 正确生成，softdep 是 insmod 路径的第二重保险）
softdep swt6621s_wifi pre: cfg80211 rfkill
softdep skwbt pre: bluetooth rfkill
SOFTEOF
    echo "  ✓ modprobe.d softdep（maxio 先于 dwmac_rk/stmmac；cfg80211/rfkill 先于 swt6621s_wifi；bluetooth/rfkill 先于 skwbt）"
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
      # 注意 \$m 必须转义：这是给【内层 /bin/sh】用的变量，若被本脚本展开，
      # 在 set -u 下会直接报 "m: unbound variable" 并中断构建（实测踩到）。
      # ExecStart 在【构建期】就展开成逐个 insmod 的字面命令：内层 sh 不再有 $ 变量，
      # 既不会被本脚本 set -u 判 "m: unbound variable"，也不会被 systemd 变量展开吃掉路径。
      CMD=""
      # 无外部依赖的模块继续用【绝对路径 insmod】：不依赖 depmod，也不受
      # modules.dep 是否刷新影响（maxio/skw_sdio_lite 的 modules.dep 依赖为空）。
      for m in maxio skw_sdio_lite; do
        [[ -n "$CMD" ]] && CMD="$CMD; "
        # 提示语不能含引号/空格/括号：它们会破坏 ExecStart 的引号嵌套，
        # 导致 sh -c 只拿到第一个命令、后面全被当成位置参数（实测 argv 会裂成 15 项，
        # 结果只有第一条 insmod 真正执行）。
        CMD="$CMD/sbin/insmod /usr/lib/modules/$KREL/updates/kickpi-k1/$m.ko || echo insmod-failed:$m"
      done
      # 有符号依赖的模块必须走 modprobe：insmod 不解析依赖 → 必然符号缺失。
      #   swt6621s_wifi 依赖 cfg80211 + rfkill（实机：57 个 cfg80211_* err -2）
      #   skwbt        依赖 bluetooth + rfkill（实机：5 个 hci_* 缺失）
      # modules.dep 已由 depmod -b 生成正确依赖链，modprobe 会先拉公共层；
      # modprobe.d 的 softdep 是第二重保障。
      CMD="$CMD; /sbin/modprobe swt6621s_wifi || echo modprobe-failed:swt6621s_wifi"
      CMD="$CMD; /sbin/modprobe skwbt || echo modprobe-failed:skwbt"
      # 两个 GMAC 的 MAC 驱动：本内核 =m，必须由本单元【确定性】拉起，不能只等 udev
      # 冷插拔（实机症状：开机不加载 → 不输出 RGMII 参考时钟 → PHY 无时钟 → 灯全灭）。
      # 用 modprobe 而不是 insmod：dwmac_rk 依赖 pcs_xpcs/stmmac/stmmac-platform，
      # insmod 不解析依赖会直接失败；modprobe 同时会按 softdep 保证 maxio 已先行注册。
      CMD="$CMD; /sbin/modprobe stmmac || echo modprobe-failed:stmmac"
      CMD="$CMD; /sbin/modprobe dwmac_rk || echo modprobe-failed:dwmac_rk"
      # 外层用双引号，内层零引号 → sh -c 恰好拿到 3 个 argv（sh/-c/完整脚本）
      echo "ExecStart=/bin/sh -c \"$CMD\""
      echo ""
      echo "[Install]"
      echo "WantedBy=sysinit.target"
    } > "$ROOT_MNT/etc/systemd/system/kickpi-k1-modules.service"
    mkdir -p "$ROOT_MNT/etc/systemd/system/sysinit.target.wants"
    ln -sf ../kickpi-k1-modules.service "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/kickpi-k1-modules.service"
    echo "  ✓ 已装 systemd 绝对路径加载单元（不依赖 depmod）"

    # ── OTA 自愈：4 个树外模块（maxio + SWT6621S 三件）随镜像下发源码，换内核后自动重编
    # 为什么必须：这些 .ko 的 vermagic 绑内核版本，飞牛 OTA 换内核后旧模块加载不了
    #   → 网口退化 generic PHY、WiFi/BT 直接消失。设备上有 headers+gcc+make（实机确认），
    #   源码 4.4 MB 可下发，所以能在板上重编。脚本只编译+安装，加载仍由 modules-load.d 决定，
    #   任何失败只写日志不阻塞开机。
    REPO_ROOT="$(dirname "$(readlink -f "$0")")"
    for f in modules/src/maxio.c modules/wifi-src.tar.gz \
             modules/ota/modules-ensure.sh modules/ota/kickpi-k1-modules-ensure.service; do
        [[ -f "$REPO_ROOT/$f" ]] || fail "OTA 自愈素材缺失: $f"
    done
    install -D -m 0644 "$REPO_ROOT/modules/src/maxio.c"         "$ROOT_MNT/usr/src/kickpi-k1-modules/maxio.c"
    install -D -m 0644 "$REPO_ROOT/modules/wifi-src.tar.gz"     "$ROOT_MNT/usr/src/kickpi-k1-modules/wifi-src.tar.gz"
    # 来源说明留在仓库（modules/src/WIFI-SRC-ORIGIN.txt），不进镜像 —— 镜像里只放能编的东西
    install -D -m 0755 "$REPO_ROOT/modules/ota/modules-ensure.sh" \
        "$ROOT_MNT/usr/local/sbin/kickpi-k1-modules-ensure.sh"
    install -D -m 0644 "$REPO_ROOT/modules/ota/kickpi-k1-modules-ensure.service" \
        "$ROOT_MNT/etc/systemd/system/kickpi-k1-modules-ensure.service"
    mkdir -p "$ROOT_MNT/etc/systemd/system/sysinit.target.wants"
    ln -sf ../kickpi-k1-modules-ensure.service \
        "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/kickpi-k1-modules-ensure.service"
    echo "  ✓ OTA 自愈素材：maxio.c + wifi-src.tar.gz(2.2MB) + modules-ensure.sh + 单元（已 enable）"

    # 刷新模块依赖。旧条件 `[[ -x $ROOT_MNT/usr/bin/depmod ]]` 恒假 —— 基镜像里只有
    # /sbin/depmod → /bin/kmod，于是【depmod 从未运行】，modules.dep 不含 updates/kickpi-k1/*，
    # modprobe/modinfo/systemd-modules-load 对 maxio 全部无效（实机：
    # `modinfo: ERROR: Module maxio not found.`）。宿主 depmod -b 不执行目标架构二进制，
    # 跨架构可用，是这里的正解。
    if command -v depmod >/dev/null 2>&1; then
        depmod -b "$ROOT_MNT" "$KREL" >/dev/null 2>&1 || fail "depmod -b $KREL 失败"
        grep -q "updates/kickpi-k1/maxio.ko" "$ROOT_MNT/usr/lib/modules/$KREL/modules.dep" \
            || fail "modules.dep 未含 updates/kickpi-k1/maxio.ko → modprobe/modules-load 全废"
        echo "  ✓ depmod -b 完成，modules.dep 已含 updates/kickpi-k1/maxio.ko"
        for f in usr/src/kickpi-k1-modules/maxio.c \
                 usr/src/kickpi-k1-modules/wifi-src.tar.gz \
                 usr/local/sbin/kickpi-k1-modules-ensure.sh \
                 etc/systemd/system/kickpi-k1-modules-ensure.service; do
            [[ -f "$ROOT_MNT/$f" ]] || fail "OTA 自愈件缺失: $f"
        done
        [[ -L "$ROOT_MNT/etc/systemd/system/sysinit.target.wants/kickpi-k1-modules-ensure.service" ]] \
            || fail "OTA 自愈单元未 enable（sysinit.target.wants 缺链接）"
        echo "  ✓ OTA 自愈四件齐备且已 enable（换内核后自动重编 maxio + WiFi/BT 三件）"
    else
        fail "宿主缺少 depmod（kmod 包），无法刷新镜像 modules.dep"
    fi
fi

    # ── 修复飞牛自带扩容脚本的缺陷（实机实测的"重启黑屏"根因）──────────────────
    # /usr/trim/bin/resize-rootfs.sh 用 fdisk「先 d 删分区、再 n 新建」来扩容；
    # 本板镜像分区表是 GPT —— 分区重建会换掉随机 PARTUUID，于是【下一次启动】
    # root=PARTUUID=<旧值> 失配，卡在 "Waiting for root device"（首启正常、重启黑屏）。
    # 做法：包一层 —— 扩容前记下 PARTUUID，脚本跑完后用 sfdisk 写回，root= 始终有效。
    if [[ -f "$ROOT_MNT/usr/trim/bin/resize-rootfs.sh" ]]; then
        cp -f "$ROOT_MNT/usr/trim/bin/resize-rootfs.sh" \
              "$ROOT_MNT/usr/trim/bin/resize-rootfs.sh.orig" 2>/dev/null || true
        cat > "$ROOT_MNT/usr/trim/bin/resize-rootfs-kickpi-k1.sh" <<'WRAP'
#!/bin/bash
# KICKPI K1：飞牛自带 resize-rootfs.sh 用 fdisk 删/建分区扩容，会更换 GPT 的
# PARTUUID，导致下次启动 root=PARTUUID 失配（实测停在 "Waiting for root device"）。
# 这里在调用前后把原 PARTUUID 记下并写回。
rootdev=$(findmnt -n -o SOURCE / | sed 's~\[.*\]~~')
old_puuid="$(blkid -s PARTUUID -o value "$rootdev" 2>/dev/null)"
diskdevname=$(lsblk -n -d -o PKNAME "$rootdev")
[[ -z "$diskdevname" ]] && diskdevname=$(echo "$rootdev" | sed -e 's/^\/dev\///' | sed 's/p.*//')
diskdev="/dev/$diskdevname"
partindex=$(echo "$rootdev" | sed "s|^$diskdev||" | sed 's/^p//')

/usr/trim/bin/resize-rootfs.sh
rc=$?

if [[ -n "$old_puuid" ]]; then
    if sfdisk --part-uuid "$diskdev" "$partindex" "$old_puuid" >/dev/null 2>&1; then
        echo "KICKPI-K1: PARTUUID restored: $old_puuid"
    else
        echo "KICKPI-K1: WARNING failed to restore PARTUUID $old_puuid"
    fi
    partprobe "$diskdev" 2>/dev/null || true
fi
exit $rc
WRAP
        chmod +x "$ROOT_MNT/usr/trim/bin/resize-rootfs-kickpi-k1.sh"
        # 单元可能在 /etc/systemd/system 也可能在 /usr/lib/systemd/system —— 两处都要覆盖
        UNIT_SRC=""
        for cand in "$ROOT_MNT/etc/systemd/system/resize-rootfs.service" \
                    "$ROOT_MNT/usr/lib/systemd/system/resize-rootfs.service"; do
            if [[ -f "$cand" && ! -L "$cand" ]]; then UNIT_SRC="$cand"; break; fi
        done
        UNIT_DST="$ROOT_MNT/etc/systemd/system/resize-rootfs.service"
        if [[ -n "$UNIT_SRC" ]]; then
            cp -f "$UNIT_SRC" "$UNIT_SRC.orig-fnnas" 2>/dev/null || true
            # 改指包层脚本后统一落到 /etc/systemd/system（/etc 覆盖 /usr/lib）
            # ⚠ 旧写法 `sed … "$UNIT_SRC" > "$UNIT_DST"` 在 UNIT_SRC==UNIT_DST（单元就在
            #   /etc/systemd/system）时会先截断目标文件，sed 读到 0 字节 → 单元被写空 →
            #   下面的自证 grep 必失败 —— 这正是 run 37726365951/37732802163/37734267965
            #   三次 CI 失败的根因（取证实测 `sed f > f` size=0）。
            #   先写临时文件、校验改指成功、再原子替换。
            UNIT_TMP="$(mktemp)"
            # ⚠ 基镜像的这个单元【整份文件每行都带 2 个前导空格】（实测 cat -A：
            #   "  ExecStart=/usr/trim/bin/resize-rootfs.sh$"），旧的 `^ExecStart=` 锚点
            #   永远匹配不上 —— 这正是 run 37726365951/37732802163/37734267965 三次 CI 红的原因。
            #   改成允许前导空白并保留原缩进。
            sed -E 's#^([[:space:]]*)ExecStart=/usr/trim/bin/resize-rootfs\.sh(.*)$#\1ExecStart=/usr/trim/bin/resize-rootfs-kickpi-k1.sh\2#' \
                "$UNIT_SRC" > "$UNIT_TMP"
            if ! grep -q 'resize-rootfs-kickpi-k1.sh' "$UNIT_TMP"; then
                echo "    原单元 ExecStart 行（源文件，未改动）："
                grep -n 'ExecStart' "$UNIT_SRC" | cat -A | sed 's/^/      /' 
                rm -f "$UNIT_TMP"
                fail "resize-rootfs.service 的 ExecStart 形状与 sed 模式不匹配（未改指）"
            fi
            cp -f "$UNIT_TMP" "$UNIT_DST"; rm -f "$UNIT_TMP"
            echo "  ✓ resize-rootfs 单元（$UNIT_SRC → $UNIT_DST）已改指包层脚本"
        fi
        # 自证：包层脚本就位、单元（任一位置）已改指
        [[ -x "$ROOT_MNT/usr/trim/bin/resize-rootfs-kickpi-k1.sh" ]] || fail "扩容包层脚本未就位"
        grep -q 'resize-rootfs-kickpi-k1.sh' "$UNIT_DST" \
            || fail "resize-rootfs.service 未指向包层脚本（扩容后 PARTUUID 会被换掉 → 重启黑屏）"
        echo "  ✓ 已修补 resize-rootfs（扩容后写回 PARTUUID，消除重启 'Waiting for root device'）"
    else
        echo "  ℹ 基镜像无 /usr/trim/bin/resize-rootfs.sh，跳过扩容补丁"
    fi

    # ── 4b) OS 层修复（逐条来自 TF 卡实测日志，固化进构建，保证一键复现）──────────
    # 这些对应实机日志里真实出现过的失败项，避免每次都靠事后手改卡。
    ASSETS="$(dirname "$(readlink -f "$0")")/assets"
    OSFIX="$ROOT_MNT"

    # (1) 开机日志收集器：每次开机在 /boot/k1logs 落两份快照（45s / 180s），供离线精读
    install -Dm755 "$ASSETS/k1-collect-boot-logs.sh" "$OSFIX/usr/local/sbin/k1-collect-boot-logs.sh"
    install -Dm644 "$ASSETS/k1-collect-logs.service" "$OSFIX/etc/systemd/system/k1-collect-logs.service"
    install -Dm644 "$ASSETS/k1-collect-logs.timer"   "$OSFIX/etc/systemd/system/k1-collect-logs.timer"
    mkdir -p "$OSFIX/etc/systemd/system/timers.target.wants"
    ln -sf ../k1-collect-logs.timer "$OSFIX/etc/systemd/system/timers.target.wants/k1-collect-logs.timer"

    # (2) modules-load 清单里去掉本内核加载不了的模块
    #     msr = x86 专用；md_mod = 本内核无此模块 → 都会让 systemd-modules-load.service 失败
    #     rga3 = 实机 8 次开机采集（16 个日志文件）一致：finit_module 返回 EFAULT（'Bad address'）。根因不是
    #     vermagic/符号（vermagic=6.18.18.c951-trim、modprobe --show-depends 解析通过、模块
    #     能跑到 init 里才失败），而是 init 调 rga_iommu_bind() 时先打印
    #     'rga_iommu: rga_iommu_bind, binding map scheduler failed!'、再打印
    #     'rga: rga iommu bind failed!'，最后返回 -14 (EFAULT) → systemd-modules-load
    #     每开机 FAILED，把整机 --failed 顶红。
    #     ⚠ 更正旧说法：rga3.ko 没有任何 MODULE_DEVICE_TABLE 别名（全树 3656 条 'alias of:'
    #     都来自别的模块、rga 相关 0 条），所以 udev **不会**按 compatible 自动加载它；
    #     改 DTS 的 compatible 也不会让它加载。要用 RGA 必须先在实机修好 rga_iommu_bind
    #     的 EFAULT（DT 侧 rga@fdeb0000 已 okay），验证能插再把 rga3 放回本清单，别硬来。
    # ── 【2026-10-27 实机翻案：rga3 必须保留，已从上面的清单里拿掉】──────────────
    #     翻案依据（K1 / TF 卡 / DTB sha256 9ab5b742 = 媒体簇对齐官方 R5S 之后的那版，
    #     含 rk_rga@fdeb0000(rockchip,rga2)、rga@fdeb0000 的 reg=0x180）：
    #       modprobe rga3           → rc=0
    #       开机自动加载            → lsmod 有 rga3(147456)，systemd-modules-load active
    #       dmesg                   → 'rga2 fdeb0000.rk_rga: probe successfully, irq=120, hw_version:3.2.63318'
    #                                 'rga_iommu: IOMMU binding successfully, default mapping core[0x4]'
    #                                 'rga: Module initialized. v1.3.4'
    #       零失败                  → 没有任何 'binding map scheduler failed' / 'rga iommu bind failed'
    #     结论：当初的 EFAULT 是**旧 DTB**（缺 rga2 节点 / rga reg 段不对）导致 iommu 绑不上，
    #     不是 rga3.ko 本身的问题。DTB 修好后 rga3 必须保留 —— 摘掉 = 整机没有 RGA 硬件加速。
    for pair in "modules.conf:msr" "trim_md_mod.conf:md_mod"; do
        f="${pair%%:*}"; m="${pair##*:}"
        p="$OSFIX/etc/modules-load.d/$f"
        if [[ -f "$p" ]] && grep -qE "^${m}$" "$p"; then
            cp -f "$p" "$p.orig-fnnas"
            sed -i "/^${m}$/d" "$p"
            echo "  ✓ 移除 $f 里本内核加载不了的模块 $m"
        fi
    done

    # (3) 本板无对应硬件的服务一律 mask（与日志里那几条 FAILED 一一对应）
    #     pwm-fancontrol = 本板风扇是 GPIO 控制；nut-* = 无 UPS；smartmontools = 无磁盘；exim4 = 未配置
    #     ⚠ 2026-10-27 补漏：exim4 是 **SysV 脚本**（只有 /etc/init.d/exim4，没有 .service 文件），
    #     旧写法只查 systemd unit 文件 → 分支从不触发 → 每次开机 exim4.service(LBS, generated)
    #     照样启动并 failed（K1 TF 实机：'either install a certificate or change
    #     tls_advertise_hosts option' → exit 1）。现在把 init.d 存在也算命中。
    for u in pwm-fancontrol nut-monitor nut-server smartmontools exim4; do
        hit=0
        for d in "$OSFIX/etc/systemd/system" "$OSFIX/usr/lib/systemd/system" "$OSFIX/lib/systemd/system"; do
            [[ -f "$d/$u.service" && ! -L "$d/$u.service" ]] && hit=1
        done
        # SysV 脚本（systemd-sysv-generator 会为它生成 $u.service，mask 同名 unit 即可拦住）
        [[ -f "$OSFIX/etc/init.d/$u" ]] && hit=1
        if [[ "$hit" = 1 ]]; then
            ln -sf /dev/null "$OSFIX/etc/systemd/system/$u.service"
            echo "  ✓ mask $u.service"
        fi
    done

    # (3b) ifupdown 是残留：本镜像由 NetworkManager + fnOS 自己的 network_service 管网，
    #      /etc/network/interfaces 根本不存在 → networking.service 每次开机报
    #      'ifup: couldn't open interfaces file'，把网口真正的报错埋掉。
    #      无条件 mask —— 旧写法用 `-f` 只查 /etc 下两个路径，而这个单元实际在 /usr/lib 下、
    #      /etc 下的 wants 又是断链（-f 恒假）→ 分支从不触发，自证随即判红。
    rm -f "$OSFIX/etc/systemd/system/multi-user.target.wants/networking.service" || true
    ln -sf /dev/null "$OSFIX/etc/systemd/system/networking.service"
    echo "  ✓ mask networking.service（ifupdown 残留；NM 才是本网的管理者）"

    # (4) 内核日志级别：产品口径 **不得带 loglevel=7 / ignore_loglevel**（2026-10-27 改判）
    #     历史：本段曾无条件把 "cma=256M loglevel=7 ignore_loglevel" 写进 fnEnv 的 extraargs，
    #     是调试期抓串口日志用的。代价：boot.scr 拼出的 loglevel=${verbosity} 被 ignore_loglevel
    #     顶掉 → 开机全程刷屏、并压低吞吐；而且它会随镜像一起发布（实机取证：设备 fnEnv 正是这串）。
    #     现在改成反向：发现调试参数就剥掉，只保留官方 R5S 口径的 cma=256M。
    if [[ -n "${BOOT_PART:-}" ]]; then
        mount "$BOOT_PART" "$BOOT_MNT" 2>/dev/null || true
        if mountpoint -q "$BOOT_MNT" && [[ -f "$BOOT_MNT/fnEnv.txt" ]]; then
            cur_ex="$(grep '^extraargs=' "$BOOT_MNT/fnEnv.txt" | head -1 || true)"
            if [[ "$cur_ex" == *loglevel* ]]; then
                fnenv_set extraargs "extraargs=cma=256M"
                echo "  ✓ fnEnv extraargs 已剥掉调试参数 → extraargs=cma=256M"
            fi
            sync
            umount_safe "$BOOT_MNT"
        fi
    fi

    # (5) EEE/LPI：**不再关闭**（2026-10-17 改判）
    #     历史：2026-10-13 曾按"EEE 唤醒时序在 dwmac + PHY 上翻车 → 整口间歇 Link Down"
    #     判定装了脚本+开机服务+NM dispatcher 三层关闭件。2026-10-17 在主路由 T68M 上按日志复核推翻：
    #     EEE 本就处于关闭态时掉线照样发生，且 141 次掉线每次都伴随对端 1–5 s 内重新 DHCP（对端在重启），
    #     因此关闭 EEE 不是该症状的解。按官方默认保持开启，镜像里不得再装任何 EEE 关闭件（下方反向自证）。
    # (5c) 存量系统【在线修复】：本脚本的决策（清除历史 EEE 关闭件 / mask 厂商单元 / webdav 权限位 /
    #      K1 卡 FAT 脏位）也能作用到已经跑着的飞牛系统上 —— 不必重刷镜像。
    #      同时装一个首启 oneshot（marker 防重复），保证新刷镜像开箱即自愈。
    install -Dm755 "$ASSETS/fnos-fix-log-errors.sh" "$OSFIX/usr/local/sbin/fnos-fix-log-errors.sh"
    {
        echo "[Unit]"
        echo "Description=fnOS(KICKPI K1): first-boot log-error fixes (masks / webdav / cma)"
        echo "After=multi-user.target"
        echo "ConditionPathExists=!/var/lib/fnos-fix-log-errors.done"
        echo ""
        echo "[Service]"
        echo "Type=oneshot"
        echo "ExecStart=/usr/local/sbin/fnos-fix-log-errors.sh"
        echo "ExecStartPost=/bin/sh -c 'mkdir -p /var/lib && touch /var/lib/fnos-fix-log-errors.done'"
        echo "RemainAfterExit=yes"
        echo ""
        echo "[Install]"
        echo "WantedBy=multi-user.target"
    } > "$OSFIX/etc/systemd/system/fnos-fix-log-errors.service"
    ln -sf ../fnos-fix-log-errors.service \
        "$OSFIX/etc/systemd/system/multi-user.target.wants/fnos-fix-log-errors.service"
    echo "  ✓ 已装首启自愈单元（fnos-fix-log-errors.service；marker 防重复执行）"

    # 自证：缺任何一项都算构建失败（只看“文件存在”不算 —— mask 必须是指向 /dev/null 的软链）
    [[ -x "$OSFIX/usr/local/sbin/k1-collect-boot-logs.sh" ]] || fail "日志收集脚本未就位"
    # EEE 反向自证（与官方默认一致：镜像里不得出现任何 EEE 关闭件）
    for f in usr/local/sbin/kickpi-k1-eee-off.sh \
             etc/systemd/system/kickpi-k1-eee-off.service \
             etc/NetworkManager/dispatcher.d/90-kickpi-k1-eee-off; do
        [[ -e "$OSFIX/$f" ]] && fail "镜像里仍有 EEE 关闭件: $f（与官方默认不一致）"
    done
    [[ -L "$OSFIX/etc/systemd/system/multi-user.target.wants/kickpi-k1-eee-off.service" ]] \
        && fail "EEE 关闭服务仍被 enable"
    [[ -x "$OSFIX/usr/sbin/ethtool" || -x "$OSFIX/usr/bin/ethtool" ]] \
        || echo "  · 提示：镜像无 ethtool（不影响功能，仅现场取证不便）"
    # 存量系统在线修复件 + 首启自愈单元自证
    [[ -x "$OSFIX/usr/local/sbin/fnos-fix-log-errors.sh" ]] || fail "存量系统修复件未就位"
    bash -n "$OSFIX/usr/local/sbin/fnos-fix-log-errors.sh" || fail "fnos-fix-log-errors.sh 语法错误"
    [[ -L "$OSFIX/etc/systemd/system/multi-user.target.wants/fnos-fix-log-errors.service" ]] \
        || fail "首启自愈单元未启用"
    grep -q 'fnos-fix-log-errors.done' "$OSFIX/etc/systemd/system/fnos-fix-log-errors.service" \
        || fail "首启自愈单元缺 marker 条件（会每次开机重跑）"
    [[ -e "$OSFIX/etc/systemd/system/timers.target.wants/k1-collect-logs.timer" ]] || fail "日志收集定时器未启用"
    # mask 自证：单元【存在于镜像里】才要求已 mask（exim4 等在本基镜像中根本不存在，
    # 一刀切断言会把好构建判死；“存在却没 mask” 才是真问题）
    for u in pwm-fancontrol nut-monitor nut-server smartmontools exim4 networking; do
        # SysV 脚本也算「存在于镜像」——它会被 systemd-sysv-generator 生成 $u.service
        # （exim4 就是这种：只有 /etc/init.d/exim4，旧自证只查 .service 文件 → 假绿）
        if [[ -e "$OSFIX/etc/systemd/system/$u.service" || -e "$OSFIX/usr/lib/systemd/system/$u.service" \
              || -e "$OSFIX/lib/systemd/system/$u.service" || -f "$OSFIX/etc/init.d/$u" ]]; then
            if ! { [[ -L "$OSFIX/etc/systemd/system/$u.service" ]] \
                    && [[ "$(readlink "$OSFIX/etc/systemd/system/$u.service")" == "/dev/null" ]]; }; then
                fail "$u 存在于镜像（systemd unit 或 /etc/init.d 脚本）但未真正 masked（自证要求 /etc 下指向 /dev/null 的软链）"
            fi
        fi
    done
    [[ ! -e "$OSFIX/etc/systemd/system/multi-user.target.wants/networking.service" ]] \
        || fail "networking.service 仍在 multi-user.target.wants（开机仍会报 ifup 空配置）"
    for pair in "modules.conf:msr" "trim_md_mod.conf:md_mod"; do
        f="${pair%%:*}"; m="${pair##*:}"
        p="$OSFIX/etc/modules-load.d/$f"
        if [[ -f "$p" ]] && grep -qE "^${m}$" "$p"; then
            fail "$f 仍含本内核跑不了的模块 $m（会让 systemd-modules-load 开机失败）"
        fi
    done
    # rga3 / rknpu / rk_vcodec 反向自证：必须【在】开机清单里（2026-10-27 翻案，见 (2) 段）
    #   摘掉 rga3 的旧决策会让整机没有 RGA 硬件加速，这条门禁专门防它再被摘。
    RC="$OSFIX/etc/modules-load.d/trim-rk_vcodec.conf"
    [[ -f "$RC" ]] || fail "镜像缺 modules-load.d/trim-rk_vcodec.conf"
    for m in rga3 rknpu rk_vcodec; do
        grep -qx "$m" "$RC" || fail "trim-rk_vcodec.conf 缺 $m（RGA/NPU/VPU 加速不可用；rga3 的「摘掉」结论已被 DTB 修复推翻）"
    done
    echo "  ✓ modules-load 含 rga3 / rknpu / rk_vcodec（RGA 硬件加速不会被静默摘掉）"
    # 网口门禁：MAC/PHY 驱动必须【全部】显式列入开机清单。
    # 只放 maxio 是历史 bug —— dwmac_rk 一旦交给 udev 自动加载，实机就是开机不加载、
    # 灯全灭。这里逐个断言，缺一个即构建失败。
    for _m in maxio stmmac dwmac_rk; do
        grep -qs "^${_m}\$" "$OSFIX/etc/modules-load.d/kickpi-k1.conf" \
            || fail "kickpi-k1.conf 缺 $_m（MAC/PHY 驱动未显式开机加载 → 网口起不来、灯不亮）"
    done
    # 顺序门禁：maxio 必须排在 stmmac/dwmac_rk 之前
    [[ "$(grep -v '^#' "$OSFIX/etc/modules-load.d/kickpi-k1.conf" | grep -v '^$' | head -1)" == "maxio" ]] \
        || fail "kickpi-k1.conf 首个模块不是 maxio（PHY 必须先于 MAC 注册）"
    # 第二道保险：绝对路径单元也必须确定性拉起 dwmac_rk
    grep -qs 'modprobe dwmac_rk' "$OSFIX/etc/systemd/system/kickpi-k1-modules.service" \
        || fail "kickpi-k1-modules.service 未用 modprobe 拉起 dwmac_rk"
    # 引号门禁：ExecStart 必须分词成恰好 3 项（sh / -c / 完整脚本）。
    # 引号嵌套一旦被破坏（提示语里出现引号/空格/括号），sh -c 只会执行第一条命令，
    # 后面所有 insmod/modprobe 全被当成位置参数静默丢弃 —— 网口驱动就永远加载不上。
    if command -v python3 >/dev/null 2>&1; then
        _es="$(grep '^ExecStart=' "$OSFIX/etc/systemd/system/kickpi-k1-modules.service" | sed 's/^ExecStart=//')"
        _n="$(python3 -c 'import shlex,sys; print(len(shlex.split(sys.argv[1])))' "$_es" 2>/dev/null || echo 0)"
        [[ "$_n" == "3" ]] || fail "kickpi-k1-modules.service ExecStart 分词成 $_n 项（应为 3）→ sh -c 只会跑第一条命令"
    fi
    [[ -f "$OSFIX/etc/modprobe.d/kickpi-k1.conf" ]] || fail "缺 modprobe.d softdep（maxio 先于 dwmac_rk）"
    # (5) 【在线更新防护】板级模块自愈 —— 2026-10-27 整理：全仓只保留一套实现
    # 飞牛在线更新会装新内核，旧 .ko 的 vermagic 绑死旧 release → 网口退化/WiFi 消失。现行链路：
    #   · 源码：/usr/src/kickpi-k1-modules/{maxio.c,wifi-src.tar.gz}（上面 4) 段注入，唯一一处）
    #   · 编译：/usr/local/sbin/kickpi-k1-modules-ensure.sh（唯一实现；接受内核 release 参数）
    #   · 触发：/etc/kernel/postinst.d/zz-kickpi-k1-modules（装内核即编）+ 开机
    #           kickpi-k1-modules.service（按 uname -r 定位，头文件晚到也能补编）
    #   · 加载：/usr/local/sbin/kickpi-k1-load-modules（唯一入口；modules-load.d/softdep 为二重保险）
    # 历史（已删除，别再捡回来）：第二套源码目录 /usr/src/kickpi-k1/ + 第二套编译脚本
    #   assets/kickpi-k1-build-modules.sh + 构建期 git clone 上游 —— 与仓内 wifi-src.tar.gz 重复、
    #   且让构建依赖外网（离线不可复现）。
    install -Dm755 "$ASSETS/kickpi-k1-load-modules"     "$OSFIX/usr/local/sbin/kickpi-k1-load-modules"
    install -Dm755 "$ASSETS/zz-kickpi-k1-modules"       "$OSFIX/etc/kernel/postinst.d/zz-kickpi-k1-modules"
    # 开机单元按【运行内核】定位（覆盖前面写死 release 的版本）
    cat > "$OSFIX/etc/systemd/system/kickpi-k1-modules.service" <<'K1EOF'
[Unit]
Description=Load KICKPI K1 board modules for the RUNNING kernel (self-heal on new kernel)
DefaultDependencies=no
Before=network-pre.target systemd-modules-load.service
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
# uname -r 在这里是 sh 展开，systemd 不做变量替换 → 始终作用于当前运行内核。
# 先按运行内核补编（幂等：四件都已是本版就秒过），再加载，最后确保两个 GMAC 驱动在位。
ExecStart=/bin/sh -c "/usr/local/sbin/kickpi-k1-modules-ensure.sh; /usr/local/sbin/kickpi-k1-load-modules; /sbin/modprobe dwmac_rk"

[Install]
WantedBy=sysinit.target
K1EOF
    ln -sf ../kickpi-k1-modules.service \
        "$OSFIX/etc/systemd/system/sysinit.target.wants/kickpi-k1-modules.service"
    echo "  ✓ 已装板级模块自愈链（唯一源码目录 + postinst 钩子 + 按 uname -r 的开机单元）"
    [[ -x "$OSFIX/usr/local/sbin/kickpi-k1-modules-ensure.sh" ]] \
        || fail "自愈脚本 kickpi-k1-modules-ensure.sh 未就位"
    [[ -x "$OSFIX/etc/kernel/postinst.d/zz-kickpi-k1-modules" ]] \
        || fail "zz-kickpi-k1-modules 未就位（新内核装完不会自动重编板级模块 → 更新后网口全灭）"
    [[ -f "$OSFIX/usr/src/kickpi-k1-modules/maxio.c" ]] || fail "maxio.c 源未注入（设备端无法随内核重编）"
    [[ -f "$OSFIX/usr/src/kickpi-k1-modules/wifi-src.tar.gz" ]] || fail "WiFi/BT 源码未注入（换内核后 WiFi 无法自愈）"
    [[ ! -e "$OSFIX/usr/src/kickpi-k1" ]] || fail "残留第二套源码目录 /usr/src/kickpi-k1（已废弃，会误导诊断）"
    grep -qs 'uname -r' "$OSFIX/etc/systemd/system/kickpi-k1-modules.service" \
        || fail "kickpi-k1-modules.service 未按 uname -r 定位（在线更新后会加载不到模块）"

    echo "  ✓ OS 层修复已固化（日志收集 / 模块清单 / 服务 mask / 内核日志级别 / 在线更新自愈）"

# OTA 引导同步脚本（若基镜像自带则保留）
# umount 加固：实测出现过 "target is busy" 让 set -e 直接退出（明明该做的都做完了）。
# 先 sync 落盘，再重试，最后惰性卸载兜底。
sync
umount_safe "$ROOT_MNT"

echo
echo "==== 5) 产出校验 ===="
LOOP2="$(losetup -fP --show "$IMG")"
mount "${LOOP2}p1" "$BOOT_MNT"
V_DTB="$(sha256sum "$BOOT_MNT/dtb/rockchip/$DTB_NAME" | awk '{print $1}')"
V_SRC="$(sha256sum "$DTB" | awk '{print $1}')"
[[ "$V_DTB" == "$V_SRC" ]] && echo "  ✓ 镜像内 DTB sha256 与源一致（${V_SRC:0:16}…）" || fail "镜像内 DTB 与源不一致"
# 引导链路必须是【官方 boot.scr】：boot.cmd 每次启动 part uuid 现场取身份，不写死
grep -q 'part uuid' "$BOOT_MNT/boot.cmd" 2>/dev/null \
    && echo "  ✓ boot.cmd 含 part uuid（现场取分区身份，不会写死 UUID）" \
    || fail "boot.cmd 缺 part uuid（官方现场取身份机制没了 → 退回静态 UUID 会串盘）"
[[ -f "$BOOT_MNT/boot.scr" ]] || fail "缺 boot.scr（官方引导链断了）"
grep -q "fdtfile=rockchip/$DTB_NAME" "$BOOT_MNT/fnEnv.txt" \
    && echo "  ✓ fnEnv fdtfile 正确" || fail "fnEnv 校验失败"
# 2026-10-27 翻案：产品口径**不得**带 loglevel / ignore_loglevel
# （它会把 boot.scr 拼出的 loglevel=${verbosity} 顶掉 → 开机全程刷屏、压吞吐）
if grep -q '^extraargs=' "$BOOT_MNT/fnEnv.txt" && ! grep -q 'loglevel' "$BOOT_MNT/fnEnv.txt"; then
    echo "  ✓ fnEnv extraargs 无调试参数（产品口径）"
else
    fail "fnEnv extraargs 仍含 loglevel/ignore_loglevel 调试参数：$(grep '^extraargs=' "$BOOT_MNT/fnEnv.txt")"
fi
# 不能留 extlinux.conf 抢引导（它会把 root= 钉在构建期 PARTUUID 上）
[[ ! -f "$BOOT_MNT/extlinux/extlinux.conf" ]] \
    || fail "仍存在 extlinux/extlinux.conf：u-boot 会优先走它，绕开官方 boot.scr 的现场取 UUID"
umount_safe "$BOOT_MNT"
losetup -d "$LOOP2"

echo
echo "==== 5b) GPT 自洽（保护MBR / 主头 / 分区项 / 备份头，全字段 + CRC）===="
# 为什么这道门禁必须有（2026-10-27 两次实机事故）：
#   镜像刷进**比镜像大**的卡/盘时，主头里的 alternate_lba / last_usable 仍指向镜像末尾
#   （例：3.86G 镜像 → 7,538,687，而卡是 14.7G → 30,883,839）。
#   U-Boot 宽容：照样从 mmc 1:1 读 boot.scr → 引导看似正常；
#   Linux 内核严格：alternate 不在设备末尾 ⇒ 拒绝整张分区表 ⇒ `mmcblk1:` 后**不列 p1 p2**
#   ⇒ 卡死 `Waiting for root device PARTUUID=...`（无 panic、无报错，干等）。
#   构建期这里断言【镜像自身自洽】；写卡后再对【目标盘】跑一次（见下方刷写提示）。
python3 tools/gpt-fix.py "$IMG" --apply || { echo "❌ GPT 修复/复检失败（alternate_lba / 项CRC / 备份头 / 保护MBR）"; exit 1; }

echo
echo "==== 6) 压缩与摘要 ===="
    # 可跳过压缩：本地快速验证（SKIP_XZ=1）或内存吃紧时用
    if [[ "${SKIP_XZ:-0}" == "1" ]]; then
        echo "  ℹ SKIP_XZ=1，跳过 xz（验证直接用 .img）"
    else
        # 默认 -T0 -6：-9 在小内存机器上会被 OOM killer 干掉（实测 xz 被 Killed），
        # 而 -6 对 3.84G 镜像体积差别很小、耗时更短。
        xz -T0 -"${XZ_LEVEL:-6}" -c "$IMG" > "$IMG.xz"
    fi
if [[ "${SKIP_XZ:-0}" == "1" ]]; then
    ( cd "$OUT_DIR" && sha256sum "$(basename "$IMG")" > SHA256SUMS )
    echo "  ✓ $IMG ($(stat -c%s "$IMG") 字节，未压缩)"
else
    ( cd "$OUT_DIR" && sha256sum "$(basename "$IMG").xz" > SHA256SUMS )
    echo "  ✓ $IMG.xz ($(stat -c%s "$IMG.xz") 字节)"
fi
cat "$OUT_DIR/SHA256SUMS" | sed 's/^/     /'
echo
echo "🎉 完成。刷写（由用户对 SD 卡执行，例如 /dev/sdX 或 /dev/mmcblk1）："
if [[ "${SKIP_XZ:-0}" == "1" ]]; then
echo "   dd if=$(basename "$IMG") of=/dev/sdX bs=4M conv=fsync status=progress"
else
echo "   xz -dc $(basename "$IMG").xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
fi
echo
echo "⚠ 刷完【必须】对目标盘再跑一次 GPT 适配（镜像比盘小 → 主头 alt/last_usable 指错，"
echo "  U-Boot 能过但内核拒表 → 卡死 Waiting for root device，2026-10-27 实机两次）："
echo "   python3 tools/gpt-fix.py /dev/sdX --apply --renew-partuuid=2"
echo "     --renew-partuuid=2 换掉 rootfs 的 PARTUUID，避免与板上 eMMC 上同源系统撞车"
echo "     （boot.cmd 是 part uuid 现场取值，换 GUID 不用改任何引导文件）"
echo "   判据：fdisk -l /dev/sdX 能看到 p1/p2，且 gpt-fix 诊断输出「GPT 全字段自洽」"
