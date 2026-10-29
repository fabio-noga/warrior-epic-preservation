"""Static string -> code cross-reference for 32-bit PE files (needs: pip install capstone pefile).

usage: xref.py PE STRING [STRING...]   find each string (ascii + utf16), list code that references it
       xref.py PE @0xVA [N]             disassemble N instructions at VA
Read-only: never executes the PE.
"""
import re, struct, sys
import capstone, pefile

pe = pefile.PE(sys.argv[1], fast_load=True)
img = pe.get_memory_mapped_image()
base = pe.OPTIONAL_HEADER.ImageBase
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
text = next(s for s in pe.sections if s.Characteristics & 0x20000000)
t0, t1 = text.VirtualAddress, text.VirtualAddress + text.Misc_VirtualSize


def sref(v):
    """Printable ascii/utf16 string at VA v, else ''."""
    o = v - base
    if not 0 <= o < len(img) - 2:
        return ''
    m = re.match(b'(?:[ -~]' + bytes(1) + b'){3,}', img[o:o + 400])
    if m:
        return 'L"%s"' % m.group().decode('utf-16le')
    m = re.match(b'[ -~]{4,}', img[o:o + 400])
    return '"%s"' % m.group().decode() if m else ''


def dis(va, n=40):
    for ins in md.disasm(img[va - base:va - base + n * 8], va):
        note = ' '.join(filter(None, (sref(int(x, 16)) for x in re.findall(r'0x[0-9a-f]{6,8}', ins.op_str))))
        print('  %08x  %-8s %s%s' % (ins.address, ins.mnemonic, ins.op_str, '   ; ' + note if note else ''))
        n -= 1
        if not n:
            break


def func_start(rva):
    # ponytail: heuristic, walks back to the nearest CC/C3 padding + push ebp / sub esp, good enough to frame a listing
    for r in range(rva, max(t0, rva - 0x4000), -1):
        if img[r - 1] in (0xCC, 0xC3, 0x90) and img[r] in (0x55, 0x83, 0x81, 0x6A, 0x56, 0x53, 0x64, 0x8B, 0x51):
            return r
    return rva


if sys.argv[2].startswith('@'):
    dis(int(sys.argv[2][1:], 16), int(sys.argv[3]) if len(sys.argv) > 3 else 40)
    sys.exit()

for s in sys.argv[2:]:
    for enc in ('ascii', 'utf-16le'):
        pat = s.encode(enc) + (b'\0\0' if enc != 'ascii' else b'\0')
        for m in re.finditer(re.escape(pat), img):
            va = base + m.start()
            refs = [r.start() for r in re.finditer(re.escape(struct.pack('<I', va)), img[t0:t1])]
            print('%r %s @%08x  refs: %s' % (s, enc, va, ' '.join('%08x' % (base + t0 + r) for r in refs)))
            for r in refs[:6]:
                ref = t0 + r
                print(' -- func ~%08x, ref %08x' % (base + func_start(ref), base + ref))
                dis(base + ref - 24, 16)
