#!/bin/sh
# KICKPI K1 —— 树外模块 OTA 自愈（maxio + SWT6621S 三件）
#
# 为什么需要（2026-10-27 实机取证）：
#   · 4 个模块都是树外编译，vermagic 绑定内核版本；飞牛 OTA 换内核后旧 .ko 加载不了。
#       maxio            Maxio MAE0621A PHY  → 没了就是网口退化（generic PHY）
#       swt6621s_wifi    板载 WiFi(SDIO)     → 没了就是没 WiFi
#       skw_sdio_lite    SDIO 公共层         → WiFi 依赖它
#       skwbt            蓝牙               → 没了就是没 BT
#   · 飞牛内核不带这些驱动（vmlinuz 里 maxio 字符串 0 处），只能自带。
#   · 树内 drivers/net/phy/maxio.c 用新 LED API（.led_dt_managed），而现装头文件是
#     int (*led_hw_control_get)(dev,u8,ulong*) → 实测编不过，所以继续用本仓自建版。
#   · 设备上有 /lib/modules/<kver>/build(=linux-headers) + gcc + make（实机确认），
#     且 WiFi 源码 4.4 MB 可随镜像下发 → 换内核后能现场重编。
#
# 实机实测（H88K，同内核 6.18.18.c1145-trim，原生 aarch64 gcc）：
#   maxio 4s；WiFi 三件 67s；产物 vermagic 全部 6.18.18.c1145-trim ✓
#
# 设计要点：
#   · 只【编译+安装】，加载交给 modules-load.d / kickpi-k1-modules.service：
#     本机没声明就不加载（所以本脚本可以在没有这些硬件的机器上安全验证）。
#   · 任何失败只写日志，绝不阻塞开机（网络/WiFi 降级，系统照常起来）。
set -u

KVER="$(uname -r)"
SRC="/usr/src/kickpi-k1-modules"
HDR="/lib/modules/${KVER}/build"
DST="/usr/lib/modules/${KVER}/updates/kickpi-k1"
WORK="/var/lib/kickpi-k1/build-${KVER}"
LOG="/var/log/kickpi-k1-modules-ensure.log"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

vermagic_ok() {
    [ -f "$1" ] || return 1
    modinfo -F vermagic "$1" 2>/dev/null | grep -q "$KVER"
}

# 四个模块都已是本内核版本 → 什么都不用做
ALL_OK=1
for m in maxio swt6621s_wifi skw_sdio_lite skwbt; do
    vermagic_ok "${DST}/${m}.ko" || ALL_OK=0
done
[ "$ALL_OK" = 1 ] && exit 0

log "内核 ${KVER} 缺少本版树外模块，开始现场重编"

[ -d "$HDR" ]              || { log "缺内核头文件 $HDR —— 放弃（模块不可用，系统降级运行）"; exit 0; }
command -v gcc  >/dev/null || { log "缺 gcc —— 放弃"; exit 0; }
command -v make >/dev/null || { log "缺 make —— 放弃"; exit 0; }

mkdir -p "$DST" || { log "建 $DST 失败"; exit 0; }
rm -rf "$WORK"; mkdir -p "$WORK" || { log "建 $WORK 失败"; exit 0; }

# ── 1) maxio：单文件 ────────────────────────────────────────────────
if ! vermagic_ok "${DST}/maxio.ko"; then
    if [ -f "${SRC}/maxio.c" ]; then
        mkdir -p "$WORK/maxio" && cp -f "${SRC}/maxio.c" "$WORK/maxio/maxio.c" \
            && printf 'obj-m += maxio.o\n' > "$WORK/maxio/Makefile"
        if make -C "$HDR" M="$WORK/maxio" modules >>"$LOG" 2>&1; then
            install -m 0644 "$WORK/maxio/maxio.ko" "$DST/maxio.ko" && log "maxio.ko 重编成功"
        else
            log "maxio 重编失败（多半是新内核改了 PHY API，需更新 modules/src/maxio.c）"
        fi
    else
        log "缺 ${SRC}/maxio.c，跳过 maxio"
    fi
fi

# ── 2) SWT6621S 三件：整棵源码（tar 下发，构建期解包） ───────────────
NEED_WIFI=0
for m in swt6621s_wifi skw_sdio_lite skwbt; do
    vermagic_ok "${DST}/${m}.ko" || NEED_WIFI=1
done
if [ "$NEED_WIFI" = 1 ]; then
    if [ -f "${SRC}/wifi-src.tar.gz" ]; then
        mkdir -p "$WORK/wifi" && tar xzf "${SRC}/wifi-src.tar.gz" -C "$WORK/wifi"
        if make -C "$HDR" M="$WORK/wifi" \
                CONFIG_SEEKWAVE_BSP_DRIVERS=m CONFIG_SKW_NO_CONFIG=y CONFIG_SKW_SDIOHAL=m \
                CONFIG_WLAN_VENDOR_SWT6621S=m CONFIG_SKW_BT=m modules >>"$LOG" 2>&1; then
            n=0
            for ko in $(find "$WORK/wifi" -name '*.ko'); do
                install -m 0644 "$ko" "$DST/$(basename "$ko")" && n=$((n+1))
            done
            log "SWT6621S 重编完成：$n 个 .ko"
        else
            log "SWT6621S 重编失败（看日志尾部；多半是新内核改了 cfg80211/sdio API，需更新 patches/wifi-6.18-port.patch）"
            tail -30 "$LOG" >/dev/null 2>&1 || true
        fi
    else
        log "缺 ${SRC}/wifi-src.tar.gz，跳过 WiFi/BT"
    fi
fi

command -v depmod >/dev/null 2>&1 && { depmod -a "$KVER" >>"$LOG" 2>&1 || log "depmod 失败（不影响绝对路径 insmod）"; }

# ── 3) 汇总 ────────────────────────────────────────────────────────
OK=0; BAD=""
for m in maxio swt6621s_wifi skw_sdio_lite skwbt; do
    if vermagic_ok "${DST}/${m}.ko"; then OK=$((OK+1)); else BAD="$BAD $m"; fi
done
log "结果：${OK}/4 可用$([ -n "$BAD" ] && echo "；仍缺:$BAD")（加载由 modules-load.d 决定）"
exit 0
