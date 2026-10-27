#!/usr/bin/env bash
# KICKPI K1 (飞牛 fnOS) 媒体层 DT 门禁 —— 转码死机事故的防回归判据（2026-10-19）
# 用法: tools/verify-k1-media-dts.sh [dtb]      默认 dist/rk3568-kickpi-k1.dtb
# 判据来源（全部本轮实测取证，勿凭空增删）：
#   L1 官方 fnOS RK3568 设备 DTB 逐节点对照（同内核包 rk3568-nanopi-r5s / rk3568-easepi-r1）
#   L2 内核只认 rockchip,rk3568-iommu（vmlinuz 未压缩 Image strings:
#      "rockchip,rk3568-iommu" 1 次 / "rockchip,iommu-v2" 0 次）
#   L3 rk_vcodec.ko 的 of_match（含 rockchip,vpu-encoder-v2、rkv-encoder-v1、
#      rkv-decoder-rk3568…；"rockchip,rk3568-vepu" 全库 0 命中）
# 事故链（2026-10-19 实机）：IOMMU 写孤串 iommu-v2 → SMMU 不注册 → rkvenc/iep/jpegd
#   failed to attach iommu；vepu 节点错名成死节点；rkvdec/rkvenc 挂 OPP 把解码核压到
#   240/250MHz（官方锁 396/396/396/600）→ mediasrv 转码锁死共享 mpp-srv 复位机制 →
#   rkvdec 每任务 timeout、irq:invalid 风暴 → 整机挂死（看门狗 89s 后硬复位）。
set -u
DTB="${1:-dist/rk3568-kickpi-k1.dtb}"
[ -f "$DTB" ] || { echo "✗ 找不到 DTB: $DTB"; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
dtc -I dtb -O dts "$DTB" -o "$TMP/d.dts" 2>/dev/null || { echo "✗ dtc 反编译失败"; exit 1; }

FAIL=0
ck() { # ck <描述> <实际> <期望>
  if [ "$2" = "$3" ]; then echo "  OK   $1 = $2"
  else echo "  ✗    $1 = '$2'  期望 '$3'"; FAIL=1; fi
}
has() { # has <文件> <描述> <正则>
  if grep -qE "$3" "$1"; then echo "  OK   $2"
  else echo "  ✗    $2 缺失"; FAIL=1; fi
}
hasnt() { # hasnt <文件> <描述> <正则>
  if grep -qE "$3" "$1"; then echo "  ✗    $2 仍存在"; FAIL=1
  else echo "  OK   $2 不存在"; fi
}
blk() { # blk <文件> <起始行>  → 节点整块
  awk -v s="$2" 'NR>=s {print; o=gsub(/{/,"{"); c=gsub(/}/,"}"); d+=o-c; if(NR>s && d<=0) exit}' "$1"
}
node_block() { # node_block <节点名模式> <输出文件>；找不到节点 = FAIL
  local n; n=$(grep -nE "$1" "$TMP/d.dts" | head -1 | cut -d: -f1)
  if [ -z "$n" ]; then echo "  ✗    节点 $1 缺失"; FAIL=1; return 1; fi
  blk "$TMP/d.dts" "$n" > "$2"; return 0
}

echo "-- IOMMU compatible 形态（官方 RK3568：双串 rk3568-iommu+iommu-v2，仅 fe043e00 单串）"
ck "双串 iommu 节点数" "$(grep -c 'rk3568-iommu.*rockchip,iommu-v2' "$TMP/d.dts" || true)" "9"
ck "单串 rk3568-iommu 数（仅 fe043e00，官方同款）" "$(grep -c 'compatible = "rockchip,rk3568-iommu"' "$TMP/d.dts" || true)" "1"
ck "孤串 iommu-v2 数（内核不认，必须 0）" "$(grep -c 'compatible = "rockchip,iommu-v2"' "$TMP/d.dts" || true)" "0"

echo "-- NPU iommu@fde4b000：必须 okay（iommu 模式，2026-10-27 翻案）"
# 为什么这条是硬门禁：non-iommu 逃生门下 rknpu GEM 必须物理连续 → 只能吃 CMA，
# fnOS trim.face_det 单次要 339MiB 连续块（cma=256M 必失败，每 90 秒刷 alloc failed），
# 相册人脸识别完全不可用。iommu 模式走 scatter-gather 吃系统内存，不受 CMA 约束。
if node_block 'iommu@fde4b000 \{' "$TMP/npu_iommu"; then
  has   "$TMP/npu_iommu" "status=okay（iommu 模式，跟随官方 R5S）"  'status = "okay"'
  hasnt "$TMP/npu_iommu" "status=disabled（non-iommu 逃生门，不得作为当前方案）" 'status = "disabled"'
fi

echo "-- rkvdec@fdf80200：官方锁频形态（396/396/396/600 + disable-auto-freq，不挂 OPP）"
if node_block 'rkvdec@fdf80200 \{' "$TMP/rkvdec"; then
  has "$TMP/rkvdec" "disable-auto-freq 在位"        'rockchip,disable-auto-freq'
  has "$TMP/rkvdec" "assigned-clock-rates=396/396/396/600" '0x179a7b00 0x179a7b00 0x179a7b00 0x23c34600'
  hasnt "$TMP/rkvdec" "OPP 链接（官方无）"           'operating-points-v2'
  has "$TMP/rkvdec" "结构件 iommus/sram/srv"         'iommus'
fi

echo "-- rkvenc@fdf40000：不挂 OPP（官方形态；挂 OPP 会把任务压出超时风暴）"
if node_block 'rkvenc@fdf40000 \{' "$TMP/rkvenc"; then
  hasnt "$TMP/rkvenc" "OPP 链接（官方无）" 'operating-points-v2'
fi

echo "-- 第二编码器 fdee0000：官方名 rockchip,vpu-encoder-v2 + disable-auto-freq"
if node_block 'fdee0000 \{' "$TMP/vepu"; then
  has "$TMP/vepu" "compatible = rockchip,vpu-encoder-v2" 'compatible = "rockchip,vpu-encoder-v2"'
  hasnt "$TMP/vepu" "旧死名 rockchip,rk3568-vepu（rk_vcodec.ko 不认）" 'rockchip,rk3568-vepu'
  has "$TMP/vepu" "disable-auto-freq 在位" 'rockchip,disable-auto-freq'
  has "$TMP/vepu" "iommus 挂接"            'iommus'
fi

echo "-- 媒体单元清单齐全（与官方 R5S 同清单）"
for u in 'rkvdec@fdf80200 \{' 'rkvenc@fdf40000 \{' 'jpegd@fded0000 \{' 'iep@fdef0000 \{' 'video-codec@fdea0400 \{' 'mpp-srv'; do
  if grep -qE "$u" "$TMP/d.dts"; then echo "  OK   单元存在: $u"
  else echo "  ✗    单元缺失: $u"; FAIL=1; fi
done

echo "------------------------------------------------"
if [ "$FAIL" = "0" ]; then echo "MEDIA-DTS GATE: ALL PASS"; else echo "MEDIA-DTS GATE: FAIL"; fi
exit $FAIL
