#!/usr/bin/env bash
# KICKPI K1 (飞牛 fnOS) 网口 DT 门禁 —— 只读校验，判据全部来自三方取证报告 deleg_f8cea9c3
# 用法: tools/verify-k1-net-dts.sh [dtb]      默认 dist/rk3568-kickpi-k1.dtb
# 判据来源：
#   L1 实机运行 5.10（单持有 MAC 侧复位；tx/rx 0x21/0x3c 与 0x2f/0x39）
#   L2 官方 6.1 SDK rk3568-kickpi-eth-gmac0/1.dtsi
#   L3 官方 5.10 镜像 DTB
#   板上日志：双持有 → -EBUSY → "Cannot register the MDIO bus"（相位A）
#             无复位  → "MDIO device at address 0 is missing" / -ENODEV（相位C）
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
has() { # has <描述> <正则>
  if grep -qE "$2" "$TMP/d.dts"; then echo "  OK   $1"
  else echo "  ✗    $1 缺失"; FAIL=1; fi
}
hasnt() { # hasnt <描述> <正则>
  if grep -qE "$2" "$TMP/d.dts"; then echo "  ✗    $1 仍存在"; FAIL=1
  else echo "  OK   $1 不存在"; fi
}

echo "== 网口 DT 门禁: $DTB =="
for eth in ethernet@fe2a0000 ethernet@fe010000; do
  echo "-- $eth"
  # 节点范围内的属性（sed 取该节点到下一个同级节点前）
  SEG=$(awk -v n="\t$eth {" 'index($0,n){f=1} f{print} f&&/^\t};/{exit}' "$TMP/d.dts")
  echo "$SEG" > "$TMP/seg"
  grep -q 'status = "okay"' "$TMP/seg" && echo "  OK   status=okay" || { echo "  ✗    status != okay"; FAIL=1; }
  grep -q 'phy-mode = "rgmii"' "$TMP/seg" && echo "  OK   phy-mode=rgmii" || { echo "  ✗    phy-mode 错"; FAIL=1; }
  grep -q 'clock_in_out = "output"' "$TMP/seg" && echo "  OK   clock_in_out=output" || { echo "  ✗    clock_in_out 错"; FAIL=1; }
  # 复位必须只在 MAC 侧
  grep -q 'snps,reset-gpio = ' "$TMP/seg" && echo "  OK   MAC 侧 snps,reset-gpio 在位" || { echo "  ✗    MAC 侧复位缺失"; FAIL=1; }
  grep -q 'snps,reset-active-low' "$TMP/seg" && echo "  OK   snps,reset-active-low" || { echo "  ✗    缺 snps,reset-active-low"; FAIL=1; }
  grep -q 'snps,reset-delays-us' "$TMP/seg" && echo "  OK   snps,reset-delays-us" || { echo "  ✗    缺 reset-delays-us"; FAIL=1; }
  # 反编译产物里没有标签、全是裸 phandle → 按【cell 数】判：2 组 = 4 个 cell
  cells() { tr '\n' ' ' < "$TMP/seg" | grep -o "$1 = <[^>]*>" | head -1 | sed 's/.*<//; s/>//' | wc -w | tr -d ' '; }
  ck "assigned-clocks cell 数(2组=4)" "$(cells assigned-clocks)" "4"
  ck "assigned-clock-parents cell 数(2组=4)" "$(cells assigned-clock-parents)" "4"
  ck "assigned-clock-rates cell 数(=2)" "$(cells assigned-clock-rates)" "2"
done

echo "-- PHY 节点（不得持有复位，逐块作用域）"
PHY_BAD=0
for b in $(grep -n 'ethernet-phy@0 {' "$TMP/d.dts" | cut -d: -f1); do
  if sed -n "${b},$((b+16))p" "$TMP/d.dts" | grep -qE 'reset-(gpios|assert-us|deassert-us)\s*='; then
    echo "  ✗    PHY 块(行 $b) 仍持有复位属性"; PHY_BAD=1; FAIL=1
  fi
done
[ "$PHY_BAD" = "0" ] && echo "  OK   两个 PHY 块均不持有复位"

echo "-- 队列节点（不得有复位垃圾属性）"
hasnt "queue0 内 reset-*"  'queue0 \{[^}]*reset-(gpios|assert-us|deassert-us)'

echo "-- 全局单持有：两根网口复位线不得再被任何 reset-gpios 引用"
ck "reset-gpios 引用 fe750000/0x1b 次数" "$(grep -c 'reset-gpios = <&{/pinctrl/gpio@fe750000} 0x1b' "$TMP/d.dts" || true)" "0"
ck "reset-gpios 引用 fe760000/0x07 次数" "$(grep -c 'reset-gpios = <&{/pinctrl/gpio@fe760000} 0x07' "$TMP/d.dts" || true)" "0"

echo "-- 其它三方一致项回归"
ck "phy-mode rgmii 计数"   "$(grep -c 'phy-mode = \"rgmii\"' "$TMP/d.dts" || true)" "2"
ck "tx_delay 0x21/0x2f 计数" "$(grep -cE 'tx_delay = <0x(21|2f)>' "$TMP/d.dts" || true)" "2"
ck "rx_delay 0x3c/0x39 计数" "$(grep -cE 'rx_delay = <0x(3c|39)>' "$TMP/d.dts" || true)" "2"
hasnt "T68M 残留 realtek 属性"  'realtek,'
# 每个 PHY 块都要有 reg=0（缺它 → invalid PHY address → 退化 Generic PHY）
PHY_OK=0; PHY_N=0
for b in $(grep -n 'ethernet-phy@0 {' "$TMP/d.dts" | cut -d: -f1); do
  PHY_N=$((PHY_N+1))
  if sed -n "${b},$((b+12))p" "$TMP/d.dts" | grep -q 'reg = <0x00>'; then PHY_OK=$((PHY_OK+1)); fi
done
ck "PHY 节点数" "$PHY_N" "2"
ck "带 reg=0 的 PHY 节点数" "$PHY_OK" "2"

echo "------------------------------------------------"
if [ "$FAIL" = "0" ]; then echo "NET-DTS GATE: ALL PASS"; else echo "NET-DTS GATE: FAIL"; fi
exit $FAIL
