#!/usr/bin/env python3
"""
把 fnOS 基镜像自带 U-Boot 的内置默认 env 里 boot_targets 改成 mmc 优先。

背景（2026-10-12 排查结论）：
  KICKPI K1 的 fnOS 镜像沿用 armbian 的 U-Boot（2026.04-TRIM-c218，内嵌
  fdtfile=rk3568-nanopi-r5s.dtb），其内置默认 env 把 USB 排在扫描第一位：
      bootcmd=bootflow scan -lb
      boot_targets=usb mmc1 mmc0 nvme scsi pxe dhcp spi
  bootflow scan 扫到第一个有效 bootflow 就立刻启动，于是"开机前插着 USB 硬盘"
  时会先去枚举 USB，在轮到 SD(mmc1) 之前卡住/被抢走 → 表现即"机器起不来"。
  对照本板 eMMC 的厂商 U-Boot 是 mmc1 mmc0 ... usb0（usb 在最后），可见
  "USB 优先"是 armbian 补丁引入的，不是本板固有。

改法：就地把 boot_targets 的值改成 mmc 优先（等长替换）。
  old = "usb mmc1 mmc0 nvme scsi pxe dhcp spi"   (36 字节)
  new = "mmc1 mmc0 usb nvme scsi pxe dhcp spi"   (36 字节)
  两串等长 → env 总长不变、NUL 终止位不动、无需重算 CRC。

内存安全：全程分块扫描，单次只驻留 CHUNK+ 重叠，不整盘读入
          （这台机器只有 ~3G 内存，整盘 read() 会被 OOM kill）。

安全设计：
  · 全盘扫描统计命中数，必须**恰好 1 处**，否则中止
  · 命中处逐字节断言旧串 + 后随 NUL
  · 写完读回断言：旧串 0 处、新串 1 处、文件大小不变
  · --dry-run 只检查不写

用法：
  python3 tools/patch-uboot-boot-targets.py <device-or-image> [--dry-run]
"""

import argparse
import os
import sys

OLD = b"usb mmc1 mmc0 nvme scsi pxe dhcp spi"
NEW = b"mmc1 mmc0 usb nvme scsi pxe dhcp spi"
KEY = b"boot_targets="
NEEDLE = KEY + OLD
NEEDLE_NEW = KEY + NEW

CHUNK = 4 * 1024 * 1024
OVERLAP = 256

assert len(OLD) == len(NEW) == 36, "新旧串必须等长"


UBOOT_ZONE = 32 * 1024 * 1024  # 只认前 32MiB 的 U-Boot 区


def scan(fh, needle: bytes, end: int = UBOOT_ZONE):
    """分块扫描 U-Boot 区 [0, end)，返回所有命中偏移。

    只扫前 32MiU：v1.1.0 起基镜像删过 boot 分区的 u-boot-rockchip-spi.bin，
    unlink 后字节仍留在盘上（实测 0x4cecd45 命中旧串），全盘扫会把残留
    当成第二处命中、触发"恰好 1 处"断言误炸。
    """
    hits = []
    fh.seek(0, os.SEEK_END)
    total = min(fh.tell(), end)
    pos = 0
    tail = b""
    while pos < total:
        fh.seek(pos)
        buf = fh.read(CHUNK)
        if not buf:
            break
        blob = tail + buf
        base = pos - len(tail)
        start = 0
        while True:
            i = blob.find(needle, start)
            if i < 0:
                break
            hits.append(base + i)
            start = i + 1
        tail = blob[-OVERLAP:] if len(blob) >= OVERLAP else blob
        pos += len(buf)
    # 去重（重叠区可能重复命中）
    return sorted(set(hits))


def dev_size(path: str) -> int:
    """块设备用 ioctl BLKGETSIZE64；普通文件用 getsize。"""
    st = os.stat(path)
    import stat as _stat
    if _stat.S_ISBLK(st.st_mode):
        import fcntl
        import struct
        BLKGETSIZE64 = 0x80081272
        with open(path, "rb") as f:
            buf = fcntl.ioctl(f.fileno(), BLKGETSIZE64, struct.pack("Q", 0))
        return struct.unpack("Q", buf)[0]
    return st.st_size


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("target")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    path = args.target
    if not os.path.exists(path) or os.path.isdir(path):
        print(f"  ❌ 目标无效: {path}")
        return 1

    size = dev_size(path)
    print(f"  目标: {path}  大小 {size} 字节 ({size/1024/1024/1024:.1f} GiB)")

    with open(path, "rb") as f:
        hits = scan(f, NEEDLE)
    print(f"  扫描 'boot_targets=' + 旧串 → 命中 {len(hits)} 处"
          + (f"  {[hex(h) for h in hits]}" if hits else ""))

    if not hits:
        with open(path, "rb") as f:
            if scan(f, NEEDLE_NEW):
                print("  ✅ 已是新值（mmc 优先），无需改动")
                return 0
            # 现役引导件（lyw-ki 仓构建的 U-Boot 2025.10）内置就是 mmc 优先，
            # 但它的 boot_targets 串更长、与本工具的 NEW 常量不同 —— 不能因此判 ❌。
            # 这里只做"是否 mmc 优先"的粗判，硬判据在六环验证（断言 boot_targets=mmc1 mmc0）。
            if scan(f, b"boot_targets=mmc"):
                print("  ⓘ 该 U-Boot 的 boot_targets 已是 mmc 优先（非本工具的目标串）→ 不改写；"
                      "由六环验证断言 boot_targets=mmc1 mmc0 兜底")
                return 0
        print("  ⓘ 未找到任何 boot_targets 串（前导区可能为空/非本工具预期的 U-Boot）—— 不改写；"
              "由六环验证断言兜底")
        return 0
    if len(hits) > 1:
        print(f"  ❌ 命中 {len(hits)} 处（要求恰好 1 处）—— 为安全中止")
        return 1

    at = hits[0]
    val_at = at + len(KEY)
    if val_at + len(OLD) >= size:
        print("  ❌ 命中位置越界")
        return 1

    with open(path, "rb") as f:
        f.seek(val_at)
        cur = f.read(len(OLD) + 1)
    if cur[:len(OLD)] != OLD:
        print(f"  ❌ 值处字节不符: {cur[:len(OLD)]!r}")
        return 1
    if cur[len(OLD)] != 0:
        print(f"  ❌ 旧串后不是 NUL（{cur[len(OLD)]:#x}）—— 布局不符，中止")
        return 1
    print(f"  ✅ 断言通过: {hex(at)} 处 boot_targets = {OLD.decode()}  （后随 NUL）")

    if args.dry_run:
        print(f"  [dry-run] 将改为: {NEW.decode()}")
        return 0

    with open(path, "r+b") as f:
        f.seek(val_at)
        f.write(NEW)
        f.flush()
        os.fsync(f.fileno())
    print("  已写入")

    # 读回复核
    if dev_size(path) != size:
        print(f"  ❌ 大小变了: {size} → {dev_size(path)}")
        return 1
    with open(path, "rb") as f:
        n_old = len(scan(f, NEEDLE))
    with open(path, "rb") as f:
        n_new = len(scan(f, NEEDLE_NEW))
    print(f"  读回复核: 旧串 {n_old} 处(应0)  新串 {n_new} 处(应1)  大小 {dev_size(path)}")
    if n_old != 0 or n_new != 1:
        print("  ❌ 复核失败")
        return 1
    print(f"  ✅ 完成: boot_targets = {NEW.decode()}")
    print("     冷启动判据: U-Boot 的 Scanning bootdev 'mmc1' 应早于 'usb'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
