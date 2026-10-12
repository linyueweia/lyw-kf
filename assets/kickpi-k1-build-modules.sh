#!/bin/bash
# KICKPI K1：把板级树外模块【对指定内核】本机重编并装进该内核的模块目录。
#
# 为什么需要它：maxio(MAE0621A PHY) 与 SWT6621S WiFi/BT 都是树外模块，
# 飞牛在线更新会安装新内核（如 6.18.18.c951-trim → 6.18.18.c1145-trim），
# /usr/lib/modules/<新内核>/ 下没有这些 .ko → 新内核起来后 PHY 无人驱动 →
# 双网口全灭（2026-10-12 实机复现）。本脚本让模块跟着内核走：
#   /etc/kernel/postinst.d/zz-kickpi-k1-modules 在每次内核安装后自动调它，
#   kickpi-k1-modules.service 开机也会调它兜底。
#
# 用法: kickpi-k1-build-modules.sh [内核release]   （默认当前运行内核）
# 特性: 幂等（该内核已有可用 .ko 就跳过）、失败不破坏既有 .ko、全程留日志。
set -u

REL="${1:-$(uname -r)}"
SRCDIR="/usr/src/kickpi-k1"
DEST="/usr/lib/modules/$REL/updates/kickpi-k1"
KDIR="/lib/modules/$REL/build"
LOG="/var/log/kickpi-k1-modules.log"

ts() { date '+%F %T'; }
say() { echo "[$(ts)] $*" | tee -a "$LOG"; }

mkdir -p /var/log 2>/dev/null || true
say "==== kickpi-k1-build-modules: 目标内核 $REL ===="

[[ -d "$SRCDIR" ]] || { say "✗ 缺少 $SRCDIR（镜像里没注入板级模块源码），跳过"; exit 0; }
if [[ ! -d "$KDIR" ]]; then
    say "✗ 缺少 $KDIR（该内核的头文件包未安装，例如 linux-headers-$REL），无法重编"
    say "  → 该内核下网口/WiFi 不可用；装上对应 headers 后重跑本脚本即可"
    exit 1
fi

# 幂等：maxio 是唯一必须自编的（网口 PHY 硬依赖）。它已就位且 vermagic 匹配 → 秒过。
# WiFi/BT 不归本脚本管：飞牛官方内核自带 updates/trim/seekwave-swt6621s/ 三件套，
# 随内核更新，永远不需要我们编译（2026-10-12 实测确认）。
if [[ -f "$DEST/maxio.ko" ]] && strings "$DEST/maxio.ko" 2>/dev/null | grep -q "vermagic=.*$REL"; then
    say "✓ $REL 已有 maxio.ko，跳过编译（WiFi/BT 用官方自带 seekwave）"
    exit 0
fi
say "…需要为 $REL 编译 maxio"

command -v make >/dev/null 2>&1 || { say "✗ 无 make（build-essential 未装）"; exit 1; }
command -v gcc  >/dev/null 2>&1 || { say "✗ 无 gcc（build-essential 未装）"; exit 1; }

WORK="$(mktemp -d /tmp/k1mod.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DEST"

# ARCH=arm64 是本机，所以不设 CROSS_COMPILE；CONFIG_INIT_STACK_ALL_ZERO= 是历史坑位，
# 本机头文件是完整包，留着无害。
MK=(make -C "$KDIR" ARCH=arm64 CONFIG_INIT_STACK_ALL_ZERO= modules)

# ── maxio（PHY 驱动）────────────────────────────────────────────────────
MD="$WORK/maxio"; mkdir -p "$MD"
cp "$SRCDIR/maxio.c" "$MD/maxio.c"
printf 'obj-m += maxio.o\n' > "$MD/Makefile"
if "${MK[@]}" M="$MD" >"$WORK/maxio.log" 2>&1; then
    if [[ -f "$MD/maxio.ko" ]] && strings "$MD/maxio.ko" | grep -q "vermagic=.*$REL"; then
        cp -f "$MD/maxio.ko" "$DEST/maxio.ko"
        say "✓ maxio.ko 已装入 $DEST"
    else
        say "✗ maxio.ko 产出异常或 vermagic 不符 $REL（见 $WORK/maxio.log）"
    fi
else
    say "✗ maxio 编译失败（日志尾部）："
    tail -15 "$WORK/maxio.log" | tee -a "$LOG"
fi

# ── WiFi/BT：官方自带，本脚本不编译 ──────────────────────────────────
# 飞牛官方内核包自带 updates/trim/seekwave-swt6621s/
#   {swt6621s_wifi,skwbt,skw_sdio_lite,skw_usb_lite}.ko，随内核一起更新，
# 实测存在且可加载（2026-10-12）。所以我们只编 maxio，WiFi 一律用官方的。
OFFICIAL_WIFI="/usr/lib/modules/$REL/updates/trim/seekwave-swt6621s"
if compgen -G "$OFFICIAL_WIFI/*.ko" >/dev/null 2>&1; then
    say "✓ 官方 seekwave 三件套在（$OFFICIAL_WIFI），WiFi 不自编"
    WIFI_SRC="官方包"
else
    say "⚠ 该内核没带官方 seekwave（$OFFICIAL_WIFI 为空）→ 本内核无 WiFi（不影响网口）"
    WIFI_SRC="缺失"
fi

# ── 收尾：刷新模块依赖 + 结果断言 ───────────────────────────────────────
if command -v depmod >/dev/null 2>&1; then
    # depmod 可能对官方目录结构报 fstatat/alternatives 之类告警，只要 modules.dep
    # 里写进了 maxio 就算成功（下面用 grep 实断言，不依赖 depmod 退出码）
    depmod -a "$REL" >>"$LOG" 2>&1 || say "⚠ depmod -a $REL 有告警（继续，下面实断言）"
fi
grep -q "updates/kickpi-k1/maxio.ko" "/usr/lib/modules/$REL/modules.dep" 2>/dev/null \
    && say "✓ modules.dep 已登记 updates/kickpi-k1/maxio.ko" \
    || say "✗ modules.dep 未登记 maxio（modprobe 会找不到 → 网口挂）"

# 硬断言：maxio 必须就位 —— 没有它，这个内核的两个网口必然全灭
if [[ -f "$DEST/maxio.ko" ]] && strings "$DEST/maxio.ko" | grep -q "vermagic=.*$REL"; then
    say "==== 完成：$REL 网口驱动 maxio ✓；WiFi/BT 来源=${WIFI_SRC} ===="
    exit 0
fi
say "==== 失败：$REL 下没有可用的 maxio.ko（网口必然起不来）===="
exit 1
