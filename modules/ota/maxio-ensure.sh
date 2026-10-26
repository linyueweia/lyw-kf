#!/bin/sh
# KICKPI K1 —— Maxio MAE0621A PHY 驱动 OTA 自愈
#
# 背景（2026-10-27 实机取证）：
#   · 飞牛内核【不带】Maxio 驱动：6.18.18.c1145-trim 的 vmlinuz 里 "maxio" 字符串 0 处，
#     /lib/modules/<kver>/…/net/phy/ 无 maxio.ko，modinfo maxio → not found，
#     /sys/bus/mdio_bus/drivers 54 个里也没有 Maxio/MAE。
#   · 内核树里虽有 drivers/net/phy/maxio.c（904 行、含 LED），但它是给更新内核写的：
#     用 .led_dt_managed，而飞牛现装头文件是旧 API int (*led_hw_control_get)(dev,u8,ulong*)
#     → 实测编译失败（-Werror=incompatible-pointer-types）。所以只能继续用本仓自建版。
#   · 自建 maxio.ko 是按【内核版本】定死的（vermagic）。OTA 换内核后旧 .ko 加载不了，
#     Maxio PHY 会退回 Generic PHY（RGMII 参考时钟/灯/速率都可能异常）。
#
# 本脚本：OTA 后开机时，若当前内核没有可用的 maxio.ko，就用设备上的
#   /lib/modules/$(uname -r)/build（= /usr/src/linux-headers-<kver>）+ gcc + make 现场重编。
# 实机已确认这些前提都在：headers 目录、/usr/bin/gcc、/usr/bin/make 均存在。
# 任何一步失败都【只记录、不阻塞开机】（网络降级为 generic PHY，但系统还能上）。
set -u

KVER="$(uname -r)"
SRC_DIR="/usr/src/maxio-k1"
MOD_DIR="/usr/lib/modules/${KVER}/updates/maxio-k1"
KO="${MOD_DIR}/maxio.ko"
LOG="/var/log/maxio-ensure.log"
HDR="/lib/modules/${KVER}/build"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

modvermagic_ok() {
    [ -f "$1" ] || return 1
    # vermagic 里带内核 release 才算可用（OTA 后旧模块会缺/不符）
    modinfo -F vermagic "$1" 2>/dev/null | grep -q "$KVER"
}

if modvermagic_ok "$KO"; then
    exit 0
fi

log "当前内核 ${KVER} 没有可用的 maxio.ko，尝试现场重编（OTA 自愈）"

[ -f "${SRC_DIR}/maxio.c" ] || { log "缺源码 ${SRC_DIR}/maxio.c —— 放弃（网络可能降级为 generic PHY）"; exit 0; }
[ -d "$HDR" ]              || { log "缺内核头文件 ${HDR} —— 放弃（网络可能降级为 generic PHY）"; exit 0; }
command -v gcc  >/dev/null || { log "缺 gcc —— 放弃"; exit 0; }
command -v make >/dev/null || { log "缺 make —— 放弃"; exit 0; }

BUILD="/var/lib/maxio-k1/build-${KVER}"
rm -rf "$BUILD"; mkdir -p "$BUILD" || { log "建 ${BUILD} 失败"; exit 0; }
cp -f "${SRC_DIR}/maxio.c" "${BUILD}/maxio.c" || { log "拷源码失败"; exit 0; }
printf 'obj-m += maxio.o\n' > "${BUILD}/Makefile"

if ! make -C "$HDR" M="$BUILD" modules >>"$LOG" 2>&1; then
    log "重编失败（多半是新内核改了 PHY API，需更新 modules/src/maxio.c）—— 网络降级为 generic PHY"
    exit 0
fi

mkdir -p "$MOD_DIR" || { log "建 ${MOD_DIR} 失败"; exit 0; }
cp -f "${BUILD}/maxio.ko" "$KO" || { log "安装 ko 失败"; exit 0; }

if command -v depmod >/dev/null 2>&1; then
    depmod -a "$KVER" >>"$LOG" 2>&1 || log "depmod 失败（不影响 insmod 绝对路径加载）"
fi

if modvermagic_ok "$KO"; then
    log "重编成功：$KO（$(stat -c%s "$KO" 2>/dev/null) B）"
    # 立即加载；随后 kickpi-k1-modules.service 还会按绝对路径 insmod 一次（幂等）
    /sbin/modprobe maxio >>"$LOG" 2>&1 || /sbin/insmod "$KO" >>"$LOG" 2>&1 || log "加载失败"
else
    log "重编产物 vermagic 仍不符 —— 不安装"
fi

exit 0
