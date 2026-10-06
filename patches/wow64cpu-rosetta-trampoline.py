#!/usr/bin/env python3
"""Binary-patch wow64cpu.dll (Wine 11.16 staging, x86_64-windows) to work around a
Rosetta 2 bug on Apple Silicon: far transfers between 32- and 64-bit code sometimes don't
switch the CPU mode. It shows up after an app writes code into a page that already ran
(Delphi MakeObjectInstance), i.e. after Rosetta retranslates, and under heavy syscall load.

1. 32->64 (the Altium installer). Symptom: "exception outside of stack limits" at
   wow64cpu+0x1135 (or +0x1239): the far jump in the syscall/unix-call thunks lands in
   64-bit code while the CPU is still in 32-bit mode.
   Fix: point both thunks at mode-detecting trampolines placed in .text padding. The same
   bytes decode differently in each mode:
       31 c9        xor ecx,ecx
       41 89 c9     32-bit: inc ecx; mov ecx,ecx   64-bit: mov r9d,ecx
       e3 0d        jecxz/jrcxz -> 64-bit path
       e8 00000000  59  83 c1 f4   (32-bit) ecx = trampoline address
       6a 2b 51 cb  push 0x2b; push ecx; retf  -> retry the switch into 64-bit mode
       e9 rel32     (64-bit) jmp to the real wow64cpu entry
   ecx/r9/flags are volatile at these entry points.

2. 64->32 (Altium Designer 17's DXP.EXE, which walks the global atom table with ~16k
   syscalls at startup). Symptom: "Exception frame is not in stack limits", with a fault
   at an address whose low half is a 32-bit return address: the `ljmp` back to 32-bit code
   after a syscall/unix call stayed in 64-bit mode, and the first 32-bit `ret` popped 8 bytes.
   Fix: both return sites now build an iretq frame (eip, cs32, rflags, esp, ss) on the
   64-bit stack and return with iretq, the way wow64cpu's full-context return already does,
   instead of `ljmp`. (A mode-detecting 32-bit landing pad doesn't work: Rosetta faults on a
   far transfer into 32-bit mode at a page that also holds 64-bit code.) edx is volatile on
   the 32-bit side and wow64cpu already used it as scratch here.

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
# The two returns to 32-bit code: mov r14d,[r13+0xc4]; xchg r14,rsp; ljmp [r14]
RETURN_SITES = (0x7a4011a2, 0x7a40128b)
RETURN_BYTES = bytes.fromhex("458bb5c4000000" "4987e6" "41ff2e")


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
    ret1 = tramp1 + 0x40       # 64-bit stubs replacing the two return sequences
    ret2 = tramp1 + 0x80
    end = ret2 + 0x40
    if end - base - text_va > text_rs:
        raise SystemExit("no room in .text padding")
    if any(x not in (0, 0xCC) for x in b[off(tramp1):off(tramp1) + (end - tramp1)]):
        raise SystemExit("padding not empty; already patched or different build")

    for at, nxt, opc, disp in (LEA_SYSCALL, LEA_UNIXCALL):
        o = off(at)
        if bytes(b[o:o + 3]) != opc or struct.unpack_from("<i", b, o + 3)[0] != disp:
            raise SystemExit("unexpected bytes at %x; not the 11.16 build" % at)
    for at in RETURN_SITES:
        if bytes(b[off(at):off(at) + len(RETURN_BYTES)]) != RETURN_BYTES:
            raise SystemExit("unexpected bytes at %x; not the 11.16 build" % at)

    def put(addr, code):
        b[off(addr):off(addr) + len(code)] = code

    # 1. 32->64 entry trampolines
    def tramp(addr, real):
        code = bytes.fromhex("31c9" "4189c9" "e30d" "e800000000" "59" "83c1f4" "6a2b" "51" "cb")
        return code + b"\xe9" + struct.pack("<i", real - (addr + 0x19))

    put(tramp1, tramp(tramp1, SYSCALL_ENTRY))
    put(tramp2, tramp(tramp2, UNIXCALL_ENTRY))
    for (at, nxt, _, _), tgt in ((LEA_SYSCALL, tramp1), (LEA_UNIXCALL, tramp2)):
        struct.pack_into("<i", b, off(at) + 3, tgt - nxt)

    # 2. 64->32 returns: [rsp] holds eip and [rsp+4] cs32 already; 0x28 bytes from rsp are
    # free (the full-context path builds its iretq frame at the same place).
    stub = bytes.fromhex(
        "4989e6"            # mov r14,rsp            64-bit stack for the next entry's xchg
        "8b1424"            # mov edx,[rsp]          eip
        "48891424"          # mov [rsp],rdx
        "418b95bc000000"    # mov edx,[r13+0xbc]     cs32
        "4889542408"        # mov [rsp+8],rdx
        "9c" "5a"           # pushfq; pop rdx
        "4889542410"        # mov [rsp+16],rdx       rflags
        "418b95c4000000"    # mov edx,[r13+0xc4]     esp
        "4889542418"        # mov [rsp+24],rdx
        "418b95c8000000"    # mov edx,[r13+0xc8]     ss
        "4889542420"        # mov [rsp+32],rdx
        "48cf")             # iretq
    assert len(stub) <= 0x40
    put(ret1, stub)
    put(ret2, stub)
    for at, tgt in zip(RETURN_SITES, (ret1, ret2)):
        put(at, b"\xe9" + struct.pack("<i", tgt - (at + 5)) + b"\xcc" * (len(RETURN_BYTES) - 5))

    struct.pack_into("<I", b, text_hdr + 8, ret2 + len(stub) - base - text_va)
    open(dst, "wb").write(b)
    print("patched %s (entry trampolines at %x, %x; iretq return stubs at %x, %x)"
          % (dst, tramp1, tramp2, ret1, ret2))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
