#!/usr/bin/env python3
"""v2：把实机 DT 的板级属性并入我们的 K1 DTS —— 结构化插入位置版。

与 v1 的区别（v1 失败点）：
  1) 属性必须插到该节点【第一个子节点之前】—— 否则 dtc 报
     "Properties must precede subnodes"（v1 是简单 prepend/append，且替换会保留坏位置）
  2) 只取该节点的【顶层】属性 —— v1 的正则把子节点里的属性也拍平进了父节点
  3) 新建节点时显式给 compatible（v1 跳过了 compatible，导致新建节点不合法）
  4) 多字符串 "a\0b" → "a", "b"（dtc 语法）
  5) 数字 phandle → <&{/full/path}>（用实机 DT 自己的 phandle→路径表）
不再使用任何"整树规范化器"（那只把文本改坏）。
"""
import re, sys, subprocess, pathlib

LIVE_FS = '/sys/firmware/devicetree/base'
WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
BASE_DTS = WORK / 'k1.dts'
OUT_DTS  = WORK / 'k1-merged.dts'

# 实机名 → 我们的名字
ALIAS = {
    'rk_rga@fdeb0000': 'rga@fdeb0000',
    'dwmmc@fe000000': 'mmc@fe000000', 'dwmmc@fe2b0000': 'mmc@fe2b0000',
    'dwmmc@fe2c0000': 'mmc@fe2c0000', 'sdhci@fe310000': 'mmc@fe310000',
}
TARGETS = [
    'rk_rga@fdeb0000',
    'dwmmc@fe000000', 'pcie@fe260000', 'pcie@fe280000',
    'pcie30-avdd0v9', 'pcie30-avdd1v8',
    'vop@fe040000', 'hdmi@fe0a0000', 'hdmi-sound',
    'gpu@fde60000', 'leds', 'dwmmc@fe2b0000', 'sdhci@fe310000',
]
NEW_NODES = {'pcie3-regulator': 'regulator-fixed',
             'minipcie-regulator': 'regulator-fixed',
             'gpio-regulator': 'regulator-fixed'}   # 需要新建的节点 → 显式 compatible

PH_FIRST = ('phy-handle','phy-supply','vpcie3v3-supply','vcc-supply','vmmc-supply','vqmmc-supply',
            'vccio-supply','interrupt-parent','power-domains','iommus','nvmem-cells',
            'rockchip,grf','resets','io-channels','gpio','rockchip,vo-grf')
PH_EVEN  = ('clocks','assigned-clocks','assigned-clock-parents','dmas','phys')

def decompile_live():
    subprocess.run(['dtc','-I','fs','-O','dts','-o','/tmp/live2.dts',LIVE_FS],
                   check=True, capture_output=True)
    return pathlib.Path('/tmp/live2.dts').read_text(errors='ignore')

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
            if stack: stack.pop()
            continue
        ph = re.match(r'^phandle\s*=\s*<(0x[0-9a-fA-F]+|\d+)>;$', s)
        if ph and stack:
            v = int(ph.group(1),16) if ph.group(1).startswith('0x') else int(ph.group(1))
            m[v] = stack[-1][2]
    return m

def find_node(text, name):
    """返回 (body_start, body_end) —— 节点体内文本的起止偏移"""
    m = re.search(r'\n(\t*)%s\s*\{' % re.escape(name), text)
    if not m: return None
    i = m.end() - 1                      # 指向 '{'
    d = 0; j = i
    while j < len(text):
        if text[j] == '{': d += 1
        elif text[j] == '}':
            d -= 1
            if d == 0: break
        j += 1
    return (i+1, j)                       # 不含最外层 { }

def top_props(body):
    """只取 depth==0 的属性行 -> [(name, line_without_newline)]"""
    out, depth = [], 0
    for line in body.split('\n'):
        s = line.strip()
        if depth == 0 and s and not s.startswith('/*') and not s.startswith('*') \
           and not s.endswith('{') and '=' in s and s.endswith(';'):
            pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=', s)
            if pm: out.append((pm.group(1), s))
        depth += line.count('{') - line.count('}')
    return out

def insert_index(body):
    """属性区插入点（行号）：第一个顶层子节点所在行之前"""
    depth = 0
    for idx, line in enumerate(body.split('\n')):
        s = line.strip()
        if depth == 0 and s.endswith('{'):
            return idx
        depth += line.count('{') - line.count('}')
    return len(body.split('\n'))

def translate(prop, val, phmap, warns):
    nums = list(re.finditer(r'(0x[0-9a-fA-F]+|\d+)', val))
    if not nums: return val
    if prop in PH_EVEN: mode = 'even'
    elif prop in PH_FIRST or prop.endswith('-supply') or prop.endswith('-gpios') or prop.startswith('pinctrl-'):
        mode = 'first'
    else:
        return val
    out, off = val, 0
    for idx, m in enumerate(nums):
        if mode == 'even' and idx % 2 == 1: continue
        if mode == 'first' and idx != 0: continue
        v = int(m.group(1),16) if m.group(1).startswith('0x') else int(m.group(1))
        if v in phmap:
            tgt = phmap[v]
            # FIXPATH: 我们 DTS 里 gpio 控制器名不带 bank 数字（实机是 gpio3@fe760000，我们是 gpio@fe760000）
            tgt = re.sub(r'^(/pinctrl/)gpio[0-9](@[0-9a-f]+)$', r'\1gpio\2', tgt)
            rep = '&{%s}' % tgt
            a, b = m.start()+off, m.end()+off
            out = out[:a] + rep + out[b:]; off += len(rep) - len(m.group(1))
        else:
            warns.append('%s: 0x%x 未在 phandle 表' % (prop, v))
    return out

def merge_node(text, name, live_text, phmap, warns, live_name=None):
    span = find_node(text, name)
    if not span: return text, 0
    lbs = find_node(live_text, live_name or name)
    if not lbs: return text, 0
    live_body = live_text[lbs[0]:lbs[1]]
    newprops = []
    for pname, pline in top_props(live_body):
        if pname in ('phandle','linux,phandle','name','compatible'): continue   # status 要合并（实机是能跑的系统）
        if pname.startswith('pinctrl-') and '/pinctrl/' in pline and 'pcie3' in pline: continue
        pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=\s*(.*);$', pline)
        if not pm: continue
        val = pm.group(2).strip()
        if '\\0' in val: val = val.replace('\\0', '", "')
        newprops.append((pname, '= ' + translate(pname, val, phmap, warns)))
    if not newprops: return text, 0
    body = text[span[0]:span[1]]
    lines = body.split('\n')
    # 删除同名旧属性行（无论位置）并记录顺序
    # DROPFILTER：丢弃被拉黑的属性；丢弃引用我们 DTS 里不存在的 /pinctrl/ 组的属性
    _drop = drop_list().get(name, [])
    _val = None
    _keep = []
    for _p, _v in newprops:
        if _p in _drop:
            print('      · 丢弃属性 %s.%s（被拉黑）' % (name, _p)); continue
        mm2 = re.search(r'&\{(/[^}]+)\}', _v)
        if mm2 and mm2.group(1).startswith('/pinctrl/') and mm2.group(1) not in our_paths(text):
            print('      · 丢弃属性 %s.%s（引用不存在的引脚组 %s）' % (name, _p, mm2.group(1))); continue
        _keep.append((_p, _v))
    newprops = _keep
    names = {p for p,_ in newprops}
    kept, removed = [], 0
    for line in lines:
        s = line.strip()
        pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=', s)
        if pm and pm.group(1) in names:
            removed += 1; continue
        kept.append(line)
    body2 = '\n'.join(kept)
    idx = insert_index(body2)
    lines2 = body2.split('\n')
    indent = '\t\t'
    for m2 in re.finditer(r'\n(\t+)[A-Za-z0-9,\-\#\+_\.]+\s*=', body2):
        indent = m2.group(1); break
    ins = ['%s%s %s;' % (indent, p, v) for p, v in newprops]
    lines2[idx:idx] = ins
    newbody = '\n'.join(lines2)
    return text[:span[0]] + newbody + text[span[1]:], len(newprops)

def make_node(name, live_text, phmap, warns):
    span = find_node(live_text, name)
    if not span: return None
    body = live_text[span[0]:span[1]]
    props = []
    for pname, pline in top_props(body):
        if pname in ('phandle','linux,phandle','name','compatible'): continue
        if pname.startswith('pinctrl-'): continue   # 引脚组：需要父链，直接丢
        if pname in drop_list().get(name, []): continue   # DROPNEW
        pm = re.match(r'^([A-Za-z0-9,\-\#\+_\.]+)\s*=\s*(.*);$', pline)
        if not pm: continue
        val = pm.group(2).strip()
        if '\\0' in val: val = val.replace('\\0', '", "')
        props.append((pname, translate(pname, val, phmap, warns)))
    _dropn = drop_list().get(name, [])
    comp = None
    lc = re.search(r'compatible\s*=\s*"([^"]+)"', body)
    if lc:
        comp = lc.group(1).replace('\\0', '", "')
    if not comp:
        comp = NEW_NODES.get(name, 'simple-bus')
    out = ['\t%s {' % name, '\t\tcompatible = "%s";' % comp]
    for p, v in props: out.append('\t\t%s = %s;' % (p, v))
    out.append('\t};')
    return '\n'.join(out)

def drop_list():
    try:
        return json.loads(pathlib.Path('/tmp/drop-props.json').read_text())
    except Exception:
        return {}

def our_paths(text):
    """我们 DTS 里现存节点的全路径集合（粗略但够用）"""
    out, stack = set(), []
    for line in text.splitlines():
        s2 = line.strip()
        m = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s2)
        if m:
            stack.append(m.group(1)); out.add('/' + '/'.join(stack)); continue
        if s2.startswith('}'):
            if stack: stack.pop()
    return out

def main():
    live = decompile_live()
    phmap = build_phmap(live)
    print('  实机 phandle 表: %d 项' % len(phmap))
    text = BASE_DTS.read_text(errors='ignore')
    warns, done = [], []
    for t in TARGETS:
        ours = ALIAS.get(t, t)
        text, n = merge_node(text, ours, live, phmap, warns, live_name=t)
        if n: done.append('%s(%d)' % (ours, n)); print('    ✓ %-20s 并入 %d 属性' % (ours, n))
        else: print('    · %-20s 无可用属性/未找到' % ours)
    try:
        extra = json.load(open('/tmp/extra-nodes.json'))
    except Exception:
        extra = {}
    NEW_NODES.update(extra)
    for name in list(NEW_NODES):
        blk = make_node(name, live, phmap, warns)
        if blk:
            rm = re.search(r'\n/ \{', text)
            i = text.index('{', rm.start()); d = 0; j = i
            while j < len(text):
                if text[j] == '{': d += 1
                elif text[j] == '}':
                    d -= 1
                    if d == 0: break
                j += 1
            text = text[:j] + '\n' + blk + text[j:]
            done.append(name); print('    + %-20s 新建节点' % name)
    OUT_DTS.write_text(text)
    print('  写出 %s（%d 行）；处理 %d 个节点' % (OUT_DTS, len(text.splitlines()), len(done)))
    if warns:
        print('  ⚠ 翻译告警 %d 条（前 5）: %s' % (len(warns), warns[:5]))

if __name__ == '__main__':
    main()
