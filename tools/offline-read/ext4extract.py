"""Extract files from an ext4 partition on a raw disk / image (read-only).

usage:
  python ext4extract.py <dev> <list|extract> <part_index> <dest_or_dir> [src_path ...]

GPT partitions are parsed from LBA1 of <dev>.
part_index: 1-based GPT partition number (0 = whole device, no partition).
"""
import sys, io, os, struct, traceback
import ext4

MAX_FILE = 64 * 1024 * 1024
MAX_TOTAL = 500 * 1024 * 1024

CTL = set(range(32)) | {127}


def clean_name(n: bytes) -> str:
    # dirent parsing in this lib sometimes appends stray control bytes
    s = n.decode("utf-8", "replace")
    return s.rstrip("".join(chr(c) for c in CTL))


def gpt_partitions(f):
    f.seek(512)
    h = f.read(92)
    if h[:8] != b"EFI PART":
        # MBR fallback
        f.seek(446)
        parts = []
        for i in range(4):
            e = f.read(16)
            if e[4] == 0:
                continue
            parts.append((i + 1, struct.unpack("<I", e[8:12])[0] * 512,
                          struct.unpack("<I", e[12:16])[0] * 512))
        return parts
    (_sig, _rev, _sz, _crc, _, _cur, _bak, _first, _last, _guid,
     entry_lba, npart, psize, _pcrc) = struct.unpack("<8sIIIIQQQQ16sQIII", h[:92])
    f.seek(entry_lba * 512)
    entries = f.read(npart * psize)
    out = []
    for i in range(npart):
        e = entries[i * psize:(i + 1) * psize]
        if e[0:16] == b"\x00" * 16:
            continue
        first_lba, last_lba = struct.unpack("<QQ", e[32:48])
        name = e[56:128].decode("utf-16le").rstrip("\x00")
        out.append((i + 1, first_lba * 512, (last_lba - first_lba + 1) * 512, name))
    return out


def dir_list(vol, path, depth, maxdepth, out, budget):
    try:
        d = vol.inode_at(path)
    except Exception as e:
        out.append(("ERR", path, str(e)))
        return
    if not isinstance(d, ext4.Directory):
        return
    try:
        items = sorted({clean_name(dt.name_bytes): ft for dt, ft in d.opendir()}.items())
    except Exception as e:
        out.append(("ERR", path, str(e)))
        return
    for name, ft in items:
        if name in (".", "..", "lost+found") or not name:
            continue
        p = path.rstrip("/") + "/" + name
        try:
            node = vol.inode_at(p)
        except Exception as e:
            out.append(("ERR", p, repr(e)))
            continue
        isdir = isinstance(node, ext4.Directory)
        out.append(("DIR " if isdir else "FILE", p, getattr(node, "i_size", 0)))
        budget[0] += 1
        if isdir and depth < maxdepth:
            dir_list(vol, p, depth + 1, maxdepth, out, budget)


def extract(vol, src, dest_root, stats):
    try:
        node = vol.inode_at(src)
    except Exception as e:
        print("  SKIP (not found):", src, e)
        return
    if isinstance(node, ext4.Directory):
        stack = [(src, node)]
        while stack:
            cur, dn = stack.pop()
            try:
                items = sorted({clean_name(dt.name_bytes): ft for dt, ft in dn.opendir()}.items())
            except Exception as e:
                print("  ERR list", cur, e)
                continue
            for name, _ft in items:
                if name in (".", "..", "lost+found") or not name:
                    continue
                p = cur.rstrip("/") + "/" + name
                try:
                    n2 = vol.inode_at(p)
                except Exception as e:
                    print("  ERR open", p, e)
                    continue
                rel = p.lstrip("/")
                target = os.path.join(dest_root, rel)
                if isinstance(n2, ext4.Directory):
                    os.makedirs(target, exist_ok=True)
                    stack.append((p, n2))
                else:
                    extract_file(vol, n2, p, target, stats)
    else:
        extract_file(vol, node, src, os.path.join(dest_root, src.lstrip("/")), stats)


def extract_file(vol, node, src, target, stats):
    size = getattr(node, "i_size", None)
    if size is None:
        size = getattr(node, "size", 0) or 0
    if size > MAX_FILE:
        print("  SKIP big (%d): %s" % (size, src))
        return
    if stats["total"] + size > MAX_TOTAL:
        print("  SKIP budget: %s" % src)
        return
    try:
        data = node.open().read()
    except Exception as e:
        print("  ERR read", src, e)
        return
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "wb") as o:
        o.write(data)
    stats["total"] += len(data)
    stats["count"] += 1
    print("  + %-9d %s" % (len(data), src))


def main():
    dev, mode, part_arg = sys.argv[1], sys.argv[2], sys.argv[3]
    rest = sys.argv[4:]
    f = open(dev, "rb", buffering=0)
    parts = gpt_partitions(f)
    print("GPT partitions:")
    for p in parts:
        print("   ", p)
    if part_arg == "0":
        offset = 0
        label = "whole"
    else:
        idx = int(part_arg)
        offset = [p[1] for p in parts if p[0] == idx][0]
        label = [p[3] for p in parts if p[0] == idx][0] if len(parts[0]) > 3 else str(idx)
    print("using partition", idx if part_arg != "0" else 0, "offset", offset, "label", label)
    stream = io.BufferedReader(f, buffer_size=1 << 20)
    vol = ext4.Volume(stream, offset=offset)
    sb = vol.superblock
    print("VOLUME label=%r uuid=%s blocksize=%s" % (
        bytes(sb.s_volume_name).split(b"\x00")[0], sb.s_uuid, vol.block_size))

    if mode == "list":
        dest = rest[0] if rest else "/"
        maxdepth = int(rest[1]) if len(rest) > 1 else 3
        out = []
        dir_list(vol, dest, 1, maxdepth, out, budget=[0])
        for kind, p, size in out:
            print("%s %-76s %s" % (kind, p, size))
    else:
        dest_root = rest[0]
        srcs = rest[1:]
        stats = {"total": 0, "count": 0}
        os.makedirs(dest_root, exist_ok=True)
        for s in srcs:
            print("extract", s)
            extract(vol, s, dest_root, stats)
        print("DONE files=%d bytes=%d" % (stats["count"], stats["total"]))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(1)
