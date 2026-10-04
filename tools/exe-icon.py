#!/usr/bin/env python3
"""Write the largest icon from a Windows .exe's resources as a .png or .ico file.

Usage: exe-icon.py <file.exe> <out-base>   -> prints the path written (<out-base>.png or .ico)

Used by `altium-wine.sh launcher` to give the Mac launcher app Altium's icon. Exits non-zero
(and the launcher goes without an icon) if the exe has no icon resources.
"""
import struct
import sys
import zlib

RT_ICON, RT_GROUP_ICON = 3, 14


def dib_to_png(data):
    """32- or 24-bit icon DIB (BITMAPINFOHEADER + XOR bitmap + AND mask) -> PNG bytes, else None."""
    hsize, w, h2, _, bpp, comp = struct.unpack_from("<IiiHHI", data, 0)
    h = h2 // 2
    if comp != 0 or bpp not in (24, 32) or w <= 0 or h <= 0:
        return None
    stride = (w * bpp // 8 + 3) & ~3
    mask_stride = ((w + 31) // 32) * 4
    xor = hsize
    andm = xor + stride * h
    rows = []
    for y in range(h):
        src = xor + stride * (h - 1 - y)  # bottom-up
        msk = andm + mask_stride * (h - 1 - y)
        row = bytearray(b"\0")
        for x in range(w):
            px = data[src + x * (bpp // 8):src + x * (bpp // 8) + bpp // 8]
            if bpp == 32:
                a = px[3]
            else:
                transparent = andm + mask_stride * h <= len(data) and data[msk + x // 8] >> (7 - x % 8) & 1
                a = 0 if transparent else 255
            row += bytes((px[2], px[1], px[0], a))
        rows.append(bytes(row))
    if bpp == 32 and not any(r[4::4].strip(b"\0") for r in rows):  # 32-bit with an empty alpha channel
        return None

    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b""))


def main(exe, out_base):
    b = open(exe, "rb").read()
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    if b[pe:pe + 4] != b"PE\0\0":
        raise SystemExit("not a PE file")
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    optsize = struct.unpack_from("<H", b, pe + 20)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", b, opt)[0]
    ddir = opt + (112 if magic == 0x20B else 96)
    rsrc_rva = struct.unpack_from("<I", b, ddir + 2 * 8)[0]
    secs = []
    for i in range(nsec):
        s = opt + optsize + 40 * i
        vs, va, rs, ro = struct.unpack_from("<IIII", b, s + 8)
        secs.append((va, max(vs, rs), ro))

    def off(rva):
        for va, size, ro in secs:
            if va <= rva < va + size:
                return ro + rva - va
        raise SystemExit("rva %x not in file" % rva)

    base = off(rsrc_rva)

    def entries(dir_off):
        named, ids = struct.unpack_from("<HH", b, dir_off + 12)
        for i in range(named + ids):
            name, target = struct.unpack_from("<II", b, dir_off + 16 + 8 * i)
            yield name, target

    def leaf(target):  # follow subdirectories down to the first data entry
        while target & 0x80000000:
            target = next(entries(base + (target & 0x7FFFFFFF)))[1]
        rva, size = struct.unpack_from("<II", b, base + target)
        return b[off(rva):off(rva) + size]

    by_type = {}
    for name, target in entries(base):
        if not name & 0x80000000 and target & 0x80000000:
            by_type[name] = {n: t for n, t in entries(base + (target & 0x7FFFFFFF))}
    if RT_GROUP_ICON not in by_type or RT_ICON not in by_type:
        raise SystemExit("no icon resources")

    group = leaf(next(iter(by_type[RT_GROUP_ICON].values())))
    count = struct.unpack_from("<H", group, 4)[0]
    best = None
    for i in range(count):
        w, h, colors, _, planes, bpp, size, icon_id = struct.unpack_from("<BBBBHHIH", group, 6 + 14 * i)
        key = ((w or 256) * (h or 256), bpp)
        if best is None or key > best[0]:
            best = (key, (w, h, colors, planes, bpp, icon_id))
    w, h, colors, planes, bpp, icon_id = best[1]
    if icon_id not in by_type[RT_ICON]:
        raise SystemExit("icon %d missing" % icon_id)
    data = leaf(by_type[RT_ICON][icon_id])
    png = data if data.startswith(b"\x89PNG") else dib_to_png(data)
    if png:
        path = out_base + ".png"
        open(path, "wb").write(png)
    else:
        path = out_base + ".ico"
        hdr = struct.pack("<HHH", 0, 1, 1) + struct.pack("<BBBBHHII", w, h, colors, 0, planes, bpp, len(data), 22)
        open(path, "wb").write(hdr + data)
    print(path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
