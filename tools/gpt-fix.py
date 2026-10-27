#!/usr/bin/env python3
"""tools/gpt-fix.py — UEFI GPT 校验/修复（R5S 官方镜像同款自洽口径）
用法: python3 tools/gpt-fix.py <镜像|块设备> [--apply]
不带 --apply = 纯诊断（有问题 exit 1，供 CI 断言）；--apply = 修复后自检。

依据官方 fnOS R5S 镜像实测口径 + Linux 内核 block/partitions/efi.c 校验链：
  保护MBR 55AA + 0xEE 项 count=末扇区
  主头 hsz=92, 头CRC@0x10（置零算前92B）, alt=末扇区, last_usable=末扇区-33,
  分区项@LBA2, 项CRC@0x58（对项数组全量实算）
  备份头@末扇区, 备份项@末扇区-32（与主项逐字节一致）, alt=1
刷进比镜像更大的盘后：烧录工具常改 alt/last_usable 却漏算头CRC → 内核严格校验
拒绝整表 → mmcblk 只认到卡无分区 → 内核卡死 Waiting for root device（U-Boot 宽容
能过，故表现为'U-Boot 正常但系统起不来'）。本脚本按规范重算全部字段。
只动 GPT 元数据（MBR+主头+备份项+备份头），分区内容零修改。
"""
import struct, zlib, sys, os

def crc32(b): return zlib.crc32(b) & 0xffffffff
def hdr_crc(h, hsz=92):
    h2 = bytearray(h[:hsz]); h2[16:20] = b"\0\0\0\0"
    return crc32(bytes(h2))

def dev_size(path):
    base = os.path.basename(path)
    sysf = f"/sys/class/block/{base}/size"
    if os.path.exists(sysf):
        return int(open(sysf).read().strip()) * 512
    return os.path.getsize(path)

def scan(f, last, off_mbr=0):
    """诊断：返回 (问题列表, 主头bytes, 项bytes)"""
    probs = []
    f.seek(off_mbr); mbr = bytearray(f.read(512))
    if mbr[510:512] != b"\x55\xaa": probs.append("保护MBR 缺55AA签名")
    p = mbr[446:462]
    if p[4] != 0xEE: probs.append(f"MBR 非保护项(type=0x{p[4]:02x})")
    cnt = struct.unpack_from("<I", p, 12)[0]
    if cnt != last: probs.append(f"MBR count={cnt}≠末扇区{last}")
    f.seek(off_mbr+512); prim = bytearray(f.read(512))
    if prim[:8] != b"EFI PART": return (["主头无EFI PART签名"], prim, b"")
    hsz = struct.unpack_from("<I", prim, 12)[0]
    hc  = struct.unpack_from("<I", prim, 16)[0]
    if hsz != 92: probs.append(f"主头hsz={hsz}≠92")
    if hdr_crc(prim, hsz) != hc: probs.append(f"主头CRC坏(声明0x{hc:08x} 实算0x{hdr_crc(prim,hsz):08x})")
    alt = struct.unpack_from("<Q", prim, 32)[0]
    lus = struct.unpack_from("<Q", prim, 48)[0]
    if alt != last: probs.append(f"主头alt={alt}≠末扇区{last}")
    if lus != last-33: probs.append(f"last_usable={lus}≠{last-33}")
    ent_lba, num, esz = struct.unpack_from("<QII", prim, 72)
    ecrc = struct.unpack_from("<I", prim, 88)[0]
    f.seek(off_mbr + ent_lba*512); entries = f.read(num*esz)
    real = crc32(entries)
    if real != ecrc: probs.append(f"分区项CRC坏(声明0x{ecrc:08x} 实算0x{real:08x})")
    # 备份侧
    f.seek(off_mbr + last*512); bak = f.read(512)
    if bak[:8] != b"EFI PART":
        probs.append("备份头@末扇区 无签名")
    else:
        bsz = struct.unpack_from("<I", bak, 12)[0]
        bhc = struct.unpack_from("<I", bak, 16)[0]
        if bsz != 92 or hdr_crc(bak, bsz) != bhc: probs.append("备份头CRC坏")
        bent, bnum, besz = struct.unpack_from("<QII", bak, 72)
        f.seek(off_mbr + bent*512); bents = f.read(bnum*besz)
        if crc32(bents) != struct.unpack_from("<I", bak, 88)[0]: probs.append("备份项CRC坏")
        elif bents != entries: probs.append("备份项与主项不一致")
    return (probs, prim, entries)

def repair(f, last, mbr, prim, entries, off_mbr=0):
    num = len(entries)//128
    b_lba = last - 32
    # MBR
    struct.pack_into("<I", mbr, 446+12, last)
    mbr[446+4] = 0xEE; mbr[510:512] = b"\x55\xaa"
    f.seek(off_mbr); f.write(mbr)
    # 主头
    struct.pack_into("<Q", prim, 32, last)             # alt
    struct.pack_into("<Q", prim, 48, last-33)          # last_usable
    struct.pack_into("<Q", prim, 72, 2)                # 项@LBA2（主分区区，除偏移块设备恒2）
    struct.pack_into("<I", prim, 12, 92)
    struct.pack_into("<I", prim, 88, crc32(entries))   # 项CRC以内容为准
    struct.pack_into("<I", prim, 16, hdr_crc(prim))    # 头CRC@0x10 最后算
    # 主项（--renew-partuuid 会改内容，必须回写；否则声明 CRC 与磁盘不符）
    f.seek(off_mbr + 2*512); f.write(entries)
    # 备份项
    f.seek(off_mbr + b_lba*512); f.write(entries)
    # 备份头
    nb = bytearray(prim)
    struct.pack_into("<Q", nb, 24, last)               # cur=末扇区
    struct.pack_into("<Q", nb, 32, 1)                  # alt=主头
    struct.pack_into("<Q", nb, 72, b_lba)
    struct.pack_into("<I", nb, 16, hdr_crc(nb))
    f.seek(off_mbr + last*512); f.write(nb)
    # 主头最后
    f.seek(off_mbr+512); f.write(prim)
    f.flush(); os.fsync(f.fileno())

def renew_partuuid(entries, idx):
    """把第 idx 个分区项（1-based）的 unique GUID 换成新的随机值。
    用途：镜像与板上已有系统同源时 PARTUUID 会撞车（内核先挂到 eMMC 那个），
    而 fnOS 的 boot.cmd 是 `part uuid` 现场取值，所以换 GUID 不需要改任何引导文件。"""
    import uuid
    off = (idx - 1) * 128
    if off + 128 > len(entries):
        raise SystemExit(f"分区号 {idx} 超出项数组（共 {len(entries)//128} 项）")
    if entries[off:off + 16] == b"\x00" * 16:
        raise SystemExit(f"分区 {idx} 不存在（类型 GUID 全零）")
    old = uuid.UUID(bytes_le=bytes(entries[off + 16:off + 32]))
    new = uuid.uuid4()
    entries[off + 16:off + 32] = new.bytes_le
    print(f"  · 分区 {idx} PARTUUID: {old} -> {new}")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print(__doc__)
        return 2
    path = args[0]
    do_apply = "--apply" in sys.argv
    renew = None
    for a in sys.argv[1:]:
        if a.startswith("--renew-partuuid="):
            renew = int(a.split("=", 1)[1])
    last = dev_size(path) // 512 - 1
    mode = "APPLY" if do_apply else "诊断"
    print(f"[gpt-fix] {path} 末扇区={last} 模式={mode}"
          + (f" 换分区{renew}的PARTUUID" if renew else ""))
    with open(path, "r+b" if do_apply else "rb") as f:
        probs, prim, entries = scan(f, last)
        need = bool(probs) or bool(renew)
        if probs:
            for p in probs:
                print("  ✗", p)
        elif not renew:
            print("  ✓ GPT 全字段自洽（主/备/MBR）")
        if not need:
            return 0
        if not entries:
            print("  ❌ 主项读取失败，放弃修复")
            return 1
        if not do_apply:
            if renew:
                print(f"  [dry-run] 将把分区 {renew} 的 PARTUUID 换成新随机值（其余字段一并按规范重算）")
            else:
                print("  [dry-run] 用 --apply 修复（只动 GPT 元数据，分区内容零修改）")
            return 1
        ents = bytearray(entries)
        if renew:
            renew_partuuid(ents, renew)
        repair(f, last, _mbr(f), prim, bytes(ents))
    # 修复后复检
    with open(path, "rb") as f:
        probs2, _, _ = scan(f, last)
    if probs2:
        for p in probs2:
            print("  ✗ 复检:", p)
        return 1
    if need:
        print("  ✓ 修复后复检通过")
    return 0

def _mbr(f):
    f.seek(0); return bytearray(f.read(512))

if __name__ == "__main__":
    sys.exit(main())
