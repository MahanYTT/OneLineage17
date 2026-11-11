import zipfile, struct, hashlib, zlib

def uleb(b, o):
    r = s = 0
    while True:
        x = b[o]; o += 1
        r |= (x & 0x7f) << s; s += 7
        if x < 0x80: return r, o

def patch_camera_proxy(jar_in, jar_out):
    z = zipfile.ZipFile(jar_in)
    data = {name: bytearray(z.read(name)) for name in z.namelist()}
    d = data['classes2.dex']
    
    h = lambda off: struct.unpack_from('<I', d, off)[0]
    sid_o, tid_o, mid_o, cdef_n, cdef_o = h(0x3c), h(0x44), h(0x5c), h(0x60), h(0x64)
    string = lambda i: d[uleb(d, h(sid_o + 4 * i))[1]:d.index(b'\0', uleb(d, h(sid_o + 4 * i))[1])].decode('utf-8', 'replace')
    tname = lambda i: string(h(tid_o + 4 * i))
    mref = lambda i: (tname(struct.unpack_from('<H', d, mid_o + 8 * i)[0]), string(struct.unpack_from('<I', d, mid_o + 8 * i + 4)[0]))

    target_map = {
        'Landroid/hardware/ICameraService$Stub$Proxy;': {
            'createDefaultRequest': (23, 24),
            'isSessionConfigurationWithParametersSupported': (24, 25),
            'getSessionCharacteristics': (25, 26),
            'warmUp': (26, 27),
        },
        'Landroid/hardware/camera2/ICameraDeviceUser$Stub$Proxy;': {
            'getInputSurface': (13, 14),
            'createDefaultRequest': (14, 15),
            'getCameraInfo': (15, 16),
            'waitUntilIdle': (16, 17),
            'flush': (17, 18),
            'prepare': (18, 19),
            'tearDown': (19, 20),
            'prepare2': (20, 21),
            'updateOutputConfiguration': (21, 22),
            'finalizeOutputConfigurations': (22, 23),
            'getCaptureResultMetadataQueue': (23, 24),
            'setCameraAudioRestriction': (24, 25),
            'getGlobalAudioRestriction': (25, 26),
            'switchToOffline': (26, 27),
            'isPrimaryClient': (27, 28),
            'updateOutputConfigurations': (28, 29),
        }
    }

    patched_count = 0
    for c in range(cdef_n):
        base = cdef_o + 32 * c
        cname = tname(h(base))
        if cname not in target_map:
            continue
        c_targets = target_map[cname]
        cd = h(base + 24)
        if not cd: continue
        o = cd
        sf, o = uleb(d, o); inf, o = uleb(d, o); dm, o = uleb(d, o); vm, o = uleb(d, o)
        for _ in range(sf + inf): _, o = uleb(d, o); _, o = uleb(d, o)
        for count in (dm, vm):
            idx = 0
            for _ in range(count):
                diff, o = uleb(d, o); acc, o = uleb(d, o); code, o = uleb(d, o)
                idx += diff
                if not code: continue
                mname = string(struct.unpack_from('<I', d, mid_o + 8 * idx + 4)[0])
                if mname not in c_targets: continue
                old_tx, new_tx = c_targets[mname]
                isz = struct.unpack_from('<I', d, code + 12)[0]
                ins = d[code + 16: code + 16 + isz * 2]
                for k in range(0, len(ins), 2):
                    if ins[k] == 0x72 and k + 6 <= len(ins):
                        midx = struct.unpack_from('<H', ins, k + 2)[0]
                        if mref(midx)[1] == 'transact':
                            reg_e = (ins[k+4] >> 4) & 0xf
                            for p in range(k - 2, max(-2, k - 20), -2):
                                if ins[p] == 0x13 and ins[p+1] == reg_e:
                                    val = struct.unpack_from('<h', ins, p+2)[0]
                                    assert val == old_tx, f"Expected {old_tx} got {val} in {cname}.{mname}"
                                    struct.pack_into('<h', d, code + 16 + p + 2, new_tx)
                                    print(f"Patched {cname}.{mname}: tx {old_tx} -> {new_tx}")
                                    patched_count += 1
                                    break
                                elif ins[p] == 0x12 and (ins[p+1] & 0xf) == reg_e:
                                    val = (ins[p+1] >> 4)
                                    if val & 8: val -= 16
                                    assert val == old_tx, f"Expected {old_tx} got {val} in {cname}.{mname}"
                                    # Need const/16 if new_tx >= 8, but old_tx was < 8
                                    raise ValueError(f"const/4 not expected for {mname}")
    print(f"Total methods patched: {patched_count}")
    assert patched_count == 20, f"Expected 20 patched methods, got {patched_count}"

    # Fix checksums in classes2.dex
    d[12:32] = hashlib.sha1(bytes(d[32:])).digest()
    struct.pack_into('<I', d, 8, zlib.adler32(bytes(d[12:])) & 0xffffffff)

    with zipfile.ZipFile(jar_out, 'w', zipfile.ZIP_DEFLATED) as zo:
        for name in z.namelist():
            zo.writestr(name, bytes(data[name]))
    print(f"Wrote patched jar: {jar_out}")

if __name__ == '__main__':
    tmp = r"C:\Users\Mahan\AppData\Local\Temp\opencode"
    patch_camera_proxy(tmp + r"\l24_framework.jar", tmp + r"\framework17_patched.jar")
