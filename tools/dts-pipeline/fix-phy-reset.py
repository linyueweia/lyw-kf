#!/usr/bin/env python3
"""按【新式 PHY 绑定】修好网口 PHY 的复位（并在 PHY 节点上清掉错厂商属性）。

实机日志证据（本次收集）：
  rk_gmac-dwmac fe2a0000.ethernet end0: PHY [stmmac-0:00] driver [Generic PHY]   ← PHY 没被识别
  rk_gmac-dwmac fe2a0000.ethernet end0: Failed to reset the dma                  ← RGMII 时钟没来
根因：我们只在 MAC 节点写了旧式 snps,reset-gpio；6.18 内核对 PHY 复位走的是
      PHY 节点里的 reset-gpios（新式绑定）。PHY 未被正确释放复位 → MDIO 读不到 ID
      （退化成 Generic PHY）→ RGMII 时钟不来 → MAC 的 DMA 软复位永不完成。
另外：PHY 节点上还残留 T68M 基座带来的 realtek,led*-triggers（本板 PHY 是 Maxio）→ 清掉。

对照实机（能跑）：ethernet@fe2a0000 的 snps,reset-gpio=<gpio2 27 1>；ethernet@fe010000 的 =<gpio3 7 1>
"""
import re, pathlib, sys

DTS = pathlib.Path('/work/kbuild/6.18.18-rockchip/work/k1-final.dts')
t = DTS.read_text(errors='ignore')

# 每个网口 → (PHY 复位 gpio 引用, 行号, 有效电平)
# fe2a0000: gpio2 line27 active-low ; fe010000: gpio3 line7 active-low
MAP = {
    'ethernet@fe2a0000': ('&{/pinctrl/gpio@fe750000} 0x1b 0x01', '0x1b'),
    'ethernet@fe010000': ('&{/pinctrl/gpio@fe760000} 0x07 0x01', '0x07'),
}
GPIO_REF = {
    'ethernet@fe2a0000': '/pinctrl/gpio@fe750000',
    'ethernet@fe010000': '/pinctrl/gpio@fe760000',
}

def span(text, name, indent='\t'):
    m = re.search(r'\n' + indent + re.escape(name) + r' \{', text)
    if not m:
        return None
    i = m.end() - 1; d = 0; j = i
    while j < len(text):
        if text[j] == '{': d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0: break
        j += 1
    return (i + 1, j)

fixed = 0
for eth, (gpioref, line) in MAP.items():
    sp = span(t, eth)
    if not sp:
        print('  ✗ 找不到 %s' % eth); continue
    body = t[sp[0]:sp[1]]
    # 找 mdio 子树里的 PHY 节点
    m = re.search(r'\n\t\t\t([\w\-\+,\@\.]+)\s*\{', body)
    if not m:
        print('  ✗ %s 里没有 PHY 子节点' % eth); continue
    phy_name = m.group(1)
    i = m.start(); d = 0; j = m.end() - 1
    while j < len(body):
        if body[j] == '{': d += 1
        elif body[j] == '}':
            d -= 1
            if d == 0: break
        j += 1
    phy_body = body[m.end():j]
    # ① 清掉错厂商属性（realtek,*）
    new = re.sub(r'\n\t+realtek,[^\n]*;', '', phy_body)
    removed = len(re.findall(r'realtek,', phy_body))
    # ② 加新式复位绑定（若还没有）
    if 'reset-gpios' not in new:
        new = ('\n\t\t\t\treset-gpios = <%s>;\n' % gpioref) + new
        new += '\n\t\t\t\treset-assert-us = <20000>;\n\t\t\t\treset-deassert-us = <100000>;'
    body2 = body[:m.end()] + new + body[j:]
    t = t[:sp[0]] + body2 + t[sp[1]:]
    print('  ✓ %s：清理 realtek 属性 %d 条，并在 PHY 节点加 reset-gpios=<%s> line %s' % (eth, removed, gpioref, line))
    fixed += 1

DTS.write_text(t)
# 自证
bad = []
for eth in MAP:
    sp = span(t, eth)
    b = t[sp[0]:sp[1]] if sp else ''
    if 'reset-gpios' not in b: bad.append('%s 缺 reset-gpios' % eth)
    if re.search(r'realtek,', b): bad.append('%s 仍有 realtek 属性' % eth)
print('  自证：修好 %d 个网口；问题 %s' % (fixed, bad if bad else '无 ✓'))
sys.exit(1 if bad else 0)
