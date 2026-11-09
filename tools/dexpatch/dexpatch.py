"""Dex method patcher (void / boolean / object / int returns).

usage:
  dexpatch2.py JAR list CLASS_DESCRIPTOR
  dexpatch2.py JAR patch OUTJAR CLASS_DESCRIPTOR:METHOD[:VALUE] [...]
Searches every classesN.dex. Each named method (all overloads with that name)
gets a body of "return-void" / "const/4 v0, VALUE; return v0" /
"const/4 v0, 0; return-object v0", nops over the rest, then the dex SHA-1 and
adler32 are fixed. Other zip entries are copied byte-identical.
"""
import struct, sys, zipfile, hashlib, zlib


def uleb(b, o):
    r = s = 0
    while True:
        x = b[o]; o += 1
        r |= (x & 0x7f) << s; s += 7
        if x < 0x80:
            return r, o


def mutf8(b, off):
    _, o = uleb(b, off)
    e = b.index(b'\0', o)
    return b[o:e].decode('utf-8', 'replace')


def methods(d, cls_desc):
    h = lambda off: struct.unpack_from('<I', d, off)[0]
    sid_o, tid_o, pid_o = h(0x3c), h(0x44), h(0x4c)
    mid_o, cdef_n, cdef_o = h(0x5c), h(0x60), h(0x64)
    string = lambda i: mutf8(d, h(sid_o + 4 * i))
    tname = lambda i: string(h(tid_o + 4 * i))
    for c in range(cdef_n):
        base = cdef_o + 32 * c
        if tname(h(base)) != cls_desc:
            continue
        cd = h(base + 24)
        if not cd:
            return []
        o = cd
        sf, o = uleb(d, o); inf, o = uleb(d, o); dm, o = uleb(d, o); vm, o = uleb(d, o)
        for _ in range(sf + inf):
            _, o = uleb(d, o); _, o = uleb(d, o)
        out = []
        for count in (dm, vm):
            idx = 0
            for _ in range(count):
                diff, o = uleb(d, o); acc, o = uleb(d, o); code, o = uleb(d, o)
                idx += diff
                cls, proto, name = struct.unpack_from('<HHI', d, mid_o + 8 * idx)
                ret = tname(h(pid_o + 12 * proto + 4))
                out.append((string(name), ret, acc, code))
        return out
    return None


def body(ret, value, isz, regs):
    if ret == 'V':
        ins = bytes([0x0e, 0x00])
    elif ret in ('Z', 'I', 'B', 'S', 'C'):
        assert regs >= 1
        ins = bytes([0x12, (int(value or 0) & 0xf) << 4, 0x0f, 0x00])
    elif ret in ('J', 'D'):
        assert regs >= 2
        # const-wide/16 v0, #0 ; return-wide v0
        ins = bytes([0x16, 0x00, 0x00, 0x00, 0x10, 0x00])
    elif ret.startswith('L') or ret.startswith('['):
        assert regs >= 1
        ins = bytes([0x12, 0x00, 0x11, 0x00])
    else:
        raise SystemExit('unsupported return type ' + ret)
    assert len(ins) <= isz * 2, 'method too short'
    return ins + bytes(isz * 2 - len(ins))


def main():
    jar, mode = sys.argv[1], sys.argv[2]
    z = zipfile.ZipFile(jar)
    dexes = sorted(n for n in z.namelist() if n.startswith('classes') and n.endswith('.dex'))
    if mode == 'list':
        for dn in dexes:
            d = z.read(dn)
            ms = methods(d, sys.argv[3])
            if ms is None:
                continue
            for n, r, acc, code in ms:
                print('%s %s ret=%s acc=0x%x code=0x%x' % (dn, n, r, acc, code))
        return
    out = sys.argv[3]
    specs = [s.split(':') for s in sys.argv[4:]]
    data = {dn: bytearray(z.read(dn)) for dn in dexes}
    done = 0
    for spec in specs:
        cls, mname = spec[0], spec[1]
        value = spec[2] if len(spec) > 2 else None
        for dn, d in data.items():
            ms = methods(d, cls)
            if not ms:
                continue
            for n, r, acc, code in ms:
                if n != mname or not code:
                    continue
                regs, _, _, _, _, isz = struct.unpack_from('<HHHHII', d, code)
                d[code + 16:code + 16 + isz * 2] = body(r, value, isz, regs)
                print('patched %s %s.%s ret=%s' % (dn, cls, n, r))
                done += 1
    assert done, 'nothing patched'
    for d in data.values():
        d[12:32] = hashlib.sha1(bytes(d[32:])).digest()
        struct.pack_into('<I', d, 8, zlib.adler32(bytes(d[12:])) & 0xffffffff)
    with zipfile.ZipFile(out, 'w') as zo:
        for i in z.infolist():
            zo.writestr(i, bytes(data[i.filename]) if i.filename in data else z.read(i.filename))
    print('wrote', out)


main()
