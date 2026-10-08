#!/usr/bin/env python3
"""按【实机 DT】对齐 status：实机 okay、而我们 disabled/未写的节点，一律置为 okay。

为什么要做：我们的 DTS 基座来自 T68M，导致本板 K1 实际拥有的设备被误关 ——
实测 sata@fc000000 我们 disabled / 实机 okay（难怪 smartmontools 起不来、SATA 用不了），
另有 USB3、视频编解码、NPU、I2C、I2S、PWM、多个 UART、SPI、IOMMU 等共 50+ 处。

安全规则：
  · 只改【我们已存在】的节点状态；实机有而我们没有的节点只报告，不擅自新建。
  · 只做 disabled/未写 → okay；绝不把 okay 改成 disabled（如 serial@fe660000 是我们的控制台，实机恰好 disabled）。
  · 节点名不同时用 "@地址" 兜底匹配（实机 dwmmc@fe000000 ↔ 我们 mmc@fe000000）。
"""
import re
import pathlib
import sys

WORK = pathlib.Path('/work/kbuild/6.18.18-rockchip/work')
SRC = WORK / 'k1-final.dts'
LIVE = pathlib.Path('/tmp/live2.dts')


def parse(t):
    """返回 {key: (nodename, status)}；key = @地址 或 节点名"""
    out = {}
    stack = []
    for line in t.splitlines():
        ind = len(line) - len(line.lstrip('\t'))
        s = line.strip()
        m = re.match(r'^([\w\-\+,\@\.]+)\s*\{$', s)
        if m:
            while stack and stack[-1][0] >= ind:
                stack.pop()
            stack.append((ind, m.group(1), None))
            continue
        st = re.match(r'^status\s*=\s*"([^"]+)";$', s)
        if st and stack:
            for i in range(len(stack) - 1, -1, -1):
                if stack[i][2] is None:
                    stack[i] = (stack[i][0], stack[i][1], st.group(1))
                    break
            continue
        if s.startswith('}'):
            if stack:
                ind2, name, status = stack.pop()
                key = name.split('@')[-1] if '@' in name else name
                out[key] = (name, status)
    return out


def find_node(text, name):
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


def set_status(text, name, value):
    sp = find_node(text, name)
    if not sp:
        return text, False
    body = text[sp[0]:sp[1]]
    if re.search(r'\n\t\tstatus\s*=\s*"[^"]*";', body):
        body2 = re.sub(r'\n\t\tstatus\s*=\s*"[^"]*";',
                       '\n\t\tstatus = "%s";' % value, body, count=1)
    else:
        # 插到第一个子节点之前（属性必须先于子节点）
        lines = body.split('\n')
        depth = 0
        idx = len(lines)
        for k, line in enumerate(lines):
            s = line.strip()
            if depth == 0 and s.endswith('{'):
                idx = k
                break
            depth += line.count('{') - line.count('}')
        lines[idx:idx] = ['\t\tstatus = "%s";' % value]
        body2 = '\n'.join(lines)
    return text[:sp[0]] + body2 + text[sp[1]:], True


def main():
    if not LIVE.exists():
        print('  ✗ 缺实机 DT 反编译文本 %s' % LIVE); return 1
    live = LIVE.read_text(errors='ignore')
    text = SRC.read_text(errors='ignore')
    nv, no = parse(live), parse(text)

    enabled, missing, already = [], [], []
    for key, (name, st) in sorted(nv.items()):
        if st != 'okay':
            continue
        if key in no:
            myname, myst = no[key]
            if myst != 'okay':
                text, ok = set_status(text, myname, 'okay')
                if ok:
                    enabled.append('%s(%s→okay)' % (myname, myst or '未写'))
                else:
                    missing.append(name)
            else:
                already.append(myname)
        else:
            missing.append(name)

    SRC.write_text(text)
    print('  实机 okay 节点: %d' % sum(1 for v in nv.values() if v[1] == 'okay'))
    print('  ✓ 本次打开 %d 个：%s' % (len(enabled), ', '.join(enabled[:14]) + (' …' if len(enabled) > 14 else '')))
    print('  · 本来就 okay: %d 个' % len(already))
    if missing:
        print('  ⚠ 实机有而我们没有（未擅自新建，%d 个）：' % len(missing))
        for m in missing[:20]:
            print('      %s' % m)
    return 0


if __name__ == '__main__':
    sys.exit(main())
