#!/usr/bin/env python3
"""FIT 镜像哈希校验 / 重签（rockchip u-boot.itb，位于镜像 0x4000 扇区）。

背景：tools/patch-uboot-boot-targets.py 就地改写了 FIT 内 u-boot 负载的 13 字节
（boot_targets 顺序），但没有重算 sha256 → SPL 校验失败 → "SPL: failed to boot
from all boot devices"。本工具：

  --verify          只校验（默认），打印每个 image 节点 OK/MISMATCH，返回码 1 表示有问题
  --fix             把 MISMATCH 节点的 hash 值按实际负载重算并【就地写回】（等长替换，
                    FDT 尺寸不变、布局不动），写完自动复核

用法：
  python tools/fit-resign.py [--fix] <镜像文件> [fit_offset=8388608]
"""
import sys
import struct
import hashlib

FDT_MAGIC = 0xD00DFEED
DEFAULT_OFFSET = 0x4000 * 512  # u-boot.itb 在 rk 镜像里的固定扇区


class FDT:
    def __init__(self, data):
        self.data = data
        (magic, self.total, self.off_struct, self.off_strings, _rsv, _version,
         _lc, _cpuid, _size_strings, self.size_struct) = struct.unpack(">10I", data[:40])
        if magic != FDT_MAGIC:
            raise ValueError("不是 FDT/FIT：%08x" % magic)

    def walk(self):
        """返回 {路径: {属性名: (值bytes, 属性字节偏移)}}，偏移用于就地改写。"""
        pos = self.off_struct
        end = self.off_struct + self.size_struct
        root = {}
        cur = root
        stack = []
        while pos < end:
            tag = struct.unpack(">I", self.data[pos:pos + 4])[0]
            pos += 4
            if tag == 1:  # BEGIN_NODE
                name = self.data[pos:self.data.index(b"\x00", pos)].decode("utf-8", "replace")
                pos = (pos + len(name) + 4) & ~3
                node = {}
                cur[name if name else "/"] = node
                stack.append(cur)
                cur = node
            elif tag == 2:  # END_NODE
                cur = stack.pop()
            elif tag == 3:  # PROP
                length, nameoff = struct.unpack(">II", self.data[pos:pos + 8])
                pos += 8
                s = self.off_strings + nameoff
                pname = self.data[s:self.data.index(b"\x00", s)].decode()
                value_off = pos
                value = self.data[pos:pos + length]
                pos = (pos + length + 3) & ~3
                cur[pname] = (value, value_off)
            elif tag == 4:
                continue
            elif tag == 9:
                break
            else:
                raise ValueError("未知 FDT tag %d @%d" % (tag, pos))
        return root


def be32(b):
    return struct.unpack(">I", b[:4])[0]


def check(blob, verbose=True):
    """返回 [(node_name, ok, actual_hex, stored_hex, (hash_off, payload_off, size), props)]"""
    fdt = FDT(blob)
    root = fdt.walk()
    images_node = root["/"].get("images")
    if images_node is None:
        raise ValueError("FIT 里没有 images 节点")
    images = images_node  # 节点即 dict
    results = []
    for name, node in sorted(images.items()):
        if not isinstance(node, dict):
            continue
        hash_entry = next((node[k] for k in node if isinstance(node[k], dict)
                           and k.startswith("hash")), None)
        if hash_entry is None:
            continue
        value, hash_off = hash_entry["value"]
        algo = hash_entry["algo"][0].decode("utf-8", "replace").rstrip("\x00")
        if "data-offset" not in node or "data-size" not in node:
            continue
        data_off = be32(node["data-offset"][0]) + fdt.total
        data_size = be32(node["data-size"][0])
        payload = blob[data_off:data_off + data_size]
        if len(payload) != data_size:
            results.append((name, False, "TRUNCATED", value.hex(),
                            (hash_off, data_off, data_size), algo))
            continue
        h = hashlib.sha256(payload).digest() if algo.startswith("sha256") else b""
        ok = h == value
        results.append((name, ok, h.hex(), value.hex(),
                        (hash_off, data_off, data_size), algo))
    return results, fdt.total


def main():
    args = sys.argv[1:]
    fix = False
    if "--fix" in args:
        fix = True
        args.remove("--fix")
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    offset = int(args[1], 0) if len(args) > 1 else DEFAULT_OFFSET

    with open(path, "r+b" if fix else "rb") as f:
        f.seek(offset)
        blob = f.read(2 * 1024 * 1024)
        results, _total = check(blob)
        bad = 0
        for name, ok, actual, stored, (hash_off, poff, psz), algo in results:
            print("  %-8s %-9s payload@0x%x size=%d  %s"
                  % (name, "OK" if ok else "MISMATCH", poff, psz, "" if ok else
                     "stored=%s actual=%s" % (stored[:16], actual[:16])))
            if not ok:
                bad += 1
                if fix:
                    new = bytes.fromhex(actual)
                    if blob[hash_off:hash_off + len(new)] != bytes.fromhex(stored):
                        print("     !! FDT 里的 hash 字节与记录不一致，拒绝写入")
                        return 2
                    f.seek(offset + hash_off)
                    f.write(new)
                    print("     → 已重写 hash（FDT 内偏移 0x%x）" % hash_off)
        if bad and fix:
            f.flush()
            import os
            os.fsync(f.fileno())
            f.seek(offset)
            blob2 = f.read(2 * 1024 * 1024)
            results2, _ = check(blob2)
            still = [n for n, ok, *_ in results2 if not ok]
            print("复核：%s" % ("全部 OK" if not still else "仍有 MISMATCH: %s" % still))
            return 1 if still else 0
    print("总计 %d 个 image 节点，%d 个异常" % (len(results), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
