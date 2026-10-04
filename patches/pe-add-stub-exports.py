#!/usr/bin/env python3
"""Add stub exports to a 64-bit Wine builtin PE DLL (e.g. user32.dll).

Altium 26 calls user32!InheritWindowMonitor (Windows 10 1903+) through delay-load whenever
it opens a menu or popup. Wine 11.16 doesn't export it, so the delay-load helper raises
C06D007F, Altium shows a modal "Error" dialog, and the main window stops taking input.

This rebuilds the export directory in a new section with the extra names, each pointing
to a tiny stub ("mov eax, <value>; ret"). Existing exports, including forwarders, keep
working.

Usage: pe-add-stub-exports.py <in.dll> <out.dll> Name=value [Name=value ...]
       e.g. pe-add-stub-exports.py user32.dll user32.dll InheritWindowMonitor=1
"""
import struct
import sys


def align(v, a):
    return (v + a - 1) & ~(a - 1)


def main(src, dst, specs):
    b = bytearray(open(src, "rb").read())
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    assert b[pe:pe + 4] == b"PE\0\0"
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    optsize = struct.unpack_from("<H", b, pe + 20)[0]
    opt = pe + 24
    assert struct.unpack_from("<H", b, opt)[0] == 0x20B, "64-bit PE only"
    sect_align, file_align = struct.unpack_from("<II", b, opt + 32)
    size_of_headers = struct.unpack_from("<I", b, opt + 60)[0]
    dd = opt + 112                       # data directories (PE32+)
    exp_rva, exp_size = struct.unpack_from("<II", b, dd)
    sec0 = opt + optsize
    secs = []
    for i in range(nsec):
        s = sec0 + 40 * i
        vs, va, rs, ro = struct.unpack_from("<IIII", b, s + 8)
        secs.append((vs, va, rs, ro))

    def off(rva):
        for vs, va, rs, ro in secs:
            if va <= rva < va + max(vs, rs):
                return ro + rva - va
        raise ValueError("rva %x not in any section" % rva)

    def cstr(rva):
        o = off(rva)
        return bytes(b[o:b.index(b"\0", o)])

    (_, _, _, _, name_rva, ord_base, nfuncs, nnames,
     funcs_rva, names_rva, ords_rva) = struct.unpack_from("<IIHHIIIIIII", b, off(exp_rva))
    funcs = list(struct.unpack_from("<%dI" % nfuncs, b, off(funcs_rva)))
    names = [cstr(r) for r in struct.unpack_from("<%dI" % nnames, b, off(names_rva))]
    ords = list(struct.unpack_from("<%dH" % nnames, b, off(ords_rva)))
    dll_name = cstr(name_rva)

    new = []
    for spec in specs:
        n, v = spec.split("=")
        if n.encode() in names:
            raise SystemExit("%s already exported" % n)
        new.append((n.encode(), int(v, 0)))

    # ---- lay out the new section --------------------------------------------
    last_va = max(va + max(vs, rs) for vs, va, rs, ro in secs)
    new_va = align(last_va, sect_align)
    blob = bytearray()

    def put(data, a=1):
        while len(blob) % a:
            blob.append(0)
        r = new_va + len(blob)
        blob.extend(data)
        return r

    stub_rvas = [put(b"\xb8" + struct.pack("<i", v) + b"\xc3", 16) for _, v in new]
    edir_start = len(blob) + (-len(blob) % 4)
    put(b"\0" * 40, 4)                                       # export directory, filled below
    # forwarders: function RVAs inside the old export range must move into the new range
    for i, f in enumerate(funcs):
        if exp_rva <= f < exp_rva + exp_size:
            funcs[i] = put(cstr(f) + b"\0")
    funcs += stub_rvas
    entries = sorted([(names[i], ords[i]) for i in range(nnames)] +
                     [(n, nfuncs + k) for k, (n, _) in enumerate(new)])
    name_rvas = [put(n + b"\0") for n, _ in entries]
    dllname_rva = put(dll_name + b"\0")
    funcs_new = put(struct.pack("<%dI" % len(funcs), *funcs), 4)
    names_new = put(struct.pack("<%dI" % len(entries), *name_rvas), 4)
    ords_new = put(struct.pack("<%dH" % len(entries), *[o for _, o in entries]), 2)
    edir_rva = new_va + edir_start
    struct.pack_into("<IIHHIIIIIII", blob, edir_start, 0, 0, 0, 0, dllname_rva, ord_base,
                     len(funcs), len(entries), funcs_new, names_new, ords_new)
    edir_size = new_va + len(blob) - edir_rva

    # ---- append section ------------------------------------------------------
    hdr = sec0 + 40 * nsec
    if hdr + 40 > size_of_headers:
        raise SystemExit("no room for another section header")
    raw_off = align(len(b), file_align)
    raw_size = align(len(blob), file_align)
    b.extend(b"\0" * (raw_off - len(b)))
    b.extend(blob + b"\0" * (raw_size - len(blob)))
    struct.pack_into("<8sIIIIIIHHI", b, hdr, b".wstubs", len(blob), new_va, raw_size, raw_off,
                     0, 0, 0, 0, 0x60000020)                  # code | exec | read
    struct.pack_into("<H", b, pe + 6, nsec + 1)
    struct.pack_into("<I", b, opt + 56, align(new_va + len(blob), sect_align))  # SizeOfImage
    struct.pack_into("<II", b, dd, edir_rva, edir_size)
    open(dst, "wb").write(b)
    print("%s: added %s" % (dst, ", ".join(n.decode() for n, _ in new)))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
