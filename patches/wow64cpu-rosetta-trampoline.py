#!/usr/bin/env python3
"""Binary-patch wow64cpu.dll (Wine 11.16 staging, x86_64-windows) to work around a
Rosetta 2 bug on Apple Silicon.

Symptom: 32-bit apps crash with "exception outside of stack limits" at wow64cpu+0x1135
(or +0x1239). The 32->64 far jump in the syscall/unix-call thunks lands in 64-bit code
while the CPU is still in 32-bit mode. It shows up right after the app writes code into a
page that already ran (Delphi MakeObjectInstance), i.e. after Rosetta retranslates.

Fix: point both thunks at mode-detecting trampolines placed in .text padding. The same
bytes decode differently in each mode:
    31 c9        xor ecx,ecx
    41 89 c9     32-bit: inc ecx; mov ecx,ecx   64-bit: mov r9d,ecx
    e3 0d        jecxz/jrcxz -> 64-bit path
    e8 00000000  59  83 c1 f4   (32-bit) ecx = trampoline address
    6a 2b 51 cb  push 0x2b; push ecx; retf  -> retry the switch into 64-bit mode
    e9 rel32     (64-bit) jmp to the real wow64cpu entry
ecx/r9/flags are volatile at these entry points.

Usage: wow64cpu-rosetta-trampoline.py <stock wow64cpu.dll> <output wow64cpu.dll>
Addresses below are for the Gcenx wine-staging 11.16 build; the script refuses to patch
anything whose bytes don't match.
"""
import struct
import sys

SYSCALL_ENTRY = 0x7a40110c
UNIXCALL_ENTRY = 0x7a401210
# lea disp32(%rip) that load the two thunk targets in BTCpuProcessInit: (insn addr, next insn)
LEA_SYSCALL = (0x7a40140e, 0x7a401415, bytes.fromhex("488d0d"), -0x309)
LEA_UNIXCALL = (0x7a401430, 0x7a401437, bytes.fromhex("488d15"), -0x227)


def main(src, dst):
    b = bytearray(open(src, "rb").read())
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    nsec = struct.unpack_from("<H", b, pe + 6)[0]
    optsize = struct.unpack_from("<H", b, pe + 20)[0]
    base = struct.unpack_from("<Q", b, pe + 24 + 24)[0]
    sec0 = pe + 24 + optsize
    secs = []
    for i in range(nsec):
        s = sec0 + 40 * i
        vs, va, rs, ro = struct.unpack_from("<IIII", b, s + 8)
        secs.append((vs, va, rs, ro, s))

    def off(v):
        r = v - base
        for vs, va, rs, ro, _ in secs:
            if va <= r < va + rs:
                return ro + r - va
        raise SystemExit("address %x not in file" % v)

    text_vs, text_va, text_rs, _, text_hdr = secs[0]
    tramp1 = base + text_va + ((text_vs + 0xF) & ~0xF) + 0x10
    tramp2 = tramp1 + 0x20
    if tramp2 + 0x20 - base - text_va > text_rs:
        raise SystemExit("no room in .text padding")
    if any(x not in (0, 0xCC) for x in b[off(tramp1):off(tramp1) + 0x40]):
        raise SystemExit("padding not empty; already patched or different build")

    for at, nxt, opc, disp in (LEA_SYSCALL, LEA_UNIXCALL):
        o = off(at)
        if bytes(b[o:o + 3]) != opc or struct.unpack_from("<i", b, o + 3)[0] != disp:
            raise SystemExit("unexpected bytes at %x; not the 11.16 build" % at)

    def tramp(addr, real):
        code = bytes.fromhex("31c9" "4189c9" "e30d" "e800000000" "59" "83c1f4" "6a2b" "51" "cb")
        return code + b"\xe9" + struct.pack("<i", real - (addr + 0x19))

    b[off(tramp1):off(tramp1) + 0x19] = tramp(tramp1, SYSCALL_ENTRY)
    b[off(tramp2):off(tramp2) + 0x19] = tramp(tramp2, UNIXCALL_ENTRY)
    struct.pack_into("<I", b, text_hdr + 8, tramp2 + 0x19 - base - text_va)
    for (at, nxt, _, _), tgt in ((LEA_SYSCALL, tramp1), (LEA_UNIXCALL, tramp2)):
        struct.pack_into("<i", b, off(at) + 3, tgt - nxt)
    open(dst, "wb").write(b)
    print("patched %s (trampolines at %x, %x)" % (dst, tramp1, tramp2))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
