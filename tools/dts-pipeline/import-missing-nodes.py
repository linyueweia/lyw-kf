#!/usr/bin/env python3
"""把【实机 DT 里有、我们树里没有】的顶层节点整棵导入我们的 DTS。

做法（与 inject-leds 同源，推广到任意节点）：
  · 按 "@地址" 判定"我们是否已有"（节点名不同也能对上：dwmmc@fe000000 ↔ mmc@fe000000）
  · 只导入实机 status=okay 的节点
  · 整棵拷贝（属性 + 子节点，递归）
  · 属性里的数字 phandle 一律翻译成【绝对路径引用】<&{/path}>；若目标在我们树里不存在
    且也不能按地址对上 → 丢掉该属性（保证 dtc 干净，宁缺勿错）
  · 去掉 phandle 属性本身
  · 插到根节点内（顶层 &{/} 覆写在本机 dtc 会 FATAL）
"""
import re
import pathlib
import subprocess
import sys

WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
OURS = WORK / 'k1-final.dts'
LIVE = pathlib.Path('/tmp/live2.dts')

PH_EVEN = ('clocks', 'assigned-clocks', 'dmas', 'phys', 'nvmem-cells')
PH_FIRST = ('interrupt-parent', 'power-domains', 'iommus', 'nvmem-cells', 'rockchip,grf',
            'rockchip,pmugrf', 'rockchip,pmu', 'resets', 'io-channels', 'memory-region',
            'rockchip,vo-grf', 'rockchip,pipe-grf', 'rockchip,usbgrf', 'rockchip,php-grf',
            'gpio', 'port', 'rockchip,grf-pcie', 'rockchip,srv',
            'rockchip,grf-pcie', 'operating-points-v2', 'rockchip,grf',
            'rockchip,taskqueue-node', 'rockchip,pmu', 'rockchip,power-controller')


def parse_tree(t):
    """返回 (nodes, phmap)；nodes: {path: (indent,name,status,body_span)}"""
    nodes, phmap, stack = {}, {}, []
    lines = t.split('\n')
    pos = 0
    for idx, line in enumerate(lines):
        s = line.strip()
        ind = len(line) - len(line.lstrip('\t'))
        m = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
        if m:
            while stack and stack[-1][0] >= ind:
                stack.pop()
            path = '/' + '/'.join([x[1] for x in stack] + [m.group(1)])
            stack.append((ind, m.group(1), path, idx, None))
            continue
        ph = re.match(r'^phandle\s*=\s*<(0x[0-9a-fA-F]+|\d+)>;$', s)
        if ph and stack:
            v = int(ph.group(1), 16) if ph.group(1).startswith('0x') else int(ph.group(1))
            phmap[v] = stack[-1][2]
            continue
        st = re.match(r'^status\s*=\s*"([^"]+)";$', s)
        if st and stack:
            for k in range(len(stack) - 1, -1, -1):
                if stack[k][4] is None:
                    stack[k] = (stack[k][0], stack[k][1], stack[k][2], stack[k][3], st.group(1))
                    break
            continue
        if s.startswith('}'):
            if stack:
                ind2, name, path, lidx, status = stack.pop()
                nodes[path] = (ind2, name, status, (lidx, idx))
    return nodes, phmap


def addr_of(path):
    seg = path.rstrip('/').split('/')[-1]
    return seg.split('@')[-1] if '@' in seg else None


def block_of(t, lidx, ridx):
    lines = t.split('\n')
    return '\n'.join(lines[lidx:ridx + 1])


def translate_body(body, phmap, ours_paths, ours_addr, importing, warnings, depth=0):
    """逐行处理节点体：翻译/丢弃 phandle 引用，去 phandle 属性，递归子节点"""
    out = []
    pad = '\t' * depth
    for line in body.split('\n'):
        s = line.strip()
        if re.match(r'^phandle\s*=', s) or re.match(r'^linux,phandle\s*=', s):
            continue
        pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=\s*(.*);$', s)
        if pm:
            prop, val = pm.group(1), pm.group(2)
            if '\\0' in val:
                val = val.replace('\\0', '", "')
            mode = None
            if prop in PH_EVEN:
                mode = 'even'
            elif prop in PH_FIRST or prop.endswith('-supply') or prop.endswith('-gpios') \
                    or prop in ('gpios',) or prop.startswith('pinctrl-'):
                mode = 'first'
            if mode:
                nums = list(re.finditer(r'(0x[0-9a-fA-F]+|\d+)', val))
                newval, off, bad = val, 0, False
                for i, m in enumerate(nums):
                    if mode == 'even' and i % 2 == 1:
                        continue
                    if mode == 'first' and i != 0:
                        continue
                    v = int(m.group(1), 16) if m.group(1).startswith('0x') else int(m.group(1))
                    tgt = phmap.get(v)
                    if not tgt:
                        bad = True
                        break
                    tgt = re.sub(r'^(/pinctrl/)gpio[0-9](@[0-9a-f]+)$', r'\1gpio\2', tgt)
                    if tgt not in ours_paths and tgt not in importing:
                        a = addr_of(tgt)
                        if a and a in ours_addr:
                            tgt = ours_addr[a]
                        else:
                            warnings.append('%s: 目标 %s 不存在 → 丢弃该属性' % (prop, tgt))
                            bad = True
                            break
                    rep = '&{%s}' % tgt
                    a2, b2 = m.start() + off, m.end() + off
                    newval = newval[:a2] + rep + newval[b2:]
                    off += len(rep) - len(m.group(1))
                if bad:
                    continue
                val = newval
            out.append('%s%s = %s;' % (pad, prop, val))
            continue
        m2 = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
        if m2:
            # 子节点：保留（含其内部），递归翻译
            out.append('%s%s {' % (pad, m2.group(1)))
            continue
        if s.startswith('}'):
            out.append(pad + '};')
            continue
        if s == '':
            continue
        out.append(pad + s)
    return '\n'.join(out)


def main():
    live = LIVE.read_text(errors='ignore')
    ours = OURS.read_text(errors='ignore')
    vnodes, vph = parse_tree(live)
    onodes, oph = parse_tree(ours)

    ours_paths = set(onodes)
    ours_addr = {}
    for p in onodes:
        a = addr_of(p)
        if a:
            ours_addr.setdefault(a, p)

    # 候选：实机【顶层】节点（路径只有一层），status=okay，且我们按地址/名字都没有
    BLACK = ('dmc', 'dmc-fsp', 'dfi@', 'ddr3-params', 'ddr4-params', 'cpuinfo',
             'debug@', 'cspmu@', 'arm-pmu', 'rockchip-suspend', 'rkisp-vir0',
             'gc5035@', 'csi2-dphy', 'mipi-csi2', 'rkisp@', 'nandc@')
    targets = []
    for path, (ind, name, status, span) in sorted(vnodes.items()):
        if path.count('/') != 1:
            continue
        if status not in (None, 'okay'):
            continue
        if any(name.startswith(b) or name == b for b in BLACK):
            continue
        a = addr_of(path)
        # 文本查重：同名节点 或 同地址节点（名不同也算已有，如 dwmmc@fe000000 ↔ mmc@fe000000）
        have = bool(re.search(r'\n\s*' + re.escape(name) + r'\s*\{', ours))
        if not have and a:
            have = bool(re.search(r'\n\s*[\w\-\+]+\@' + re.escape(a) + r'\s*\{', ours))
        if have:
            continue
        targets.append((path, name, span))

    print('  实机顶层节点 %d 个；待导入 %d 个：' % (len([1 for p in vnodes if p.count("/") == 1]), len(targets)))
    importing = {p for p, _, _ in targets}
    warnings = []
    blocks = []
    for path, name, (lidx, ridx) in targets:
        body = block_of(live, lidx, ridx)
        # 去掉最外层名字行与结尾 '}'，只取体内
        lines = body.split('\n')
        inner = '\n'.join(lines[1:-1])
        newbody = translate_body(inner, vph, ours_paths, ours_addr, importing, warnings, depth=1)
        blocks.append('\t%s {\n%s\n\t};' % (name, newbody))
        print('      + %s' % name)

    if not blocks:
        print('  无需导入'); return 0

    # 插到根节点结束之前
    rm = re.search(r'\n/ \{', ours)
    i = ours.index('{', rm.start())
    d, j = 0, i
    while j < len(ours):
        if ours[j] == '{':
            d += 1
        elif ours[j] == '}':
            d -= 1
            if d == 0:
                break
        j += 1
    ours = ours[:j] + '\n' + '\n'.join(blocks) + ours[j:]
    OURS.write_text(ours)
    print('  ✓ 已导入 %d 个节点（%d 行）' % (len(blocks), len(ours.splitlines())))
    if warnings:
        print('  ⚠ 因目标不存在而丢弃的属性 %d 条（前 12）:' % len(warnings))
        for w in warnings[:12]:
            print('      ' + w)
    return 0


if __name__ == '__main__':
    sys.exit(main())
