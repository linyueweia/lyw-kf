#!/usr/bin/env python3
"""禁掉与网口抢引脚的设备（它们在我们树里带的是 T68M 的引脚组，会抢走 GMAC 的 RGMII 引脚）。

依据（实机日志，2026-10-29 收集）：
  pin gpio4-6  already requested by fe640000.spi      → gmac1 gmac1m1-tx-bus2 失败
  pin gpio2-5  already requested by fe6b0000.serial   → gmac0 gmac0-rgmii-clk 失败
  pin gpio1-1  already requested by fe670000.serial   → i2c3m0 失败
  pin gpio4-11 already requested by fe640000.spi      → i2c4m0 失败
  pin gpio1-4  already requested by fe680000.serial   → i2s1m0 失败
结论：本板不用这几个 UART/SPI，禁掉它们才能让网口的引脚复用成功。
"""
import re, pathlib, sys
DTS = pathlib.Path('/work/kbuild/6.18.18-rockchip/work/k1-final.dts')
BAD = ('spi@fe640000', 'serial@fe670000', 'serial@fe6b0000', 'serial@fe680000')
t = DTS.read_text(errors='ignore')
n = 0
for name in BAD:
    m = re.search(r'\n(\t)' + re.escape(name) + r' \{', t)
    if not m:
        print('    · %s 不存在（跳过）' % name); continue
    i = m.end() - 1; d = 0; j = i
    while j < len(t):
        if t[j] == '{': d += 1
        elif t[j] == '}':
            d -= 1
            if d == 0: break
        j += 1
    body = t[i+1:j]
    if re.search(r'\n\t\tstatus\s*=\s*"[^"]*";', body):
        body2 = re.sub(r'\n\t\tstatus\s*=\s*"[^"]*";', '\n\t\tstatus = "disabled";', body, count=1)
    else:
        lines = body.split('\n'); depth = 0; idx = len(lines)
        for k, line in enumerate(lines):
            s = line.strip()
            if depth == 0 and s.endswith('{'):
                idx = k; break
            depth += line.count('{') - line.count('}')
        lines[idx:idx] = ['\t\tstatus = "disabled";']
        body2 = '\n'.join(lines)
    t = t[:i+1] + body2 + t[j:]
    n += 1
    print('    ✓ %s → disabled' % name)
DTS.write_text(t)
print('  共禁用 %d 个（释放网口/其它设备的引脚）' % n)
