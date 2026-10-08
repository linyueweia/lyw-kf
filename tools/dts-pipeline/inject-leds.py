#!/usr/bin/env python3
"""把实机 DT 的 leds 节点（含【子节点】）整棵注入我们的 DTS。

为什么单独做：通用合并器只搬属性，而 leds 的内容全在子节点（work-led / fan / gpioXy …），
之前日志里"系统灯不亮"就是缺这棵节点。本脚本：
  1) 从实机反编译文本取出 leds 整块
  2) 把子节点里 gpios = <0xNN line flags> 的 phandle 换成 <&{/pinctrl/gpio@ADDR} line flags>
     （注意：我们 DTS 里 gpio 控制器名不带 bank 数字）
  3) 去掉 phandle 属性，补 compatible = "gpio-leds"
  4) 插到根节点内（纯文本插入；顶层 &{/} 覆写在本机 dtc 会 FATAL）
  5) 用 dtc 判定，干净才算成功
"""
import re
import pathlib
import subprocess
import sys

WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
MERGED = WORK / 'k1-merged.dts'
LIVE = pathlib.Path('/tmp/live2.dts')

if not LIVE.exists():
    subprocess.run(['dtc', '-I', 'fs', '-O', 'dts', '-o', str(LIVE),
                    '/sys/firmware/devicetree/base'], check=True, capture_output=True)
live = LIVE.read_text(errors='ignore')
text = MERGED.read_text(errors='ignore')


def span(t, name):
    m = re.search(r'\n(\t*)' + re.escape(name) + r'\s*\{', t)
    if not m:
        return None
    i = m.end() - 1
    d = 0
    j = i
    while j < len(t):
        if t[j] == '{':
            d += 1
        elif t[j] == '}':
            d -= 1
            if d == 0:
                break
        j += 1
    return (i + 1, j)


# phandle → gpio 控制器地址
ph = {}
stack = []
for line in live.splitlines():
    ind = len(line) - len(line.lstrip('\t'))
    s = line.strip()
    mm = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
    if mm:
        while stack and stack[-1][0] >= ind:
            stack.pop()
        stack.append((ind, mm.group(1)))
        continue
    if s.startswith('}'):
        if stack:
            stack.pop()
        continue
    m2 = re.match(r'^phandle\s*=\s*<(0x[0-9a-fA-F]+|\d+)>;$', s)
    if m2 and stack:
        v = int(m2.group(1), 16) if m2.group(1).startswith('0x') else int(m2.group(1))
        ph[v] = stack[-1][1]

if re.search(r'\n\tleds\s*\{', text):
    print('  · 我们的 DTS 已有 leds 节点，先整块移除再注入实机版')
    m0 = re.search(r'\n\tleds\s*\{', text)
    i0 = m0.end() - 1
    d0 = 0
    j0 = i0
    while j0 < len(text):
        if text[j0] == '{':
            d0 += 1
        elif text[j0] == '}':
            d0 -= 1
            if d0 == 0:
                break
        j0 += 1
    j0 += 1
    while j0 < len(text) and text[j0] in ' \t\r\n':
        j0 += 1
    if j0 < len(text) and text[j0] == ';':
        j0 += 1
    text = text[:m0.start()] + text[j0:]

sp = span(live, 'leds')
if not sp:
    print('  ✗ 实机没有 leds 节点'); sys.exit(1)
body = live[sp[0]:sp[1]]

# 逐个 gpios 属性翻译 phandle
def fix_gpios(m):
    v = int(m.group(1), 16) if m.group(1).startswith('0x') else int(m.group(1))
    name = ph.get(v)
    if not name:
        return m.group(0)
    name = re.sub(r'^gpio[0-9](@[0-9a-f]+)$', r'gpio\1', name)   # 去掉 bank 数字
    return 'gpios = <&{/pinctrl/%s} %s>;' % (name, m.group(2).strip())

body = re.sub(r'gpios\s*=\s*<(0x[0-9a-fA-F]+|\d+)\s+([^>]+)>;', fix_gpios, body)
lines = [l for l in body.split('\n') if not re.match(r'^\s*phandle\s*=', l)]
body = '\n'.join(lines)
if 'compatible' not in body:
    body = '\n\t\tcompatible = "gpio-leds";' + body

block = '\tleds {' + body.rstrip() + '\n\t};'

# 插到根节点内
rm = re.search(r'\n/ \{', text)
if not rm:
    print('  ✗ 找不到根节点'); sys.exit(1)
i = text.index('{', rm.start()); d = 0; j = i
while j < len(text):
    if text[j] == '{':
        d += 1
    elif text[j] == '}':
        d -= 1
        if d == 0:
            break
    j += 1
text = text[:j] + '\n' + block + text[j:]
MERGED.write_text(text)

kids = re.findall(r'\n\t\t([\w\-\+,\@\.]+)\s*\{', block)
print('  注入 leds：子节点 %d 个 → %s' % (len(kids), kids))

d = subprocess.run(['dtc', '-f', '-Wno-pci_device_reg', '-Wno-unit_address_vs_reg',
                    '-I', 'dts', '-O', 'dtb', '-o', str(WORK / 'rk3568-kickpi-k1.dtb'),
                    str(MERGED)], capture_output=True, text=True)
hard = [l for l in d.stderr.splitlines() if 'ERROR' in l and 'Warning' not in l]
if hard:
    print('  ✗ dtc 报错：')
    for x in hard[:6]:
        print('     ' + x)
    sys.exit(1)
print('  ✓✓ dtc 0 ERROR/FATAL')
sys.exit(0)
