"""Sector-aligned raw disk reader (Windows \\\\.\\PhysicalDriveN requires
512-byte-aligned offsets/lengths for read()). Mimics a buffered file object
including peek(), so it can be handed to ext4.Volume."""


class RawDisk:
    ALIGN = 512

    def __init__(self, path):
        self.f = open(path, "rb", buffering=0)
        self.pos = 0
        self._cache = b""
        self._cache_start = 0
        self._cache_end = 0
        self.CACHE = 1 << 20
        self.size = self._query_size()

    def _query_size(self):
        """Device length via IOCTL_DISK_GET_LENGTH_INFO; fallback to 1 TiB."""
        try:
            import ctypes, ctypes.wintypes as wt, msvcrt
            k32 = ctypes.windll.kernel32
            handle = msvcrt.get_osfhandle(self.f.fileno())
            class LI(ctypes.Structure):
                _fields_ = [("Length", ctypes.c_int64)]
            li = LI()
            ret = wt.DWORD()
            ok = k32.DeviceIoControl(handle, 0x0007405C, None, 0,
                                     ctypes.byref(li), ctypes.sizeof(li),
                                     ctypes.byref(ret), None)
            if ok and li.Length > 0:
                return int(li.Length)
        except Exception:
            pass
        return 1 << 40

    def seek(self, offset, whence=0):
        if whence == 0:
            self.pos = offset
        elif whence == 1:
            self.pos += offset
        elif whence == 2:
            self.pos = self.size + offset
        else:
            raise ValueError("bad whence")
        return self.pos

    def tell(self):
        return self.pos

    def _fetch(self, start, end):
        """bytes for [start, end), using/extending the cache."""
        if end <= start:
            return b""
        if self._cache_start <= start and end <= self._cache_end:
            s = start - self._cache_start
            return self._cache[s:s + (end - start)]
        if (end - start) > self.CACHE:
            a = start - (start % self.ALIGN)
            self.f.seek(a)
            raw = self.f.read((end - a) + self.ALIGN)
            pad = start - a
            return raw[pad:pad + (end - start)]
        a = start - (start % self.ALIGN)
        self.f.seek(a)
        data = self.f.read(max(self.CACHE, end - a))
        self._cache = data
        self._cache_start = a
        self._cache_end = a + len(data)
        s = start - a
        return data[s:s + (end - start)]

    def read(self, n=-1):
        if n is None or n < 0:
            n = 1 << 40
        start = self.pos
        end = start + n
        data = self._fetch(start, end)
        self.pos = start + len(data)
        return data

    def peek(self, n):
        return self._fetch(self.pos, self.pos + n)

    def close(self):
        self.f.close()
