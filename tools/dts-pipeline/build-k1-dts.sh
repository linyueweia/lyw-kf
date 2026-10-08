#!/bin/bash
# KICKPI K1 飞牛 DTS 生成流水线（确定性、可复现）
# 每一步都幂等；最后由 dtc 判定，0 ERROR/FATAL 才算成功。
set -e
cd /work/kbuild/6.18.18-rockchip
S=/work/scripts
echo "== 1) 基座（本板身份 / gmac 四延迟 / SDIO / 关无此设备 / 网口 PHY 复位）=="
python3 $S/gen-k1-dts-from-t68m.py work/t68m-base.dts work/k1.dts
echo "== 2) 并入实机板级节点（数字 phandle → 绝对路径引用）=="
python3 $S/merge-live-nodes.py
echo "== 3) 补建缺的稳压器节点 =="
python3 $S/inject-extra-nodes.py | tail -1
echo "== 4) 注入 leds 整棵（含子节点）=="
python3 $S/inject-leds.py | tail -1
echo "== 5) 用 6.18 主线 SoC 定义覆盖（vop/hdmi/gmac/rga/gpu/pcie）=="
python3 $S/apply-mainline-soc.py | tail -6
echo "== 6) 按实机对齐 status（打开被误关的设备）=="
python3 $S/align-status-from-live.py | head -4
echo "== 7) 导入实机有而我们没有的节点 =="
python3 $S/import-missing-nodes.py | head -3
echo "== 8) 禁用抢引脚设备（否则网口引脚复用失败）=="
python3 $S/disable-conflict-nodes.py | tail -6
echo "== 8.4) 收尾合并（实机属性 → rga/npu/编解码/PCIe-PHY/USB/音频）=="
python3 $S/merge-vendor-final.py | head -2
echo "== 8.5) 补齐 PHY 节点 reg（缺它 → invalid PHY address → 退化成 Generic PHY）=="
python3 $S/fix-phy-reg.py | tail -1
echo "== 9) dtc 判定 =="
if dtc -f -Wno-pci_device_reg -Wno-unit_address_vs_reg -I dts -O dtb \
     -o work/rk3568-kickpi-k1.dtb work/k1-final.dts 2>&1 | grep -qE 'ERROR|FATAL'; then
  echo "  ✗ dtc 有错"; exit 1
fi
echo "  ✓✓ dtc 0 ERROR/FATAL"
echo "  DTB $(stat -c%s work/rk3568-kickpi-k1.dtb) 字节  md5=$(md5sum work/rk3568-kickpi-k1.dtb | cut -c1-16)"
