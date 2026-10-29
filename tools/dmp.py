"""Read memory from a full minidump (MiniDumpWithFullMemory) with the stdlib only. Read-only.

usage: dmp.py DUMP modules                 list modules (base, size, name)
       dmp.py DUMP deref VA OFF..    follow pointers: [VA] then +OFF, deref, ... and print u32s
"""
import struct, sys


class Dump:
    def __init__(self, path):
        self.f = open(path, 'rb')
        hdr = self._r(0, 32)
        n, rva = struct.unpack_from('<II', hdr, 8)
        self.streams = {}
        for i in range(n):
            t, size, off = struct.unpack('<III', self._r(rva + 12 * i, 12))
            self.streams[t] = (off, size)
        off, _ = self.streams[9]                       # Memory64ListStream
        cnt, base = struct.unpack('<QQ', self._r(off, 16))
        self.ranges = []
        for i in range(cnt):
            va, sz = struct.unpack('<QQ', self._r(off + 16 + 16 * i, 16))
            self.ranges.append((va, sz, base)); base += sz
        self.mods = []
        off, _ = self.streams[4]                       # ModuleListStream
        (cnt,) = struct.unpack('<I', self._r(off, 4))
        for i in range(cnt):
            m = self._r(off + 4 + 108 * i, 108)
            b, size = struct.unpack_from('<QI', m, 0)
            (nrva,) = struct.unpack_from('<I', m, 20)
            (ln,) = struct.unpack('<I', self._r(nrva, 4))
            self.mods.append((b, size, self._r(nrva + 4, ln).decode('utf-16le')))

    def _r(self, off, n):
        self.f.seek(off); return self.f.read(n)

    def read(self, va, n):
        for r, sz, fo in self.ranges:
            if r <= va < r + sz:
                return self._r(fo + va - r, min(n, r + sz - va))
        return None

    def u32(self, va):
        b = self.read(va, 4)
        return struct.unpack('<I', b)[0] if b and len(b) == 4 else None

    def module(self, name):
        return next(m for m in self.mods if m[2].lower().endswith(name.lower()))


if __name__ == '__main__':
    d = Dump(sys.argv[1])
    if sys.argv[2] == 'modules':
        for b, s, n in d.mods: print('%08x %08x %s' % (b, s, n))
        sys.exit()
    va = int(sys.argv[3], 16)      # ponytail: assumes modules sit at their preferred base (true so far); rebase if not
    if sys.argv[2] == 'read':
        print(d.read(va, int(sys.argv[4], 0)).hex(' '))
    else:
        p = d.u32(va); print('[%08x] = %08x' % (va, p))
        for off in sys.argv[4:]:
            a = p + int(off, 16); p = d.u32(a); print('[%08x] = %s' % (a, '%08x' % p if p is not None else '??'))
