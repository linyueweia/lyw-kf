#!/usr/bin/env python3
"""离线读取一块【btrfs】分区（Windows 上不需要装任何驱动，必须管理员权限）。

用法：
  python btrfs_dump.py list   \\\\.\\PhysicalDrive2 <分区号> [路径] [深度]
  python btrfs_dump.py extract \\\\.\\PhysicalDrive2 <分区号> <目标目录> <路径>...

例（本板 TF 卡 rootfs，GPT 第 2 分区）：
  python btrfs_dump.py list    \\\\.\\PhysicalDrive2 2 / 2
  python btrfs_dump.py extract \\\\.\\PhysicalDrive2 2 D:\\dump /var/log /etc

依赖：pip install dissect.btrfs
配套：diskio.RawDisk（Windows 原始磁盘读必须 512 字节对齐）、ext4extract.gpt_partitions
"""
import sys, os, io, time, traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from diskio import RawDisk
from ext4extract import gpt_partitions

MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 600 * 1024 * 1024


class Window:
    """把 RawDisk 裁成一个分区窗口，暴露 seek/read/tell（dissect 需要的 file-like）。"""

    def __init__(self, base, start, size):
        self.base, self.start, self.size, self.pos = base, start, size, 0

    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (self.pos + off if whence == 1 else self.size + off)
        return self.pos

    def tell(self):
        return self.pos

    def read(self, n=-1):
        if n is None or n < 0:
            n = self.size - self.pos
        n = max(0, min(n, self.size - self.pos))
        if n == 0:
            return b""
        self.base.seek(self.start + self.pos)
        d = self.base.read(n)
        self.pos += len(d)
        return d

    def peek(self, n):
        p = self.pos
        d = self.read(n)
        self.pos = p
        return d

    def readable(self):
        return True


def open_fs(dev, part_index):
    from dissect.btrfs import Btrfs
    disk = RawDisk(dev)
    parts = gpt_partitions(disk)
    print("GPT:", parts)
    off = [p[1] for p in parts if p[0] == part_index][0]
    size = [p[2] for p in parts if p[0] == part_index][0]
    fs = Btrfs(Window(disk, off, size))
    print("btrfs label=%r uuid=%s" % (fs.label, fs.uuid))
    return fs


def cmd_list(fs, path, depth):
    lines = []

    def walk(p, d):
        node = fs.get(p)
        if not hasattr(node, "is_dir"):
            node = node.root if hasattr(node, "root") else node
        if not node.is_dir():
            return
        for name, child in sorted(node.iterdir(), key=lambda kv: kv[0]):
            if name in (".", "..") or not name:
                continue
            cp = p.rstrip("/") + "/" + name
            kind = "DIR " if child.is_dir() else ("LNK " if child.is_symlink() else "FILE")
            size = 0 if child.is_dir() else child.size
            mtime = str(getattr(child, "mtime", "") or "")
            lines.append("%s %-72s %s %s" % (kind, cp, size, mtime))
            if child.is_dir() and d + 1 < depth:
                walk(cp, d + 1)

    walk(path, 1)
    for ln in lines:
        print(ln)
    print("共 %d 项" % len(lines))


def cmd_extract(fs, dest, paths):
    os.makedirs(dest, exist_ok=True)
    stats = {"n": 0, "b": 0, "err": 0}

    def one(node, p):
        if not hasattr(node, "is_dir") and hasattr(node, "root"):
            node = node.root
        if node.is_symlink():
            print("  LNK %s" % p)
            return
        if node.is_dir():
            for name, child in sorted(node.iterdir(), key=lambda kv: kv[0]):
                if name in (".", "..") or not name:
                    continue
                one(child, p.rstrip("/") + "/" + name)
            return
        size = node.size
        if size > MAX_FILE:
            print("  跳过超大文件(%d) %s" % (size, p))
            return
        if stats["b"] > MAX_TOTAL:
            print("  跳过（超出总量预算）%s" % p)
            return
        target = os.path.join(dest, p.lstrip("/").replace("/", os.sep))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        try:
            data = node.open().read()
        except Exception as e:
            print("  读失败 %s %r" % (p, e))
            stats["err"] += 1
            return
        with open(target, "wb") as o:
            o.write(data)
        stats["n"] += 1
        stats["b"] += len(data)
        if stats["n"] % 200 == 0:
            print("  进度: %d 个 / %.1f MiB" % (stats["n"], stats["b"] / 2**20))

    for p in paths:
        print("提取", p)
        try:
            one(fs.get(p), p)
        except Exception as e:
            print("  不存在或不可读 %s (%r)" % (p, e))
    print("完成: %d 个文件 / %.1f MiB / 失败 %d" % (stats["n"], stats["b"] / 2**20, stats["err"]))


def main():
    mode = sys.argv[1]
    dev, part = sys.argv[2], int(sys.argv[3])
    fs = open_fs(dev, part)
    if mode == "list":
        path = sys.argv[4] if len(sys.argv) > 4 else "/"
        depth = int(sys.argv[5]) if len(sys.argv) > 5 else 2
        cmd_list(fs, path, depth)
    elif mode == "extract":
        dest, paths = sys.argv[4], sys.argv[5:]
        cmd_extract(fs, dest, paths)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        traceback.print_exc()
        sys.exit(1)
