#!/usr/bin/env bash
#==========================================================================
# KICKPI K1(fnOS) DTB 云编译 —— 在【飞牛内核树】里编板级 DTS + SoC 一致性门禁
#
# 为什么必须在飞牛内核树里编（对齐 lyw-hk 的做法，2026-10-27）：
#   飞牛内核 = unifreq/linux-6.18.y（6.18.18.cXXX-trim 的来源）。
#   板上现在跑的 DTB 是从厂商 BSP 反编译出来的 dump（dts/rk3568-kickpi-k1.dts，
#   196 KB 平铺），它里面的 SoC 级定义（iommu 命名、gmac/combphy 绑定、
#   vpu/rga 兼容串…）停留在反编译那天的树。树一升，dump 不会跟着动 →
#   典型症状就是 hk 仓踩过的 "DTB 与内核不配套"（iommu 绑定不上、设备根本不 probe）。
#
# 本脚本做两件事：
#   1) 把板级 DTS 放进飞牛树里编（cpp + 内核 dtc 规则），产物天然与内核同源；
#   2) SoC 一致性门禁：拿树里自己编的参考板 DTB（rk3568-evb1-ddr4-v10）做对照，
#      凡"两边都有的节点"，其第一个 compatible 必须与树一致 —— 不一致就是 dump 已过期，
#      直接失败并列出差异，不允许把过期 DTB 交付。
#      （板级独有节点如 Maxio PHY、LED、regulator 只在我们的 DTB 里，不参与比对）
#
# 用法：
#   bash build-dtb.sh                          # 克隆树 + 编译 + 门禁 + 输出 dist/
#   KERNEL_DIR=/path/to/tree bash build-dtb.sh # 复用已 clone 的树
#==========================================================================
set -euo pipefail
trap 'echo "  ✗ 命令失败退出 @行 $LINENO（set -e / pipefail）" >&2' ERR

KERNEL_REPO="${KERNEL_REPO:-https://github.com/unifreq/linux-6.18.y.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"
KERNEL_DIR="${KERNEL_DIR:-kernel}"
DTS_SRC="${DTS_SRC:-dts/rk3568-kickpi-k1.dts}"
DTS_NAME="rk3568-kickpi-k1.dts"
OUT="${OUT:-dist/rk3568-kickpi-k1.dtb}"
REF_CANDIDATES="rk3568-evb1-ddr4-v10.dtb rk3568-rock-3a.dtb rk3568-nanopi-r5s.dtb"  # 树自带 RK3568 参考板（取第一个存在的作 SoC 基线）

[[ -f "$DTS_SRC" ]] || { echo "✗ 缺 $DTS_SRC"; exit 1; }
command -v dtc >/dev/null || { echo "✗ 缺 dtc（apt install device-tree-compiler）"; exit 1; }

echo "==== 1) 准备飞牛内核树 ===="
if [[ ! -d "$KERNEL_DIR/.git" ]]; then
    git clone --depth 1 -b "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_DIR"
else
    echo "  复用已有树: $KERNEL_DIR"
fi
echo "  树版本: $(cd "$KERNEL_DIR" && git log -1 --format='%h %ad %s' --date=short)"

echo
echo "==== 2) 放入板级 DTS 并登记 Makefile ===="
DTS_DIR="$KERNEL_DIR/arch/arm64/boot/dts/rockchip"
cp -f "$DTS_SRC" "$DTS_DIR/$DTS_NAME"
MK="$DTS_DIR/Makefile"
DTB_NAME="${DTS_NAME%.dts}.dtb"
if grep -q "$DTB_NAME" "$MK"; then
    echo "  Makefile 已有 $DTB_NAME"
else
    echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += $DTB_NAME" >> "$MK"
    echo "  已追加: dtb-\$(CONFIG_ARCH_ROCKCHIP) += $DTB_NAME"
fi

echo
echo "==== 3) 编译 DTB（树内规则，不需要交叉工具链）===="
LOG="$(mktemp)"
( cd "$KERNEL_DIR" && make ARCH=arm64 defconfig >/dev/null && make ARCH=arm64 dtbs -j"$(nproc)" ) 2>&1 | tee "$LOG"
echo "---- 本板 DTS 相关告警/错误 ----"
grep -nE "kickpi|k1" "$LOG" | tail -20 || true
echo "-------------------------------"

OUR_DTB="$DTS_DIR/$DTB_NAME"
[[ -f "$OUR_DTB" ]] || { echo "✗ 没编出 $DTB_NAME"; grep -nE "Error|error:" "$LOG" | head -30 || true; exit 1; }
mkdir -p "$(dirname "$OUT")"
cp -f "$OUR_DTB" "$OUT"
ls -la "$OUT"; sha256sum "$OUT"

echo
echo "==== 4) SoC 一致性门禁（对照树自带参考板）===="
REF=""
for c in $REF_CANDIDATES; do
    if [[ -f "$DTS_DIR/$c" ]]; then REF="$DTS_DIR/$c"; break; fi
done
if [[ -z "$REF" ]]; then
    echo "  ⚠ 树里没有可用的 RK3568 参考板（试过: $REF_CANDIDATES），跳过对照"
else
    python3 tools/dtb-soc-consistency.py "$OUT" "$REF" || exit 1
fi

echo
echo "==== 5) 本板节点自检 ===="
T="$(mktemp --suffix=.dts)"
dtc -I dtb -O dts "$OUT" -o "$T" 2>/dev/null || { echo "✗ DTB 反编译失败"; exit 1; }
fail() { echo "  ✗ $1"; exit 1; }
grep -q 'kickpi,k1' "$T"                        || fail "compatible 不含 kickpi,k1"
grep -q 'model = "KICKPI K1"' "$T"              || fail "model 不是 KICKPI K1"
grep -q 'rockchip,rk3568-iommu' "$T"            || fail "iommu 不是 rk3568-iommu（飞牛树口径）"
grep -q 'phy-mode = "rgmii"' "$T"               || fail "gmac 必须 rgmii + 显式 tx/rx_delay（rgmii-id 在厂商 dwmac-rk 里延迟清零）"
grep -qE 'tx_delay|rx_delay' "$T"               || fail "缺 tx/rx_delay"
grep -q 'eee-broken-1000t' "$T"                 || fail "缺 eee-broken-1000t（Maxio MAE0621A 协商 1G EEE 会打死 RX）"
grep -q 'ethernet@fe010000' "$T"                || fail "缺 gmac0（ethernet@fe010000）"
grep -q 'ethernet@fe2a0000' "$T"                || fail "缺 gmac1（ethernet@fe2a0000）"
echo "  ✓ 全部通过（kickpi,k1 / model / rk3568-iommu / rgmii+delay / eee-broken-1000t / 双 gmac）"
echo "  ✓ DTB 由飞牛内核树编译：$OUT"
