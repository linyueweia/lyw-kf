#!/usr/bin/env python3
"""以 fnOS 6.18 内核自带的 rk3568-lyt-t68m.dtb（同项目姊妹板、6.18 原生）为基座，
叠加 KICKPI K1 的板级差异，产出 K1 的 DTS。

为什么这次方法是对的：
  上一版失败是因为把厂商【5.10 时代】的实机 DT 整体搬进 6.18 内核 ——
  节点/属性集合与新一代内核不匹配（先丢 #gpio-cells，再坏 assigned-clocks），
  表现为 pinctrl -22 与上百条 -517 连锁。
  本方案基座是 6.18 内核自己编出的兄弟板 DTB，与目标内核同源；且 T68M 与 K1
  实测同为 RK809+TCS4525 供电、eMMC=mmc0(sdhci@fe310000)、SD=mmc1(dwmmc@fe2b0000)，
  因此只需叠加四处板级差异。

四处差异（全部有实机依据）：
  1. model / compatible 改为 kickpi k1
  2. gmac0 (fe2a0000): phy-mode=rgmii, tx_delay=0x21, rx_delay=0x3c   ← 实机逐字
  3. gmac1 (fe010000): phy-mode=rgmii, tx_delay=0x2f, rx_delay=0x39   ← 实机逐字
  4. mmc@fe000000 由 disabled 改 okay（K1 的 SWT6621S WiFi 是 SDIO，实机 mmc3=fe000000.dwmmc；
     驱动按 SDIO ID 匹配，无需 DT 节点，只要控制器就位）
"""
import re, subprocess, sys, pathlib

BASE = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'work/t68m-base.dts')
OUT  = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else 'work/k1.dts')
src = BASE.read_text(errors='ignore')
print('  基座: %s (%d 行)' % (BASE, len(src.splitlines())))

def set_prop(text, node_pat, prop, value, must_exist=True):
    """在指定节点块内设置属性（存在则替换，不存在则插入）"""
    m = re.search(r'(\n\t%s\s*\{)' % re.escape(node_pat), text)
    if not m:
        # 允许带 @地址 的匹配
        m = re.search(r'(\n\t%s[^\{]*\{)' % re.escape(node_pat.split('@')[0]), text)
    if not m:
        print('    ✗ 找不到节点 %s' % node_pat); return text, False
    start = m.end()
    # 找到该节点块的结束（缩进回到一个 tab 之前）
    depth = 1; i = start
    while i < len(text) and depth:
        if text[i] == '{': depth += 1
        elif text[i] == '}': depth -= 1
        i += 1
    block = text[start:i]
    # 值形态通用化：phy-mode 是字符串("rgmii-id")，tx_delay 是 <数>，都要能替换
    pat = re.compile(r'\n\t\t%s\s*=\s*[^;]*;' % re.escape(prop))
    if pat.search(block):
        newblock = pat.sub(lambda mm: '\n\t\t%s = %s;' % (prop, value), block, count=1)
        print('    ✓ %s: %s → %s' % (node_pat, prop, value))
    elif must_exist:
        print('    ⚠ %s 里没有 %s，插入' % (node_pat, prop))
        newblock = '\n\t\t%s = %s;' % (prop, value) + block
    else:
        newblock = block
    return text[:start] + newblock + text[i:], True

# 1) 身份
s = src.replace('compatible = "lyt,t68m\\0rockchip,rk3568";',
                'compatible = "kickpi,k1\\0rockchip,rk3568";')
s = s.replace('model = "LYT T68M";', 'model = "KICKPI K1";')
print('  ✓ 身份改为 kickpi,k1 / KICKPI K1')

# 2/3) 两个网口：phy-mode 与四延迟（实机逐字值）
for node, tx, rx in (('ethernet@fe2a0000', '0x21', '0x3c'),
                     ('ethernet@fe010000', '0x2f', '0x39')):
    s, _ = set_prop(s, node, 'phy-mode', '"rgmii"')
    s, _ = set_prop(s, node, 'tx_delay', '<%s>' % tx)
    s, _ = set_prop(s, node, 'rx_delay', '<%s>' % rx)

# 4) 打开 K1 的 WiFi SDIO 控制器
m = re.search(r'(\n\tmmc@fe000000\s*\{)', s)
if m:
    start = m.end(); depth = 1; i = start
    while i < len(s) and depth:
        if s[i] == '{': depth += 1
        elif s[i] == '}': depth -= 1
        i += 1
    blk = s[start:i]
    if 'status = "disabled"' in blk:
        blk2 = blk.replace('status = "disabled"', 'status = "okay"', 1)
    else:
        blk2 = blk
    # SDIO WiFi 常用属性（缺则补，已有不动）
    extra = ''
    for prop, val in (('bus-width', '<0x04>'), ('non-removable', None),
                      ('cap-sdio-irq', None), ('keep-power-in-suspend', None),
                      ('no-sd', None), ('no-mmc', None)):
        if prop not in blk2:
            extra += ('\n\t\t%s;' % prop) if val is None else ('\n\t\t%s = %s;' % (prop, val))
    # 必须插在节点闭合 } 之前（blk2 已含结尾的 }）
    blk2 = blk2.rstrip()
    assert blk2.endswith('}'), blk2[-40:]
    blk2 = blk2[:-1].rstrip() + extra + '\n\t}'
    s = s[:start] + blk2 + s[i:]
    print('  ✓ mmc@fe000000 → okay（补齐 SDIO WiFi 属性）')
else:
    print('  ✗ 未找到 mmc@fe000000')


# 5) 关闭 K1 上不存在的 PCIe 控制器
#    实机（厂商 DT）实测：pcie@fe260000=okay、pcie@fe270000=disabled、pcie@fe280000=okay
#    而 T68M 基座把 fe270000 也启用了 → 本板报
#      rockchip-dw-pcie 3c0400000.pcie: probe failed -110
#    故按实机把 fe270000 关掉（另两个属于 M.2/PCIe2 功能项，留待第 2 步按实机时钟源重建）
for node in ('pcie@fe270000',):
    mm = re.search(r'(\n\t%s\s*\{)' % re.escape(node), s)
    if not mm:
        print('    ⚠ 未找到节点 %s' % node); continue
    start = mm.end(); depth = 1; i = start
    while i < len(s) and depth:
        if s[i] == '{': depth += 1
        elif s[i] == '}': depth -= 1
        i += 1
    blk = s[start:i]
    if 'status = "okay"' in blk:
        blk = blk.replace('status = "okay"', 'status = "disabled"', 1)
        print('    ✓ %s: okay → disabled（按实机）' % node)
    elif 'status = "disabled"' in blk:
        print('    · %s 本来就是 disabled' % node)
    else:
        blk = blk.rstrip()
        blk = blk[:-1].rstrip() + '\n\t\tstatus = "disabled";\n\t}'
        print('    ✓ %s: 补 status=disabled' % node)
    s = s[:start] + blk + s[i:]


# 6) 网口 PHY 复位（头号问题：缺它则 MDIO 无应答、end0/end1 全死）
#    数据出处：实机 DT
#      fe2a0000: reset=<gpio@fe750000, line27, active-low>, delays=<0,20000,100000>
#      fe010000: reset=<gpio@fe760000, line7,  active-low>, delays=<0,20000,100000>
#    实现：把属性【插进节点内部】（顶层 &{/path} 覆写在本 dtc 上会 FATAL；插属性这条路已验证可行）
def add_flag(text, node, prop):
    m = re.search(r'(\n\t%s\s*\{)' % re.escape(node), text)
    if not m: print('      ⚠ 找不到 %s' % node); return text
    start = m.end(); d = 1; k = start
    while k < len(text) and d:
        if text[k] == '{': d += 1
        elif text[k] == '}': d -= 1
        k += 1
    body = text[start:k]
    if re.search(r'\n\t\t%s\s*;' % re.escape(prop), body):
        return text
    return text[:start] + '\n\t\t%s;' % prop + body + text[k:]

for node, gpio, line in (('ethernet@fe2a0000', 'gpio@fe750000', '0x1b'),
                         ('ethernet@fe010000', 'gpio@fe760000', '0x07')):
    s, _ = set_prop(s, node, 'snps,reset-gpio',
                    '<&{/pinctrl/%s} %s 0x01>' % (gpio, line), must_exist=False)
    s, _ = set_prop(s, node, 'snps,reset-delays-us', '<0x00 0x4e20 0x186a0>', must_exist=False)
    s = add_flag(s, node, 'snps,reset-active-low')
    print('    ✓ %s: PHY reset = %s line %s (active-low, 20ms/100ms)' % (node, gpio, line))

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text(s)
print('  ✓ 写出 %s (%d 行)' % (OUT, len(s.splitlines())))
