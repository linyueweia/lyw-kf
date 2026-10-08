#!/usr/bin/env python3
"""补齐 ethernet-phy@N 的 reg，并清理 mdio 节点【自身层级】误插的 reg。

实机日志证据：mdio_bus stmmac-0: ethernet-phy@0 has invalid PHY address
缺 reg → 取不到 PHY 地址 → 读不到 PHY ID(0x7b744411) → 退化成 Generic PHY。

两次踩坑（都记下来）：
  1) re.finditer 迭代同时改文本 → 偏移失效 → reg 插错节点；
  2) "删 mdio 体内的 reg" 会连【子节点 ethernet-phy 里的 reg】一起删掉 ——
     必须按层级：只删 mdio 自己那一层（depth 0）。
"""
import re, pathlib, sys

DTS = pathlib.Path('/work/kbuild/6.18.18-rockchip/work/k1-final.dts')
t = DTS.read_text(errors='ignore')


def body_span(text, brace_pos):
    d = 0
    j = brace_pos
    while j < len(text):
        if text[j] == '{':
            d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0:
                break
        j += 1
    return (brace_pos + 1, j)


edits = []
# ① 只删 mdio 自己那一层的 reg（depth==0），不动子节点里的
for m in re.finditer(r'\n(\t+)mdio\s*\{', t):
    bs, be = body_span(t, m.end() - 1)
    body = t[bs:be]
    off = 0
    depth = 0
    for line in body.split('\n'):
        s = line.strip()
        if depth == 0 and re.match(r'^reg\s*=', s):
            edits.append(('del', bs + off, bs + off + len(line) + 1))
        off += len(line) + 1
        depth += line.count('{') - line.count('}')

# ② 每个 ethernet-phy@N 缺 reg 就补（补在该节点体最前面）
for m in re.finditer(r'\n(\t+)ethernet-phy@([0-9a-fA-F]+)\s*\{', t):
    ind = m.group(1)
    addr = int(m.group(2), 16)
    bs, be = body_span(t, m.end() - 1)
    if re.search(r'\n\t+reg\s*=', t[bs:be]):
        continue
    edits.append(('ins', bs, '\n%s\treg = <0x%02x>;' % (ind, addr)))

edits.sort(key=lambda e: e[1], reverse=True)
n_del = n_ins = 0
for e in edits:
    if e[0] == 'del':
        t = t[:e[1]] + t[e[2]:]
        n_del += 1
    else:
        t = t[:e[1]] + e[2] + t[e[1]:]
        n_ins += 1
DTS.write_text(t)
print('  清理 mdio 自身层级的 reg: %d 处；补齐 ethernet-phy 的 reg: %d 个' % (n_del, n_ins))

bad, ok = [], 0
for m in re.finditer(r'\n(\t+)mdio\s*\{', t):
    bs, be = body_span(t, m.end() - 1)
    depth = 0
    for line in t[bs:be].split('\n'):
        if depth == 0 and re.match(r'^reg\s*=', line.strip()):
            bad.append('mdio 自身仍有 reg')
        depth += line.count('{') - line.count('}')
for m in re.finditer(r'\n(\t+)ethernet-phy@([0-9a-fA-F]+)\s*\{', t):
    bs, be = body_span(t, m.end() - 1)
    if re.search(r'\n\t+reg\s*=', t[bs:be]):
        ok += 1
    else:
        bad.append('ethernet-phy@%s 缺 reg' % m.group(2))
print('  自证：带 reg 的 PHY 节点 %d 个；问题 %s' % (ok, bad if bad else '无 ✓'))
sys.exit(1 if bad else 0)
