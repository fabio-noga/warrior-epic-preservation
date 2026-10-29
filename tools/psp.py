"""Possibility Space PSP archive tool (.pak / .psp) - stdlib only.

Format (little endian), see RECON.md:
  header   "PSP\\0" u32 5, 8 zero bytes
  record   "USD\\0" u32 reclen (next = off+8+reclen) u32 namechars
           utf16le name + NUL, u32 size, 16-byte hash, data[size]
  data     raw, or MARK(16) u32 rawsize zlib-stream
  last rec "<<PSP_DICTIONARY>>" (compressed): per file
           u32 namebytes u32 recoff u32 reclen u32 dataoff u32 size hash16 lower(name)
  trailer  "PSPDICT\\0" u32 dict_record_offset u32 0

usage: psp.py list ARCHIVE
       psp.py cat ARCHIVE NAME            (decompressed to stdout)
       psp.py extract ARCHIVE OUTDIR
       psp.py pack OUT DIR [--compress]   (files under DIR, names relative to DIR)
       psp.py selftest ARCHIVE...         (re-pack in memory, must be byte-identical)
"""
import os, struct, sys, zlib

MARK = bytes.fromhex('f7f4e4c8cad7d5c2d4d4c2c3e1cecbc2')
DICT = '<<PSP_DICTIONARY>>'
ZERO = bytes(16)


def read(path):
    """-> list of (name, stored_bytes, hash16), dictionary record excluded."""
    d = open(path, 'rb').read()
    assert d[:4] == b'PSP\0', 'not a PSP archive'
    out, i = [], 16
    while d[i:i + 4] == b'USD\0':
        reclen, nl = struct.unpack_from('<II', d, i + 4)
        name = d[i + 12:i + 12 + nl * 2].decode('utf-16le')
        p = i + 12 + nl * 2 + 2
        size = struct.unpack_from('<I', d, p)[0]
        if name != DICT:
            out.append((name, d[p + 20:p + 20 + size], d[p + 4:p + 20]))
        i += 8 + reclen
    assert d[i:i + 8] == b'PSPDICT\0', 'missing trailer at %#x' % i
    return out


def unpack(stored):
    if stored[:16] == MARK:
        raw = zlib.decompress(stored[20:])
        assert len(raw) == struct.unpack_from('<I', stored, 16)[0]
        return raw
    return stored


def compress(raw):
    return MARK + struct.pack('<I', len(raw)) + zlib.compress(raw)


def _record(name, stored, h):
    n = name.encode('utf-16le') + b'\0\0'
    body = struct.pack('<I', len(name)) + n + struct.pack('<I', len(stored)) + h + stored
    return b'USD\0' + struct.pack('<I', len(body)) + body


def build(entries):
    """entries: list of (name, stored_bytes, hash16) -> archive bytes."""
    out = bytearray(b'PSP\0' + struct.pack('<I', 5) + bytes(8))
    dic = []
    for name, stored, h in entries:
        off = len(out)
        rec = _record(name, stored, h)
        out += rec
        n = name.lower().encode('utf-16le') + b'\0\0'
        dic.append(struct.pack('<5I', len(n), off, len(rec) - 8, off + len(rec) - len(stored), len(stored)) + h + n)
    dic = b''.join(sorted(dic, key=lambda e: e[36:]))  # sorted by lowercased utf16 name
    doff = len(out)
    out += _record(DICT, compress(dic), ZERO)
    out += b'PSPDICT\0' + struct.pack('<II', doff, 0)
    return bytes(out)


def main(a):
    cmd = a[0] if a else ''
    if cmd == 'list':
        for name, s, h in read(a[1]):
            print('%10d %s %s %s' % (len(s), 'Z' if s[:16] == MARK else '-', h.hex(), name))
    elif cmd == 'cat':
        sys.stdout.buffer.write(unpack({n: s for n, s, _ in read(a[1])}[a[2]]))
    elif cmd == 'extract':
        root = os.path.abspath(a[2])
        for name, s, _ in read(a[1]):
            dst = os.path.abspath(os.path.join(root, *name.split('\\')))
            assert dst.startswith(root + os.sep), 'path escapes outdir: %r' % name
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            with open(dst, 'wb') as f:
                f.write(unpack(s))
    elif cmd == 'pack':
        root, z = a[2], '--compress' in a
        ents = []
        for dp, _, fs in os.walk(root):
            for f in sorted(fs):
                raw = open(os.path.join(dp, f), 'rb').read()
                name = os.path.relpath(os.path.join(dp, f), root).replace('/', '\\')
                ents.append((name, compress(raw) if z else raw, ZERO))  # ponytail: zero hash, real hash algo unknown (WEShell.psp ships zero hashes)
        open(a[1], 'wb').write(build(ents))
    elif cmd == 'selftest':
        for p in a[1:]:
            ok = build(read(p)) == open(p, 'rb').read()
            print('OK  ' if ok else 'FAIL', p)
            assert ok
    else:
        print(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
