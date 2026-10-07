#!/usr/bin/env bash
#
# 从 kk（iNextOS）构建产物里取 K1 专用的 u-boot 对（idbloader.img + u-boot.itb），
# 并做 DDR 固件防呆校验。
#
# 为什么不能借用别的板子的 idbloader（重要，已实测踩到）：
#   idbloader.img 里装着【板级 DDR 初始化固件】，频率是按板子 DRAM 定的。
#   实测对比：
#     · T68M 那份（xck-nas 仓库）      -> strings 显示 "DDR V1.18 f366f69a7d"
#     · K1 自己 eMMC 里厂商那份        -> strings 显示 "DDR v1.23-03ea844c5d / fwver: v1.23"
#   两者版本与哈希都不同，直接复用会踩 DDR 训练不匹配。
#   K1 实机 DT 的 LPDDR4 参数为 freq_0 = <0x618> = 1560MHz，
#   而 kk 管线用的是框架默认 rk35/rk3568_ddr_1560MHz_v1.21.bin（频率一致）。
#   => 取 kk 编出来的那一对，才是与 K1 实机匹配的组合。
#
# 用法（在 CI 里由 workflow 调用；本地需 gh 已登录）:
#   ./fetch-uboot-from-kk.sh <run_id> <out_dir> [kk_repo]
set -euo pipefail

RUN_ID="${1:?用法: fetch-uboot-from-kk.sh <run_id> <out_dir> [kk_repo]}"
OUT_DIR="${2:?缺少 out_dir}"
KK_REPO="${3:-linyueweia/lyw-kk}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "1) 取 kk 构建 $RUN_ID 的 u-boot 产物"
gh run download "$RUN_ID" --repo "$KK_REPO" --dir "$WORK/art" 2>/dev/null || true

UBOOT_DEB="$(find "$WORK/art" -name 'linux-u-boot-*kickpi-k1-vendor*.deb' | head -1 || true)"
if [[ -z "$UBOOT_DEB" ]]; then
    echo "✗ 产物里没找到 kickpi-k1 的 u-boot deb，现有文件："
    find "$WORK/art" -type f | head -20 | sed 's/^/    /'
    exit 1
fi
echo "   找到: $(basename "$UBOOT_DEB")"

echo "2) 解包取出 idbloader / u-boot.itb"
dpkg-deb -x "$UBOOT_DEB" "$WORK/deb"
IDB="$(find "$WORK/deb" -name 'idbloader.img' | head -1 || true)"
ITB="$(find "$WORK/deb" -name 'u-boot.itb' | head -1 || true)"
[[ -n "$IDB" ]] || { echo "✗ deb 里没有 idbloader.img"; exit 1; }
[[ -n "$ITB" ]] || { echo "✗ deb 里没有 u-boot.itb"; exit 1; }

echo "3) DDR 固件防呆校验（必须与 K1 实机 1560MHz 匹配）"
DDR_LINE="$(strings "$IDB" | grep -iE 'ddr.*v1\.[0-9]+|fwver: v1\.' | head -1 || true)"
echo "   idbloader 里的 DDR 固件: ${DDR_LINE:-未识别}"
# 明确拒绝已知错误的 T68M 版本
if strings "$IDB" | grep -q 'V1.18 f366f69a7d'; then
    echo "✗ 检测到 T68M 的 DDR V1.18 固件 —— 不是 K1 的，拒绝使用"
    exit 1
fi
# 期望框架默认的 1560MHz 变体（版本号可能随框架升级，故只做提示不硬卡）
if strings "$IDB" | grep -qiE '1560|v1\.2[0-9]'; then
    echo "   ✓ 与 K1 (LPDDR4 @1560MHz) 匹配"
else
    echo "   ⚠ 未能从字符串确认 1560MHz —— 请人工核对后再使用（K1 实机 freq_0=0x618=1560MHz）"
fi

mkdir -p "$OUT_DIR"
cp "$IDB" "$OUT_DIR/idbloader.img"
cp "$ITB" "$OUT_DIR/u-boot.itb"
echo
echo "4) 产出"
for f in idbloader.img u-boot.itb; do
    printf "   %-16s %8s 字节  sha256=%s\n" "$f" "$(stat -c%s "$OUT_DIR/$f")" "$(sha256sum "$OUT_DIR/$f" | cut -c1-16)"
done
