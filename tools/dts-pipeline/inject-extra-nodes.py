#!/usr/bin/env python3
"""把 /tmp/extra-nodes.json 里要求的节点，直接从实机 DT 注入到 k1-merged.dts 的根节点内。

为什么单独做：主循环里的 NEW_NODES.update(extra) 不生效（原因不明），
但 make_node() 本身经探针验证是好用的 → 这里直接复用它，不依赖主循环。
注入后再由 dtc 判定；dtc 干净才允许门禁与写卡。
"""
import importlib.util
import json
import pathlib
import re
import subprocess
import sys

WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
MERGED = WORK / 'k1-merged.dts'
LIVE = pathlib.Path('/tmp/live2.dts')
EXTRA = pathlib.Path('/tmp/extra-nodes.json')

spec = importlib.util.spec_from_file_location('m', '/work/scripts/merge-live-nodes.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

if not LIVE.exists():
    subprocess.run(['dtc', '-I', 'fs', '-O', 'dts', '-o', str(LIVE),
                    '/sys/firmware/devicetree/base'], check=True, capture_output=True)

live = LIVE.read_text(errors='ignore')
phmap = m.build_phmap(live)
extra = json.loads(EXTRA.read_text()) if EXTRA.exists() else {}
text = MERGED.read_text(errors='ignore')

added, skipped, failed = [], [], []
for name in list(extra):
    if re.search(r'\n\t' + re.escape(name) + r'\s*\{', text):
        skipped.append(name)
        continue
    warns = []
    blk = m.make_node(name, live, phmap, warns)
    if not blk:
        failed.append(name)
        continue
    rm = re.search(r'\n/ \{', text)
    if not rm:
        failed.append(name)
        continue
    i = text.index('{', rm.start())
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
    text = text[:j] + '\n' + blk + text[j:]
    added.append(name)
    if warns:
        print('    ⚠ %s 翻译告警: %s' % (name, warns[:3]))

MERGED.write_text(text)
print('  注入完成：新增 %s；已存在 %s；失败 %s' % (added or '无', skipped or '无', failed or '无'))

d = subprocess.run(['dtc', '-f', '-Wno-pci_device_reg', '-Wno-unit_address_vs_reg',
                    '-I', 'dts', '-O', 'dtb', '-o', str(WORK / 'rk3568-kickpi-k1.dtb'),
                    str(MERGED)], capture_output=True, text=True)
hard = [l for l in d.stderr.splitlines() if 'ERROR' in l and 'Warning' not in l]
if hard:
    print('  ✗ dtc 仍报错：')
    for x in hard[:6]:
        print('     ' + x)
    sys.exit(1)
print('  ✓✓ dtc 0 ERROR/FATAL')
sys.exit(0)
