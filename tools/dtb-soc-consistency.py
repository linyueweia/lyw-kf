#!/usr/bin/env python3
"""
SoC 一致性门禁：把"我们的板级 DTB"与"飞牛内核树自己编的参考板 DTB"做节点级对照。

判据（只比 SoC，不管板级）：
  · 只在两边都存在的节点上比对；
  · 只比对第一个 compatible 字符串（第二个往往是 fallback，比对会误报：
    本板 dump 里是 "rockchip,rk3568-iommu\\0rockchip,iommu-v2"，
    飞牛树里只有 "rockchip,rk3568-iommu" —— 这种首串相同即视为一致）；
  · 板级独有节点（Maxio PHY / LED / regulator / wifi sdio 等）只在我们的 DTB 里，
    自然不参与比对。

命中不一致 = 板级 DTS 是从别的树反编译来的旧 dump，交付出去就是"DTB 与内核不配套"。

允许例外：dts/soc-compat-allowlist.txt，每行 `<节点路径> <compatible>`（# 注释），
用于确实需要保留差异的情况（例如厂商私有节点名）。命中例外的条目只告警不失败。

用法：python3 tools/dtb-soc-consistency.py <我们的.dtb> <参考板.dtb>
"""
import struct
import sys
import os


def parse(path: str):
    """返回 {节点路径: {"compat": str, "props": set()}}"""
    b = open(path, 'rb').read()
    _, _, off_struct, off_strings, _, _, _, _, size_struct, _ = struct.unpack('>10I', b[:40])
    sb = b[off_strings:off_strings + struct.unpack('>I', b[32:36])[0]]

    def name(o):
        e = sb.index(b'\x00', o)
        return sb[o:e].decode('utf-8', 'replace')

    nodes = {}
    pos = off_struct
    stack = []
    while pos + 4 <= len(b):
        tok = struct.unpack('>I', b[pos:pos + 4])[0]
        pos += 4
        if tok == 1:                      # BEGIN_NODE
            e = b.index(b'\x00', pos)
            nm = b[pos:e].decode('utf-8', 'replace')
            pos = (e + 1 + 3) & ~3
            stack.append(nm)
            path_ = '/' + '/'.join(x for x in stack if x)
            nodes.setdefault(path_, {'compat': None, 'props': set()})
        elif tok == 2:                    # END_NODE
            if stack:
                stack.pop()
        elif tok == 3:                    # PROP
            ln, no = struct.unpack('>II', b[pos:pos + 8])
            pos += 8
            val = b[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
            path_ = '/' + '/'.join(x for x in stack if x)
            nd = nodes.setdefault(path_, {'compat': None, 'props': set()})
            pn = name(no)
            nd['props'].add(pn)
            if pn == 'compatible':
                first = val.split(b'\x00')[0].decode('utf-8', 'replace')
                nd['compat'] = first
        elif tok == 4:                    # NOP
            continue
        elif tok == 9:                    # END
            break
        else:
            break
    return nodes


def load_allow(path):
    al = set()
    if path and os.path.exists(path):
        for line in open(path, encoding='utf-8'):
            line = line.split('#')[0].strip()
            if line:
                parts = line.split()
                if len(parts) == 2:
                    al.add((parts[0], parts[1]))
    return al


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ours_p, ref_p = sys.argv[1], sys.argv[2]
    allow = load_allow('dts/soc-compat-allowlist.txt')
    ours, ref = parse(ours_p), parse(ref_p)

    common = sorted(set(ours) & set(ref))
    only_ours = len(set(ours) - set(ref))
    mismatch, allowed_hits = [], []
    for p in common:
        if p == '/':                      # 根节点就是板名（kickpi,k1 vs 参考板），不参与 SoC 比对
            continue
        a, b = ours[p]['compat'], ref[p]['compat']
        if a is None and b is None:
            continue
        if a != b:
            if (p, a or '') in allow:
                allowed_hits.append((p, a, b))
            else:
                mismatch.append((p, a, b))

    print(f"  参照: {os.path.basename(ref_p)}")
    print(f"  共有节点 {len(common)}  本板独有 {only_ours}  首串不一致 {len(mismatch)}")
    for p, a, b in allowed_hits:
        print(f"  ~ 例外放行 {p}: 我们={a} 树={b}")
    if mismatch:
        print("  ✗ 以下节点的 compatible 首串与飞牛树不一致（说明板级 DTS 是过期 dump）：")
        for p, a, b in mismatch[:40]:
            print(f"     {p}\n        我们: {a}\n        树  : {b}")
        if len(mismatch) > 40:
            print(f"     … 共 {len(mismatch)} 处")
        print("  修法：把该节点在 dts/ 里改成树里的 compatible，或按树重新反编译板级 DTS。")
        return 1
    print("  ok SoC 级绑定与飞牛树一致（共有节点无一例首串不一致）")
    return 0


if __name__ == '__main__':
    sys.exit(main())
