"""Write fabricated runtime resource overlays (.frro, version 3) with dimension
values. `cmd overlay fabricate` only accepts integer types (16-31), so the
status bar dimensions cannot be made on the phone.

Layout (matches the files Lineage's idmap2d writes, e.g. the cutout overlay):
  "FRRO" | u32 version=3 | u32 crc | u32 0 | u32 string-pool size |
  ResStringPool chunk | protobuf FabricatedOverlay
The crc is only an identity value (idmap2 copies it into the idmap and
compares it later); a crc32 of the payload is used.

usage: python make_frro.py OUTDIR
Writes the overlays listed in OVERLAYS below. Values are pixels for the S26
Ultra at the guest density 540 (see apply_statusbar_layout in
assets/switch_to_lineage.sh).
"""
import os
import struct
import sys
import zlib

OWNER = "com.android.shell"
TYPE_DIMENSION = 0x05

# (asset file, overlay name, target package, resource type, entry, px)
OVERLAYS = [
    ("sb_height_default.frro", "ol_sb_height_default", "android", "dimen", "status_bar_height_default", 149),
    ("sb_height_portrait.frro", "ol_sb_height_portrait", "android", "dimen", "status_bar_height_portrait", 149),
    ("sbui_pad_top.frro", "ol_sbui_pad_top", "com.android.systemui", "dimen", "status_bar_padding_top", 20),
    ("sbui_pad_start.frro", "ol_sbui_pad_start", "com.android.systemui", "dimen", "status_bar_padding_start", 48),
    ("sbui_pad_end.frro", "ol_sbui_pad_end", "com.android.systemui", "dimen", "status_bar_padding_end", 0),
]


def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])


def field_bytes(num, data):
    return varint((num << 3) | 2) + varint(len(data)) + data


def field_varint(num, value):
    return varint(num << 3) + varint(value) if value else b""


def string_pool():
    # One empty UTF-8 string: header (0x1c), one offset, data "\0\0\0" + pad.
    strings = b"\x00\x00\x00\x00"
    header_size = 0x1C
    strings_start = header_size + 4
    size = strings_start + len(strings)
    return struct.pack("<HHIIIIII", 0x0001, header_size, size, 1, 0, 0x100, strings_start, 0) \
        + struct.pack("<I", 0) + strings


def dimension_px(px):
    # TypedValue complex: integer mantissa << 8, radix 23p0 (0), unit px (0).
    return (px << 8) & 0xFFFFFFFF


def frro(name, target, rtype, entry, px):
    value = field_varint(1, TYPE_DIMENSION) + field_varint(2, dimension_px(px))
    pb_entry = field_bytes(1, entry.encode()) + field_bytes(2, value)
    pb_type = field_bytes(1, rtype.encode()) + field_bytes(2, pb_entry)
    pb_package = field_bytes(1, target.encode()) + field_bytes(2, pb_type)
    pb = field_bytes(1, pb_package) + field_bytes(2, name.encode()) \
        + field_bytes(3, OWNER.encode()) + field_bytes(4, target.encode())
    sp = string_pool()
    crc = zlib.crc32(sp + pb) & 0xFFFFFFFF
    return b"FRRO" + struct.pack("<IIII", 3, crc, 0, len(sp)) + sp + pb


def main():
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    for fname, name, target, rtype, entry, px in OVERLAYS:
        with open(os.path.join(out, fname), "wb") as f:
            f.write(frro(name, target, rtype, entry, px))
        print(f"{fname}: {target}:{rtype}/{entry} = {px}px ({OWNER}:{name})")


if __name__ == "__main__":
    main()
