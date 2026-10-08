#!/usr/bin/env python3
"""用【同一内核版本的主线 DTB】覆盖我们的 SoC 级节点属性。

为什么：我们的 DTS 基座来自厂商 5.10 反编译树，而飞牛内核是 6.18 —— 同一硬件节点的
驱动绑定已经变了（实测两例）：
  · vop：厂商写 reg-names="regs","gamma_lut"，6.18 主线是 "vop","gamma-lut"
    → 驱动 by name 取不到 → "failed to get vop2 register byname" (-EINVAL)
  · gmac：厂商节点没有 resets/reset-names、clocks 不全
    → "Failed to reset the dma" / "DMA engine initialization failed"
做法：把 6.18 主线 DTB（/work/kbuild/6.18.18-rockchip/dtbs/ 或基镜像 /boot/dtb/rockchip/）
      对应节点的【属性】翻译成绝对路径引用后覆盖进来；板级专属属性保持我们的不动。
"""
import re
import pathlib
import subprocess
import sys

WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
SRC_DTS = WORK / 'k1-merged.dts'          # 上一步的产物（含板级修复）
OUT_DTS = WORK / 'k1-final.dts'

MAINLINE_CANDIDATES = [
    pathlib.Path('/work/kbuild/6.18.18-rockchip/dtbs/rk3568-evb1-v10.dtb'),
    pathlib.Path('/work/kbuild/6.18.18-rockchip/dtbs/rk3568-easepi-r1.dtb'),
    pathlib.Path('/mnt/chk2/dtb/rockchip/rk3568-evb1-v10.dtb'),
    pathlib.Path('/mnt/k1boot/dtb/rockchip/rk3568-evb1-v10.dtb'),
]

# 要覆盖的节点（SoC 级：时钟/复位/寄存器名/iommu/电源域）
TARGETS = ['vop@fe040000', 'ethernet@fe010000', 'ethernet@fe2a0000', 'rga@fdeb0000',
           'pcie@fe260000', 'pcie@fe280000', 'phy@fe8c0000',
           'hdmi@fe0a0000', 'gpu@fde60000', 'hsv@fde50000']

# 板级专属：这些属性【不】让主线覆盖（PHY 复位/延迟由我们按本板实机 DT 决定）
KEEP_LOCAL = {
    'ethernet@fe010000': {'phy-handle', 'phy-mode', 'tx_delay', 'rx_delay',
                          'pinctrl-0', 'pinctrl-1', 'pinctrl-2', 'pinctrl-3',
                          'snps,reset-gpio', 'snps,reset-active-low', 'snps,reset-delays-us',
                          'clock_in_out'},
    'ethernet@fe2a0000': {'phy-handle', 'phy-mode', 'tx_delay', 'rx_delay',
                          'pinctrl-0', 'pinctrl-1', 'pinctrl-2', 'pinctrl-3',
                          'snps,reset-gpio', 'snps,reset-active-low', 'snps,reset-delays-us',
                          'clock_in_out'},
}
# 子节点一律不动（vop 的 ports、gmac 的 mdio 都是板级的）
SKIP_PROPS = {'phandle', 'linux,phandle', 'name', 'compatible',
              'assigned-clock-parents', 'assigned-clock-rates'}


def decompile(p):
    out = pathlib.Path('/tmp/mainline.dts')
    subprocess.run(['dtc', '-I', 'dtb', '-O', 'dts', '-o', str(out), str(p)],
                   check=True, capture_output=True)
    return out.read_text(errors='ignore')


def build_phmap(dts):
    m, stack = {}, []
    for line in dts.splitlines():
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


def our_paths(text):
    """返回 (全部路径集合, 地址→路径映射)；用缩进栈解析，路径才正确"""
    paths, amap, stack = set(), {}, []
    for line in text.splitlines():
        ind = len(line) - len(line.lstrip('\t'))
        s = line.strip()
        m = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
        if m:
            while stack and stack[-1][0] >= ind:
                stack.pop()
            stack.append((ind, m.group(1)))
            pp = '/' + '/'.join(x[1] for x in stack)
            paths.add(pp)
            seg = m.group(1)
            if '@' in seg:
                amap.setdefault(seg.split('@')[-1], pp)
            continue
        if s.startswith('}'):
            if stack:
                stack.pop()
    return paths, amap


def span(text, name):
    m = re.search(r'\n\t' + re.escape(name) + r' \{', text)
    if not m:
        return None
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
    return (i + 1, j)


def top_props(body):
    out, depth = [], 0
    for line in body.split('\n'):
        s = line.strip()
        if depth == 0 and s and '=' in s and s.endswith(';') and not s.endswith('{'):
            pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=', s)
            if pm:
                out.append((pm.group(1), s))
        depth += line.count('{') - line.count('}')
    return out


def insert_index(body):
    depth = 0
    for idx, line in enumerate(body.split('\n')):
        s = line.strip()
        if depth == 0 and s.endswith('{'):
            return idx
        depth += line.count('{') - line.count('}')
    return len(body.split('\n'))


PH_NAMES = ('clocks', 'iommus', 'power-domains', 'rockchip,grf', 'resets', 'phys',
            'assigned-clocks', 'assigned-clock-parents', 'assigned-clock-rates',
            'snps,axi-config', 'snps,mtl-rx-config', 'snps,mtl-tx-config', 'phys')


def addr_of(path):
    seg = path.rstrip('/').split('/')[-1]
    return seg.split('@')[-1] if '@' in seg else None


def translate(prop, val, phmap, mine, warns, addr_map=None):
    nums = list(re.finditer(r'(0x[0-9a-fA-F]+|\d+)', val))
    if not nums:
        return val
    mode = None
    if prop in ('clocks', 'assigned-clocks', 'dmas', 'phys'):
        mode = 'even'
    elif prop in ('iommus', 'power-domains', 'rockchip,grf', 'resets',
                  'snps,axi-config', 'snps,mtl-rx-config', 'snps,mtl-tx-config') or \
            prop.endswith('-supply') or prop.endswith('-gpios') or prop.startswith('pinctrl-'):
        mode = 'first'
    if mode is None:
        return val
    out, off = val, 0
    for idx, m in enumerate(nums):
        if mode == 'even' and idx % 2 == 1:
            continue
        if mode == 'first' and idx != 0:
            continue
        v = int(m.group(1), 16) if m.group(1).startswith('0x') else int(m.group(1))
        tgt = phmap.get(v)
        if not tgt:
            warns.append('%s: 0x%x 无对应节点' % (prop, v)); continue
        tgt = re.sub(r'^(/pinctrl/)gpio[0-9](@[0-9a-f]+)$', r'\1gpio\2', tgt)
        if tgt not in mine:
            a = addr_of(tgt)
            if a and addr_map and a in addr_map:
                tgt2 = addr_map[a]
                warns.append('%s: %s 我们树里没有 → 按地址改用 %s' % (prop, tgt, tgt2))
                tgt = tgt2
            else:
                warns.append('%s: 目标 %s 我们树里没有 → 丢弃该属性' % (prop, tgt))
                return None
        rep = '&{%s}' % tgt
        a, b = m.start() + off, m.end() + off
        out = out[:a] + rep + out[b:]
        off += len(rep) - len(m.group(1))
    return out


CHILD_IMPORTS = {
    'ethernet@fe010000': ['stmmac-axi-config', 'rx-queues-config', 'tx-queues-config'],
    'ethernet@fe2a0000': ['stmmac-axi-config', 'rx-queues-config', 'tx-queues-config'],
}


def import_children(text, node, kids, ml, phmap, mine, addr_map, warns):
    """把主线里 node 的子节点 kids 复制进我们的 node（属性翻译成路径引用）"""
    nsp = span(text, node)
    msp = span(ml, node)
    if not nsp or not msp:
        return text, 0
    body_ml = ml[msp[0]:msp[1]]
    nbody0 = text[nsp[0]:nsp[1]]
    blocks = []
    for kid in kids:
        if re.search(r'\n\t\t' + re.escape(kid) + r' \{', nbody0):
            continue            # 我们已有该子节点：不导入，后面只把属性重指到它
        # body_ml 里的子节点缩进是 \t\t
        m = re.search(r'\n\t\t' + re.escape(kid) + r' \{', body_ml)
        if not m:
            continue
        i = m.end() - 1
        d = 0
        j = i
        while j < len(body_ml):
            if body_ml[j] == '{':
                d += 1
            elif body_ml[j] == '}':
                d -= 1
                if d == 0:
                    break
            j += 1
        kbody = body_ml[i+1:j]
        props = []
        for pname, pline in top_props(kbody):
            if pname in ('phandle', 'linux,phandle', 'name'):
                continue
            pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=\s*(.*);$', pline)
            if not pm:
                continue
            props.append((pname, pm.group(2).strip()))
        blk = '\t\t%s {\n' % kid + ''.join('\t\t\t%s = %s;\n' % (pp, vv) for pp, vv in props) + '\t\t};'
        blocks.append(blk)
    if not blocks:
        return text, 0
    # 追加到我们节点体末尾（子节点在属性之后，合法）
    ins = '\n' + '\n'.join(blocks) + '\n'
    return text[:nsp[1]] + ins + text[nsp[1]:], len(blocks)


def main():
    src = next((p for p in MAINLINE_CANDIDATES if p.exists()), None)
    if not src:
        print('  ✗ 找不到主线 DTB'); return 1
    print('  主线基线: %s' % src)
    ml = decompile(src)
    phmap = build_phmap(ml)
    print('  主线 phandle 表: %d 项' % len(phmap))

    text = SRC_DTS.read_text(errors='ignore')
    mine, addr_map = our_paths(text)
    changed, dropped = [], []
    for node in TARGETS:
        msp = span(ml, node)
        osp = span(text, node)
        if not msp:
            print('    · %-20s 主线无此节点（跳过）' % node); continue
        if not osp:
            print('    · %-20s 我们无此节点（跳过）' % node); continue
        keep = KEEP_LOCAL.get(node, set())
        body_ml = ml[msp[0]:msp[1]]
        want = []
        for pname, pline in top_props(body_ml):
            if pname in SKIP_PROPS or pname in keep:
                continue
            pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=\s*(.*);$', pline)
            if not pm:
                continue
            val = pm.group(2).strip()
            if '\\0' in val:
                val = val.replace('\\0', '", "')
            tv = translate(pname, val, phmap, mine, dropped, addr_map)
            if tv is None:
                dropped.append('%s.%s（引用我们树里没有的节点）' % (node, pname)); continue
            want.append((pname, '= ' + tv))
        if not want:
            print('    · %-20s 无可覆盖属性' % node); continue
        body = text[osp[0]:osp[1]]
        lines = body.split('\n')
        names = {p for p, _ in want}
        kept = [l for l in lines
                if not (re.match(r'^\s*([A-Za-z0-9,\-\#\+_\.]+)\s*=', l) and
                        re.match(r'^\s*([A-Za-z0-9,\-\#\+_\.]+)\s*=', l).group(1) in names)]
        b2 = '\n'.join(kept)
        idx = insert_index(b2)
        ind = '\t\t'
        for mm2 in re.finditer(r'\n(\t+)[A-Za-z0-9,\-\#\+_\.]+\s*=', b2):
            ind = mm2.group(1); break
        l2 = b2.split('\n')
        l2[idx:idx] = ['%s%s %s;' % (ind, p, v) for p, v in want]
        text = text[:osp[0]] + '\n'.join(l2) + text[osp[1]:]
        changed.append('%s(%d)' % (node, len(want)))
        print('    ✓ %-20s 覆盖 %d 属性：%s' % (node, len(want), ', '.join(p for p, _ in want[:8])))

    for node, kids in CHILD_IMPORTS.items():
        text, n = import_children(text, node, kids, ml, phmap, mine, addr_map, dropped)
        if n:
            print('    ✓ %-20s 导入 %d 个 DMA 参数子节点（主线版）' % (node, n))
    # 子节点就位后，把 snps,*config 指向本节点内的子节点（先去重，再各插一条）
    for node in CHILD_IMPORTS:
        nsp = span(text, node)
        if not nsp:
            continue
        body = text[nsp[0]:nsp[1]]
        pairs = [('snps,axi-config', 'stmmac-axi-config'),
                 ('snps,mtl-rx-config', 'rx-queues-config'),
                 ('snps,mtl-tx-config', 'tx-queues-config')]
        lines = body.split('\n')
        # ① 删掉这些属性的所有出现（只留一条正确的）
        keep, removed = [], 0
        for line in lines:
            st = line.strip()
            hit = False
            for prop, kid in pairs:
                if st.startswith(prop + ' =') or st.startswith(prop + '='):
                    hit = True
            if hit:
                removed += 1
                continue
            keep.append(line)
        body2 = '\n'.join(keep)
        # ② 各插一条，指向本节点内真实存在的子节点
        ind = '\t\t'
        for mm2 in re.finditer(r'\n(\t+)[A-Za-z0-9,\-\#\+_\.]+\s*=', body2):
            ind = mm2.group(1); break
        add = []
        for prop, kid in pairs:
            if re.search(r'\n\s*' + re.escape(kid) + r' \{', body2):
                add.append('%s%s = <&{/%s/%s}>;' % (ind, prop, node, kid))
        if add:
            l2 = body2.split('\n')
            idx = insert_index(body2)
            l2[idx:idx] = add
            body2 = '\n'.join(l2)
        if removed or add:
            print('    ✓ %-20s snps,*config 去重 %d 条 → 重指 %d 条（指向本节点内子节点）'
                  % (node, removed, len(add)))
        text = text[:nsp[0]] + body2 + text[nsp[1]:]

    OUT_DTS.write_text(text)
    print('  写出 %s（%d 行）' % (OUT_DTS, len(text.splitlines())))
    if dropped:
        print('  ⚠ 丢弃 %d 项：' % len(dropped))
        for d in dropped[:10]:
            print('      ' + d)
    return 0


if __name__ == '__main__':
    sys.exit(main())
