#!/usr/bin/env bash
#
# 用【飞牛基镜像自带的内核头文件】编译本板树外模块：
#   maxio.ko                 —— 双千兆网口 Maxio MAE0621A PHY 驱动
#   skw_sdio_lite.ko / swt6621s_wifi.ko / skwbt.ko —— SWT6621S WiFi/BT
#
# 关键点（都是实测踩出来的）：
#   1) 内核版本必须与镜像一致（基镜像为 6.18.18.c951-trim），从
#      /usr/lib/modules/<rel> 与 /usr/src/linux-headers-<rel> 自动探测，不写死。
#   2) 头文件包可能缺 .config —— 用 include/config/auto.conf 补出。
#   3) 头文件包里的主机工具（fixdep/modpost）可能是别的主机/glibc 的，跑不了 —— 重编。
#   4) 若内核用 gcc12 构建而本机 gcc 较老，需置空 CONFIG_INIT_STACK_ALL_ZERO=（不认该 flag）。
#   5) 编译产物必须做 vermagic 与镜像内核 release 的比对，不一致直接失败。
#
# 用法: build-modules.sh <基镜像.img> <输出目录> [SWT6621S 源码目录或 git URL]
set -euo pipefail

IMG="${1:?用法: build-modules.sh <base.img> <out_dir> [wifi_src]}"
OUT="${2:?缺少输出目录}"
WIFI_SRC="${3:-}"

WORK="$(mktemp -d)"
HDR="$WORK/hdr"
MNT="$WORK/root"
mkdir -p "$HDR" "$MNT" "$OUT"
LOOP=""
cleanup() {
    mountpoint -q "$MNT" && umount "$MNT" || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==== 1) 从基镜像取出内核头文件 ===="
LOOP="$(losetup -fP --show "$IMG")"
sleep 1
ROOTP=""
for c in "${LOOP}p2" "${LOOP}2"; do [[ -e "$c" ]] && ROOTP="$c" && break; done
[[ -n "$ROOTP" ]] || { echo "✗ 找不到 rootfs 分区"; exit 1; }
mount "$ROOTP" "$MNT"

KREL="$(ls "$MNT/usr/lib/modules" 2>/dev/null | head -1)"
[[ -n "$KREL" ]] || { echo "✗ rootfs 里没有 /usr/lib/modules"; exit 1; }
SRCDIR="$(ls -d "$MNT/usr/src/linux-headers-$KREL" 2>/dev/null | head -1)"
[[ -n "$SRCDIR" ]] || SRCDIR="$(ls -d "$MNT/usr/src/"linux-headers-* 2>/dev/null | head -1)"
[[ -n "$SRCDIR" ]] || { echo "✗ 镜像里没有内核头文件"; exit 1; }
echo "  内核 release : $KREL"
echo "  头文件目录   : ${SRCDIR#$MNT}"

# 头文件包常见缺 auto.conf/autoconf.h（飞牛基镜像就是），而 BOOT 分区里有完整的
# config-<rel>。趁 loop 还挂着，把它取出来备用（第 2 步用它生成缺失的配置文件）。
KCFG_SRC=""
BOOTP=""
for c in "${LOOP}p1" "${LOOP}1"; do [[ -e "$c" ]] && BOOTP="$c" && break; done
if [[ -n "$BOOTP" ]]; then
    mkdir -p "$WORK/boot"
    if mount -ro "$BOOTP" "$WORK/boot" 2>/dev/null; then
        for cand in "$WORK/boot/config-$KREL" "$WORK/boot/config"; do
            if [[ -f "$cand" ]]; then
                cp "$cand" "$WORK/kernel.config"
                KCFG_SRC="$(basename "$cand")"
                break
            fi
        done
        umount "$WORK/boot" 2>/dev/null || true
    fi
fi
[[ -n "$KCFG_SRC" ]] && echo "  ✓ 取出内核配置: $KCFG_SRC（备用）" \
                     || echo "  ⚠ BOOT 分区未取到 config-<rel>（若头文件缺 auto.conf 将无法生成）"

cp -a "$SRCDIR" "$HDR/h"
HDR="$HDR/h"
chmod -R u+w "$HDR"
umount "$MNT"; [[ -n "$LOOP" ]] && losetup -d "$LOOP"; LOOP=""

echo
echo "==== 2) 修补头文件树（三个坑） ===="
if [[ ! -f "$HDR/.config" ]]; then
    if [[ -f "$HDR/include/config/auto.conf" ]]; then
        cp "$HDR/include/config/auto.conf" "$HDR/.config"
        echo "  ✓ 用 auto.conf 补出 .config"
    elif [[ -f "$WORK/kernel.config" ]]; then
        # 实测坑：飞牛基镜像的 linux-headers 包里【没有】include/config/auto.conf
        # 与 include/generated/autoconf.h，直接编译会报
        #   ERROR: Kernel configuration is invalid. The following files are missing:
        # 用 BOOT 分区的 config-<rel> 作为 .config，再让内核自己生成这两个文件。
        cp "$WORK/kernel.config" "$HDR/.config"
        echo "  ✓ 用基镜像 BOOT 的 $KCFG_SRC 补出 .config，正在生成 auto.conf/autoconf.h"
        make -C "$HDR" ARCH=arm64 olddefconfig >/dev/null 2>&1 || true
        make -C "$HDR" ARCH=arm64 prepare scripts >/dev/null 2>&1 || true
        [[ -f "$HDR/include/config/auto.conf" ]] \
            || { echo "✗ 无法生成 include/config/auto.conf"; exit 1; }
        [[ -f "$HDR/include/generated/autoconf.h" ]] \
            || { echo "✗ 无法生成 include/generated/autoconf.h"; exit 1; }
        echo "  ✓ auto.conf 与 autoconf.h 已生成"
    else
        echo "✗ 头文件树缺 include/config/auto.conf，且 BOOT 分区里也没取到内核 config"
        exit 1
    fi
fi
# 飞牛基镜像的 linux-headers 包裁剪过：include/config/auto.conf 在，
# 但 include/generated/autoconf.h 不在（内核 Makefile:862 据此报
#   ERROR: Kernel configuration is invalid ... missing: include/generated/autoconf.h）
# 同一处还会检查 6.18 新增的 include/generated/rustc_cfg。两者都必须补齐。
# 注意用 -s（非空）：裁剪过的头文件包可能给一个 0 字节的 autoconf.h，
# 用 -f 会放过它，而内核 Makefile 用 $(wildcard ...) 判定，空文件同样算缺失。
if [[ ! -s "$HDR/include/generated/autoconf.h" ]]; then
    echo "  · 缺（或为空）$HDR/include/generated/autoconf.h，正在生成"
    mkdir -p "$HDR/include/generated"
    make -C "$HDR" ARCH=arm64 syncconfig >/dev/null 2>&1 \
        || make -C "$HDR" ARCH=arm64 oldconfig  >/dev/null 2>&1 \
        || make -C "$HDR" ARCH=arm64 prepare   >/dev/null 2>&1 || true
    if [[ ! -s "$HDR/include/generated/autoconf.h" ]]; then
        echo "  · 内核自身生成不可用，改为直接从 .config 生成 autoconf.h"
        {
            sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=[yY]$/#define \1 1/p'   "$HDR/.config"
            sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=[mM]$/#define \1 1/p'   "$HDR/.config"
            sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=\([0-9][0-9a-fA-FxX]*\)$/#define \1 \2/p' "$HDR/.config"
            sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)="\(.*\)"$/#define \1 "\2"/p' "$HDR/.config"
            sed -n 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\/* #undef \1 *\//p' "$HDR/.config"
        } > "$HDR/include/generated/autoconf.h"
    fi
    [[ -s "$HDR/include/generated/autoconf.h" ]] \
        || { echo "✗ 仍无法生成 include/generated/autoconf.h"; exit 1; }
    echo "  ✓ autoconf.h 就绪（$(wc -l < "$HDR/include/generated/autoconf.h") 行）"
fi
if [[ ! -s "$HDR/include/generated/rustc_cfg" ]]; then
    echo "# 模块构建不需要 Rust，此处为占位（6.18 的完整性检查要求该文件存在）" \
        > "$HDR/include/generated/rustc_cfg"
    echo "  ✓ 补 include/generated/rustc_cfg 占位（仅模块构建用不到 Rust）"
fi
# 时间戳刷新：内核判定 auto.conf 是否过期依赖这些派生文件的时间戳，
# 只要它们比 .config/auto.conf 旧，make 就会去重建 auto.conf 并触发完整性检查。
touch "$HDR/include/generated/autoconf.h" "$HDR/include/generated/rustc_cfg" \
      "$HDR/include/config/auto.conf" 2>/dev/null || true
[[ -e "$HDR/include/config/auto.conf.cmd" ]] || : > "$HDR/include/config/auto.conf.cmd"
echo "  ✓ 派生文件已就绪（autoconf.h $(stat -c%s "$HDR/include/generated/autoconf.h") 字节）"

grep -qE '^CONFIG_MODULE_SIG_FORCE=y' "$HDR/.config" 2>/dev/null \
    && { echo "✗ 该内核强制模块签名，自编模块无法加载"; exit 1; } \
    || echo "  ✓ 内核未强制模块签名"
for t in scripts/basic/fixdep scripts/mod/modpost; do
    if [[ -x "$HDR/$t" ]] && ! "$HDR/$t" --version >/dev/null 2>&1; then
        echo "  · $t 不可执行（异主机构建），删除待重编"; rm -f "$HDR/$t"
    fi
done
if [[ ! -x "$HDR/scripts/mod/modpost" ]]; then
    if ! make -C "$HDR" scripts >/dev/null 2>&1 || [[ ! -x "$HDR/scripts/mod/modpost" ]]; then
        echo "  · make scripts 不适用，手工编译 fixdep 与 modpost"
        # modpost 需要 libelf；缺了就自己装（CI runner 上默认没有）
        # 主机工具：libelf 给 modpost；flex/bison 给 scripts/kconfig 的词法/语法分析器
        # （实测缺 flex/bison 时 `make scripts` 与 `make syncconfig` 都会失败，
        #   于是 autoconf.h 生成不出来 → 编译报 "Kernel configuration is invalid"）
        apt-get update -qq >/dev/null 2>&1 || true
        apt-get install -y -qq libelf-dev flex bison >/dev/null 2>&1 || true
        gcc -o "$HDR/scripts/basic/fixdep" "$HDR/scripts/basic/fixdep.c" -I"$HDR/scripts/include" 2>/dev/null || true
        gcc -O2 -o "$HDR/scripts/mod/modpost" "$HDR/scripts/mod/modpost.c" \
            "$HDR/scripts/mod/file2alias.c" "$HDR/scripts/mod/sumversion.c" \
            "$HDR/scripts/mod/symsearch.c" -I"$HDR/scripts/mod" -I"$HDR/scripts/include" -lelf
    fi
fi
[[ -x "$HDR/scripts/mod/modpost" ]] || { echo "✗ modpost 仍不可用（没有它产物不会有 vermagic，加载不了）"; exit 1; }
echo "  ✓ 主机工具就绪"

# 目标代码是 arm64，必须用交叉编译器。踩过的坑：CI runner 默认只有 x86_64 gcc，
# 不设 CROSS_COMPILE 时会用宿主 gcc 去编 arm64，报一堆
#   gcc: error: unrecognized command-line option '-mlittle-endian'
#        unrecognized option '-mbranch-protection=pac-ret' 等
XCC="${CROSS_COMPILE:-aarch64-linux-gnu-}"
if ! command -v "${XCC}gcc" >/dev/null 2>&1; then
    echo "  · 缺 ${XCC}gcc，尝试安装 gcc-aarch64-linux-gnu"
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq gcc-aarch64-linux-gnu >/dev/null 2>&1 || true
fi
command -v "${XCC}gcc" >/dev/null 2>&1 \
    || { echo "✗ 缺交叉编译器 ${XCC}gcc（arm64 模块无法编译）"; exit 1; }
echo "  ✓ 交叉编译器: $(command -v "${XCC}gcc")  ($("${XCC}gcc" -dumpversion))"

MAKEFLAGS_COMMON=(-C "$HDR" ARCH=arm64 CONFIG_INIT_STACK_ALL_ZERO= \
                  CROSS_COMPILE="$XCC" modules)

echo
echo "==== 3) 编译 maxio.ko ===="
MD="$WORK/maxio"
mkdir -p "$MD"
cp "$(dirname "$0")/src/maxio.c" "$MD/maxio.c" 2>/dev/null || cp "$(dirname "$0")/modules/src/maxio.c" "$MD/maxio.c"
printf 'obj-m += maxio.o\n' > "$MD/Makefile"
make "${MAKEFLAGS_COMMON[@]}" M="$MD" >/dev/null 2>&1 || make "${MAKEFLAGS_COMMON[@]}" M="$MD" 2>&1 | tail -12
cp "$MD/maxio.ko" "$OUT/" && echo "  ✓ maxio.ko"

echo
echo "==== 4) 编译 SWT6621S 三模块 ===="
if [[ -n "$WIFI_SRC" ]]; then
    WD="$WORK/wifi"
    if [[ "$WIFI_SRC" == http* || "$WIFI_SRC" == git@* ]]; then
        git clone --depth 1 "$WIFI_SRC" "$WD" >/dev/null 2>&1
    else
        cp -a "$WIFI_SRC" "$WD"
    fi
    PATCH="$(dirname "$0")/patches/wifi-6.18-port.patch"
    if [[ -f "$PATCH" ]]; then
        ( cd "$WD" && git apply "$PATCH" ) && echo "  ✓ 已应用 6.18 移植补丁" || echo "  ⚠ 补丁未能应用（可能源码版本不同）"
    fi
    make "${MAKEFLAGS_COMMON[@]}" M="$WD" \
        CONFIG_SEEKWAVE_BSP_DRIVERS=m CONFIG_SKW_NO_CONFIG=y CONFIG_SKW_SDIOHAL=m \
        CONFIG_WLAN_VENDOR_SWT6621S=m CONFIG_SKW_BT=m modules >/dev/null 2>&1 || true
    for ko in $(find "$WD" -name '*.ko'); do cp -f "$ko" "$OUT/"; done
    echo "  SWT6621S 产出: $(ls "$OUT" | grep -cE 'skw|swt') 个"
else
    echo "  （未提供 SWT6621S 源码，跳过）"
fi

echo
echo "==== 5) 产物与 vermagic 校验（必须与镜像内核 $KREL 一致） ===="
FAIL=0
for ko in "$OUT"/*.ko; do
    [[ -f "$ko" ]] || continue
    vm="$(strings "$ko" | grep -oE 'vermagic=[^"]*' | head -1)"
    if [[ "$vm" == *"$KREL"* ]]; then
        printf "  ✓ %-22s %10s B  %s\n" "$(basename "$ko")" "$(stat -c%s "$ko")" "$vm"
    else
        printf "  ✗ %-22s %s（镜像要求 %s）\n" "$(basename "$ko")" "$vm" "$KREL"; FAIL=1
    fi
done
[[ $FAIL -eq 0 ]] || { echo "✗ 有模块 vermagic 与镜像内核不符"; exit 1; }
echo "  ✓ 全部模块与镜像内核一致"
