#!/usr/bin/env python3
"""收尾合并：把【实机 DT】里对应节点的属性并入我们树（按 @地址 匹配，名字不同也能对上）。

用途（依据本次收集到的实机日志逐条）：
  rga iommu bind failed            → rga 缺 iommus（实机 rk_rga@fdeb0000 有）
  RKNPU … failed with error -110   → npu 缺 引用/电源域
  mpp-*: failed to attach service  → 缺 rockchip,srv 等
  phy-fe8c0000 … lock failed       → PCIe3 PHY 缺 refclk/grf/供电
  hdmi-sound: parse error          → 音频卡节点缺 dai 链接
  dwc3 … can't request region      → USB 胶水节点的 reg 与 dwc3 子节点重叠（本脚本只做属性合并）

规则：
  · 只处理白名单里的地址/名字（避免把已按主线对齐好的 SoC 节点又改回去）
  · 数字 phandle → 绝对路径引用；目标不存在时按地址兜底；再不行就丢掉该属性（保证 dtc 干净）
  · 属性插到【第一个子节点之前】；同名属性就地替换
  · 不新建节点、不删子节点
"""
import re
import pathlib
import subprocess
import sys

WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
OURS = WORK / 'k1-final.dts'
LIVE = pathlib.Path('/tmp/live2.dts')

# 白名单：@地址（或节点名）
ADDRS = {
    'fdeb0000',   # rga
    'fde40000',   # npu
    'fdee0000',   # vepu
    'fdf40000',   # rkvenc
    'fdf80200',   # rkvdec
    'fded0000',   # jpegd
    'fdef0000',   # iep
    'fe8c0000',   # pcie3 phy
    'fe820000',   # sata phy
    'fcc00000',   # usb3 otg
    'fd000000',   # usb3 host
    'fd800000', 'fd840000', 'fd880000', 'fd8c0000',  # usb2 hosts
}
NAMES = {'mpp-srv', 'hdmi-sound', 'bus-npu'}

PH_EVEN = ('clocks', 'assigned-clocks', 'dmas', 'phys', 'nvmem-cells')
PH_FIRST = ('interrupt-parent', 'power-domains', 'iommus', 'nvmem-cells', 'rockchip,grf',
            'rockchip,pmugrf', 'rockchip,pmu', 'resets', 'io-channels', 'memory-region',
            'rockchip,vo-grf', 'rockchip,pipe-grf', 'rockchip,pipe-phy-grf', 'rockchip,usbgrf',
            'rockchip,php-grf', 'rockchip,srv', 'operating-points-v2', 'rockchip,grf-pcie',
            'rockchip,power-controller', 'rockchip,usb-phy', 'gpio')
SKIP = {'phandle', 'linux,phandle', 'name', 'compatible', 'status'}


def parse_paths(t):
    paths, amap, stack = set(), {}, []
    for line in t.splitlines():
        ind = len(line) - len(line.lstrip('\t'))
        s = line.strip()
        m = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
        if m:
            while stack and stack[-1][0] >= ind:
                stack.pop()
            stack.append((ind, m.group(1)))
            p = '/' + '/'.join(x[1] for x in stack)
            paths.add(p)
            if '@' in m.group(1):
                amap.setdefault(m.group(1).split('@')[-1], p)
            continue
        if s.startswith('}'):
            if stack:
                stack.pop()
    return paths, amap


def phmap_of(t):
    m, stack = {}, []
    for line in t.splitlines():
        ind = len(line) - len(line.lstrip('\t'))
        s = line.strip()
        mm = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
        if mm:
            while stack and stack[-1][0] >= ind:
                stack.pop()
            stack.append((ind, mm.group(1), '/' + '/'.join([x[1] for x in stack] + [mm.group(1)])))
            continue
        if s.startswith('}'):
            if stack:
                stack.pop()
            continue
        ph = re.match(r'^phandle\s*=\s*<(0x[0-9a-fA-F]+|\d+)>;$', s)
        if ph and stack:
            v = int(ph.group(1), 16) if ph.group(1).startswith('0x') else int(ph.group(1))
            m[v] = stack[-1][2]
    return m


def span(text, name):
    m = re.search(r'\n\t' + re.escape(name) + r' \{', text)
    if not m:
        return None, None
    i = m.end() - 1
    d = 0
    j = i
    while j < len(text):
        if text[j] == '{':
            d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0:
                break
        j += 1
    return (i + 1, j), m


def top_props(body):
    out, depth = [], 0
    for line in body.split('\n'):
        s = line.strip()
        if depth == 0 and s and '=' in s and s.endswith(';'):
            pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=\s*(.*);$', s)
            if pm:
                out.append((pm.group(1), pm.group(2)))
        depth += line.count('{') - line.count('}')
    return out


def insert_index(body):
    depth = 0
    for idx, line in enumerate(body.split('\n')):
        if depth == 0 and line.strip().endswith('{'):
            return idx
        depth += line.count('{') - line.count('}')
    return len(body.split('\n'))


def main():
    if not LIVE.exists():
        subprocess.run(['dtc', '-I', 'fs', '-O', 'dts', '-o', str(LIVE),
                        '/sys/firmware/devicetree/base'], check=True, capture_output=True)
    live = LIVE.read_text(errors='ignore')
    text = OURS.read_text(errors='ignore')
    mine, myaddr = parse_paths(text)
    vph = phmap_of(live)

    # 建立 实机顶层节点 → 我们的节点名
    vtop = []
    for m in re.finditer(r'\n\t([\w\-\+,\@\.]+) \{', live):
        vtop.append(m.group(1))

    def ours_name(vname):
        if vname in NAMES or '@' not in vname:
            return vname if vname in NAMES else None
        a = vname.split('@')[-1]
        if a not in ADDRS:
            return None
        if a in myaddr:
            return myaddr[a].split('/')[-1]
        return None

    merged, dropped, missing = [], [], []
    for vname in vtop:
        oname = ours_name(vname)
        if not oname:
            continue
        osp, _ = span(text, oname)
        vsp, _ = span(live, vname)
        if not osp or not vsp:
            missing.append('%s→%s' % (vname, oname))
            continue
        vbody = live[vsp[0]:vsp[1]]
        want = []
        for pname, val in top_props(vbody):
            if pname in SKIP:
                continue
            if pname == 'status' and val == '"disabled"':
                continue
            if '\\0' in val:
                val = val.replace('\\0', '", "')
            mode = None
            if pname in PH_EVEN:
                mode = 'even'
            elif pname in PH_FIRST or pname.endswith('-supply') or pname.endswith('-gpios') \
                    or pname.startswith('pinctrl-'):
                mode = 'first'
            if mode:
                nums = list(re.finditer(r'(0x[0-9a-fA-F]+|\d+)', val))
                out, off, bad = val, 0, False
                for i, mm in enumerate(nums):
                    if mode == 'even' and i % 2 == 1:
                        continue
                    if mode == 'first' and i != 0:
                        continue
                    v = int(mm.group(1), 16) if mm.group(1).startswith('0x') else int(mm.group(1))
                    tgt = vph.get(v)
                    if not tgt:
                        bad = True
                        break
                    tgt = re.sub(r'^(/pinctrl/)gpio[0-9](@[0-9a-f]+)$', r'\1gpio\2', tgt)
                    if tgt not in mine:
                        # 按地址兜底：从路径最深处往前找带 @地址 的段，替换成我们在树里的对应路径
                        segs = [x for x in tgt.split('/') if x]
                        fixed = None
                        for i in range(len(segs) - 1, -1, -1):
                            if '@' in segs[i]:
                                a = segs[i].split('@')[-1]
                                if a in myaddr:
                                    base = myaddr[a]
                                    tail = '/'.join(segs[i + 1:])
                                    fixed = base + ('/' + tail if tail else '')
                                    break
                        if fixed and fixed in mine:
                            tgt = fixed
                        else:
                            dropped.append('%s.%s → %s 不存在' % (oname, pname, tgt))
                            bad = True
                            break
                    rep = '&{%s}' % tgt
                    a2, b2 = mm.start() + off, mm.end() + off
                    out = out[:a2] + rep + out[b2:]
                    off += len(rep) - len(mm.group(1))
                if bad:
                    continue
                val = out
            want.append((pname, val))
        if not want:
            continue
        body = text[osp[0]:osp[1]]
        names = {p for p, _ in want}
        kept, removed = [], 0
        for line in body.split('\n'):
            pm = re.match(r'^\s*([A-Za-z0-9,\-\#\+_\.]+)\s*=', line)
            if pm and pm.group(1) in names:
                removed += 1
                continue
            kept.append(line)
        b2 = '\n'.join(kept)
        idx = insert_index(b2)
        ind = '\t\t'
        for mm2 in re.finditer(r'\n(\t+)[A-Za-z0-9,\-\#\+_\.]+\s*=', b2):
            ind = mm2.group(1)
            break
        l2 = b2.split('\n')
        l2[idx:idx] = ['%s%s = %s;' % (ind, p, v) for p, v in want]
        text = text[:osp[0]] + '\n'.join(l2) + text[osp[1]:]
        merged.append('%s(%d)' % (oname, len(want)))

    OURS.write_text(text)
    print('  ✓ 合并 %d 个节点：%s' % (len(merged), ', '.join(merged)))
    if dropped:
        print('  ⚠ 丢弃属性 %d 条（目标不存在）' % len(dropped))
        for d in dropped[:6]:
            print('      ' + d)
    if missing:
        print('  ⚠ 找不到对应节点: %s' % missing[:5])
    return 0


if __name__ == '__main__':
    sys.exit(main())
