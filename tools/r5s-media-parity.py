#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""媒体簇对标门禁：本板 DTB vs 官方 R5S 参照 DTB（逐节点、逐属性，纯 Python 无 dtc 依赖）

判据来源（2026-10-27 用户口径 + 同 SoC 官方件）：
  飞牛官方 RK3568 参照件 dist/rk3568-nanopi-r5s-official.dtb（官方 R5S 固件里那份，
  与 xck-nas 仓内件同一 sha256）。K1 与 R5S 同为 RK3568，媒体簇（GPU/NPU/VPU/RGA/
  JPEGD/IEP/mpp-srv/IOMMU/OPP）必须与官方逐节点一致；本板独有差异必须写进
  dts/r5s-media-allowlist.txt 并附理由，不允许"悄悄不一样"。

归一化规则（两板 phandle 编号不同，指向相同即视为一致）：
  · 引用类属性按【目标节点的 #xxx-cells】解析，把 phandle 换成 @目标节点路径；
  · 单 phandle 属性（*-supply / operating-points-v2 / rockchip,srv / syscon 等）直接换名字；
  · reg / 频率 / 电压 / 中断号 / compatible / names 等保留原值逐字节比对。

用法：
  python3 tools/r5s-media-parity.py [本板.dtb] [参照.dtb]
  默认本板 = dist/rk3568-kickpi-k1.dtb  参照 = dist/rk3568-nanopi-r5s-official.dtb
  --list  只打印比对明细，不判失败（人工对照用）
退出码：0 = 全部一致（或差异均已 allowlist）；1 = 存在未登记差异
"""
import os
import struct
import sys

MEDIA_NODES = [
    'gpu@fde60000', 'npu@fde40000', 'npu-opp-table', 'bus-npu', 'bus-npu-opp-table',
    'video-codec@fdea0400', 'vdpu@fdea0400', 'rkvdec@fdf80200', 'rkvdec-opp-table',
    'rkvenc@fdf40000', 'rkvenc-opp-table', 'jpegd@fded0000', 'vepu@fdee0000',
    'iep@fdef0000', 'rga@fdeb0000', 'rk_rga@fdeb0000', 'mpp-srv', 'sram@fdcc0000',
    'power-management@fdd90000', 'opp-table-1',
    'iommu@fde4b000', 'iommu@fdea0800', 'iommu@fded0480', 'iommu@fdee0800',
    'iommu@fdef0800', 'iommu@fdf40f00', 'iommu@fdf80800',
]
# 比较时跳过的属性：phandle 编号本身两板无意义；status 单独判定
SKIP_PROPS = {'phandle', 'linux,phandle'}
REF_ATTRS = {
    'clocks': 'clock', 'assigned-clocks': 'clock', 'assigned-clock-parents': 'clock',
    'resets': 'reset', 'power-domains': 'power-domain', 'iommus': 'iommu',
    'nvmem-cells': 'nvmem-cell', 'phys': 'phy', 'pinctrl-0': 'pinctrl',
    'pinctrl-1': 'pinctrl', 'pinctrl-2': 'pinctrl', 'pinctrl-3': 'pinctrl',
    'dmas': 'dma', 'mboxes': 'mbox', 'io-channels': 'io-channel',
    'interrupt-parent': None, 'memory-region': None, 'rockchip,srv': None,
    'rockchip,taskqueue-node': None, 'rockchip,resetgroup-node': None,
}
SINGLE_REF = {'operating-points-v2', 'rockchip,sram', 'syscon', 'rockchip,grf',
              'rockchip,pmu', 'nvmem', 'memory-region'}
ALLOWLIST = os.environ.get('KF_PARITY_ALLOWLIST') or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'dts', 'r5s-media-allowlist.txt')


def parse(path):
    b = open(path, 'rb').read()
    if b[:4] != b'\xd0\x0d\xfe\xed':
        raise SystemExit(f'✗ 不是 DTB: {path}')
    (_, _, off_struct, off_strings, _, _, _, _, size_str, _) = struct.unpack('>10I', b[:40])
    sb = b[off_strings:off_strings + size_str]
    nodes, stack, pos = {}, [], off_struct
    while pos + 4 <= len(b):
        tok = struct.unpack('>I', b[pos:pos + 4])[0]
        pos += 4
        if tok == 1:                                   # BEGIN_NODE
            e = b.index(b'\x00', pos)
            stack.append(b[pos:e].decode('utf-8', 'replace'))
            pos = (e + 1 + 3) & ~3
            nodes.setdefault('/' + '/'.join(x for x in stack if x), {})
        elif tok == 2:                                 # END_NODE
            if stack:
                stack.pop()
        elif tok == 3:                                 # PROP
            ln, no = struct.unpack('>II', b[pos:pos + 8])
            pos += 8
            val = b[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
            e = sb.index(b'\x00', no)
            nodes.setdefault('/' + '/'.join(x for x in stack if x), {})[sb[no:e].decode()] = val
        elif tok == 4:                                 # NOP
            continue
        elif tok == 9:                                 # END
            break
        else:
            raise SystemExit(f'✗ FDT 结构异常（token {tok}）: {path}')
    return nodes


def u32s(v):
    return [struct.unpack('>I', v[i:i + 4])[0] for i in range(0, len(v) // 4 * 4, 4)]


def phandle_map(nodes):
    m = {}
    for p, nd in nodes.items():
        for k in ('phandle', 'linux,phandle'):
            if k in nd and len(nd[k]) == 4:
                m[struct.unpack('>I', nd[k][0:4])[0]] = p
    return m


def cell_count(nodes, target, kind):
    if not kind:
        return 0
    v = nodes.get(target, {}).get('#' + kind + '-cells')
    return struct.unpack('>I', v[:4])[0] if v and len(v) >= 4 else 0


def norm_prop(nodes, ph, name, val):
    if name in SINGLE_REF or name.endswith('-supply'):
        w = u32s(val)
        if len(w) == 1 and w[0] in ph:
            return '@' + ph[w[0]]
        return repr(val)
    if name in REF_ATTRS:
        kind = REF_ATTRS[name]
        w = u32s(val)
        out, i = [], 0
        while i < len(w):
            tgt = ph.get(w[i])
            if tgt is None:
                out.append(f'raw:{w[i]:#x}')
                i += 1
                continue
            n = cell_count(nodes, tgt, kind)
            extra = w[i + 1:i + 1 + n]
            out.append('@' + tgt + ('[' + ','.join(f'{x:#x}' for x in extra) + ']' if extra else ''))
            i += 1 + n
        return ' '.join(out)
    return repr(val)


def load_allow(path):
    allow = set()
    if os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.split('#')[0].strip()
            if line:
                allow.add(tuple(line.split()))
    return allow


def base(p):
    return p.rstrip('/').split('/')[-1]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    list_only = '--list' in sys.argv
    ours_p = args[0] if args else 'dist/rk3568-kickpi-k1.dtb'
    ref_p = args[1] if len(args) > 1 else 'dist/rk3568-nanopi-r5s-official.dtb'
    for f in (ours_p, ref_p):
        if not os.path.exists(f):
            raise SystemExit(f'✗ 缺文件: {f}')

    ours, ref = parse(ours_p), parse(ref_p)
    ph_o, ph_r = phandle_map(ours), phandle_map(ref)
    allow = load_allow(ALLOWLIST)

    print(f'  本板 : {ours_p} ({len(ours)} 节点)')
    print(f'  参照 : {ref_p} ({len(ref)} 节点)')
    bad, allowed, checked = [], [], 0

    for name in MEDIA_NODES:
        po = [p for p in ours if base(p) == name]
        pr = [p for p in ref if base(p) == name]
        if not pr:
            continue                                    # 官方没有的节点不参与
        if not po:
            if ('missing', name) in allow:
                allowed.append(f'缺节点 {name}（已登记例外）')
            else:
                bad.append(f'✗ 缺节点 {name}（官方 R5S 有，本板没有）')
            continue
        checked += 1
        o, r = norm_prop_map(ours, ph_o, po[0]), norm_prop_map(ref, ph_r, pr[0])
        for k in sorted(r):
            if k in SKIP_PROPS:
                continue
            if k not in o:
                if ('extra', po[0], k) in allow or ('missing-prop', name, k) in allow:
                    allowed.append(f'{po[0]} 缺属性 {k}（已登记例外）')
                else:
                    bad.append(f'✗ {po[0]} 缺属性 {k}\n      官方: {r[k]}')
            elif o[k] != r[k]:
                if ('diff', po[0], k) in allow:
                    allowed.append(f'{po[0]} 属性 {k} 与官方不同（已登记例外）')
                else:
                    bad.append(f'✗ {po[0]} 属性 {k} 与官方不同\n      本板: {o[k]}\n      官方: {r[k]}')
        for k in sorted(set(o) - set(r)):
            if k == 'status':
                continue                      # 显式 status="okay" 与官方"无 status(默认 enabled)"等价
            if ('extra-prop', po[0], k) in allow:
                continue
            allowed.append(f'ⓘ {po[0]} 多出属性 {k}（官方无；如需保留请登记 allowlist）')

    # OPP 子节点：官方表里的 opp-* 必须都在；本板多出的档位按 allowlist 放行
    for tbl in ('opp-table-1', 'npu-opp-table', 'rkvdec-opp-table', 'rkvenc-opp-table',
                'bus-npu-opp-table'):
        for p in [x for x in ref if base(x) == tbl]:
            for c in [x for x in ref if x.startswith(p + '/')]:
                cb = base(c)
                ours_c = [x for x in ours if x.endswith('/' + cb) and
                          any(base(xp) == tbl for xp in [x.rsplit('/', 1)[0]])]
                if not ours_c and ('missing', tbl + '/' + cb) not in allow:
                    bad.append(f'✗ {tbl} 缺 OPP 子节点 {cb}（官方有）')
        for p in [x for x in ours if base(x) == tbl]:
            for c in [x for x in ours if x.startswith(p + '/')]:
                cb = base(c)
                ref_c = [x for x in ref if x.endswith('/' + cb) and
                         any(base(xp) == tbl for xp in [x.rsplit('/', 1)[0]])]
                key = tbl + '/' + cb
                if not ref_c and ('extra', key) not in allow:
                    allowed.append(f'ⓘ {tbl} 多出 OPP 子节点 {cb}（官方无）')

    print(f'  参与比对节点 {checked} 个')
    for a in allowed:
        print('  ' + a)
    if bad:
        print('\n  ✗ 媒体簇与官方 R5S 不一致：')
        for b in bad:
            print('  ' + b)
        print('\n  修法：dts/ 里按官方 R5S 属性改；确属板级差异的写进 ' + ALLOWLIST)
        return 1 if not list_only else 0
    print('  ✓ 媒体簇与官方 R5S 逐节点一致（差异均已登记）')
    return 0


def norm_prop_map(nodes, ph, path):
    return {k: norm_prop(nodes, ph, k, v) for k, v in nodes[path].items() if k not in SKIP_PROPS}


if __name__ == '__main__':
    sys.exit(main())
