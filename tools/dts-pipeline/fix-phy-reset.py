#!/usr/bin/env python3
"""网口复位【单持有】门禁 + 清理（K1 飞牛 fnOS）。

取证结论（deleg_f8cea9c3 四路报告 + 板上 8 组日志实证）：
  · 复位线只允许【一个】持有者：MAC 侧 snps,reset-gpio + snps,reset-active-low
    + snps,reset-delays-us=<0 20000 100000>（L1 实机 / L2 官方6.1 / L3 官方5.10 三线一致）。
  · 24b1db5 曾在 PHY 节点再加一份 reset-gpios → 6.18 里 stmmac_mdio_reset() 先
    devm_gpiod_get("snps,reset")，PHY 侧 mdiobus_register_gpiod() 再要同一根线 →
    第二次 gpiod_request 返回 -EBUSY → mdio_device_register 失败 → 整个 GMAC probe
    失败（板上日志：`error -EBUSY: Cannot register the MDIO bus` ×16、
    `probe with driver rk_gmac-dwmac failed with error -16`，相位A）。
  · 反向也致命：只留 PHY 侧 → MDIO 扫 ID 早于拿复位脚 →
    `MDIO device at address 0 is missing` / `cannot attach to PHY (-ENODEV)`（相位C）。
  · 顺带清掉两处历史垃圾：queue0 里被正则错位写入的复位属性、PHY 节点的 realtek,*
    （旧版脚本用 `re.search('\\n\\t\\t\\t([\\w\\-...]+) \\{', body)` 抓“第一个子节点”，
     对 rx-queues-config/queue0 也命中 → 锚点错位的根因）。

本脚本只做【删】与【断言】，绝不新增 PHY 侧复位：
  1) ethernet-phy@0 块内若有 reset-gpios / reset-assert-us / reset-deassert-us → 删
  2) queue0 块内若有 reset-* → 删
  3) PHY 节点的 realtek,* 属性 → 删
  4) 断言：两个 MAC 节点三件套齐全；PHY 侧与 queue0 干净；全文件 realtek 为 0
违规 exit 1（流水线/CI 直接失败，不把坏 DTB 带出去）。
"""
import re, pathlib, sys

DTS = pathlib.Path('/work/kbuild/6.18.18-rockchip/work/k1-final.dts')
if not DTS.exists():
    print('  ✗ 找不到流水线工作文件 %s' % DTS)
    sys.exit(2)

t = DTS.read_text(errors='ignore')
MAC_NODES = ('ethernet@fe2a0000', 'ethernet@fe010000')


def all_blocks(text, opener_re):
    """返回 [(body_start, body_end)]，brace 配对，全部匹配项"""
    out = []
    for m in re.finditer(opener_re, text):
        i = m.end() - 1
        d, j = 0, i
        while j < len(text):
            if text[j] == '{':
                d += 1
            elif text[j] == '}':
                d -= 1
                if d == 0:
                    break
            j += 1
        out.append((m.end(), j))
    return out


def strip(body, props):
    n = 0
    for p in props:
        body, c = re.subn(r'\n[ \t]*' + re.escape(p) + r'\s*=\s*[^;]*;', '', body)
        n += c
    return re.sub(r'\n(?:[ \t]*\n)+', '\n', body), n


report, total = [], 0

# 1) PHY 节点（从后往前处理，避免位移）
for b0, b1 in reversed(all_blocks(t, r'\n\t+ethernet-phy@0 \{')):
    new, n = strip(t[b0:b1], ['reset-gpios', 'reset-assert-us', 'reset-deassert-us'])
    new, r = re.subn(r'\n[ \t]*realtek,[^;]*;', '', new)
    if n or r:
        t = t[:b0] + new + t[b1:]
        total += n
        report.append('  ✓ ethernet-phy@0: 删 PHY 侧复位 %d 条、realtek %d 条' % (n, r))

# 2) queue0（rx + tx，两个网口共 4 块）
for b0, b1 in reversed(all_blocks(t, r'\n\t+queue0 \{')):
    body = t[b0:b1]
    if not re.search(r'reset-(gpios|assert-us|deassert-us)', body):
        continue
    new, n = strip(body, ['reset-gpios', 'reset-assert-us', 'reset-deassert-us'])
    t = t[:b0] + new + t[b1:]
    total += n
    report.append('  ✓ queue0: 删错位写入的复位属性 %d 条' % n)

print('\n'.join(report) if report else '  ✓ 无需清理')

# 3) MAC 侧单持有者：缺则补齐（三线依据见文件头；只有 MAC 侧存在才同时过两道门）
MAC_RESET = {
    'ethernet@fe2a0000': '<&{/pinctrl/gpio@fe750000} 0x1b 0x01>',   # gpio2 RK_PD3, ACTIVE_LOW (L1/L2/L3)
    'ethernet@fe010000': '<&{/pinctrl/gpio@fe760000} 0x07 0x01>',   # gpio3 RK_PA7, ACTIVE_LOW (L1/L2/L3)
}
for eth, ref in MAC_RESET.items():
    m = re.search(r'\n\t' + re.escape(eth) + r' \{', t)
    if not m:
        continue
    i = m.end() - 1
    d, j = 0, i
    while j < len(t):
        if t[j] == '{':
            d += 1
        elif t[j] == '}':
            d -= 1
            if d == 0:
                break
        j += 1
    body = t[i:j]
    if 'snps,reset-gpio' in body:
        continue
    ins = ('\n\t\tsnps,reset-gpio = %s;' % ref +
           '\n\t\tsnps,reset-active-low;' +
           '\n\t\tsnps,reset-delays-us = <0x00 0x4e20 0x186a0>;')
    t = t[:j] + ins + '\n\t' + t[j:]
    report.append('  ✓ %s: 补 MAC 侧复位三件套 %s' % (eth, ref))
    print('  ✓ %s: 补 MAC 侧复位三件套' % eth)

# 4) 断言
bad = []
for eth in MAC_NODES:
    m = re.search(r'\n\t' + re.escape(eth) + r' \{', t)
    if not m:
        bad.append('%s 节点不存在' % eth)
        continue
    i = m.end() - 1
    d, j = 0, i
    while j < len(t):
        if t[j] == '{':
            d += 1
        elif t[j] == '}':
            d -= 1
            if d == 0:
                break
        j += 1
    body = t[i:j]
    for prop in ('snps,reset-gpio = ', 'snps,reset-active-low', 'snps,reset-delays-us'):
        if prop not in body:
            bad.append('%s 缺 %s' % (eth, prop.strip()))
if re.search(r'ethernet-phy@0 \{[^}]*reset-(gpios|assert-us|deassert-us)', t, re.S):
    bad.append('PHY 节点仍持有复位（双持有 → -EBUSY → MDIO 注册失败）')
if re.search(r'queue0 \{[^}]*reset-(gpios|assert-us|deassert-us)', t, re.S):
    bad.append('queue0 仍含复位垃圾属性')
if re.search(r'\n\s+realtek,', t):
    bad.append('仍有 realtek 属性（T68M 残留）')

print('  自证: 删除 %d 条；%s' % (total, '无问题 ✓' if not bad else '问题 → ' + '；'.join(bad)))
if bad or total:
    DTS.write_text(t)
sys.exit(1 if bad else 0)
