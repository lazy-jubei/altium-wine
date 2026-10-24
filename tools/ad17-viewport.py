#!/usr/bin/env python3
# Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
"""Build a separate, reversible Altium module with faster AD17 viewport helpers.

Only SHA256-verified AD17.1 Core3D.dll and ADVPCB.DLL are accepted. No Altium code is distributed.
The replacement helpers are assembled from diagnostics/ad17-viewport-*.S.
"""
import argparse
import hashlib
from pathlib import Path
import struct

ORIGINAL_SHA256 = "a0054c1455e8f5b2bce0d456528239666849f424add3d6f0f0368c5e2d3a00d0"
BUCKET_SCAN = bytes.fromhex(
    "83ec30f30f7f0424f30f7f4c2410f30f7f5424208b1685d20f8eac00000081faffffff0f0f87a00000008b4e048d44d1"
    "f839c80f8291000000660f6e55fc660f70d20031c083fa0472358d1cc181e3ff0f000081fbe00f00007724f30f6f04c1"
    "f30f6f4cc1100fc6c188660f76c20f50d885db751a83c00483ea0475c8eb308b1cc13b5dfc740d31db404a75b8eb200f"
    "bcdb01d831dbf30f6f0424f30f6f4c2410f30f6f54242083c430e90000000031dbf30f6f0424f30f6f4c2410f30f6f54"
    "242083c430e900000000f30f6f0424f30f6f4c2410f30f6f54242083c4308b164a85d2e900000000"
)
BOUNDS = bytes.fromhex(
    "6083ec10f30f7f04248d481839d1760b8d4a0c39c10f87be00000089c6bb06000000"
    "8b0e89cf81e70000807f81ff0000807f0f84a100000085ff750c81e1ffff7f000f8591"
    "00000083c6044b75d489d6bb030000008b0e89cf81e70000807f81ff0000807f747285"
    "ff750881e1ffff7f00756683c6044b75dcf30f1000f30f5d02f30f1100f30f104004f3"
    "0f5d4204f30f114004f30f104008f30f5d4208f30f114008f30f10400cf30f5f02f30f"
    "11400cf30f104010f30f5f4204f30f114010f30f104014f30f5f4208f30f114014f30f"
    "6f042483c41061c3f30f6f042483c41061e900000000"
)
MOVE = bytes.fromhex(
    "6083ec10f30f7f042439d0746685c97e6239c2720889d329c339cb722a83f9107216f3"
    "0f6f00f30f7f0283c01083c21083e91083f91073ea85c974378a18881a40424975f7eb"
    "2c01c801ca83f910721683e81083ea10f30f6f00f30f7f0283e91083f91073ea85c974"
    "09484a8a18881a4975f7f30f6f042483c41061c3"
)

PCB_SHA256 = "c1c49db02ce723a69328f3c4decb9db6a5ab497d5bd89deace970ac283332f17"
GRID = bytes.fromhex(
    "6083ec30f30f7f0424f30f7f4c2410837dc0000f85e4000000817dc4000000800f85d700000066817dc8ff3f0f85cb00"
    "00008b4dd00b4dd40f85bf00000066f745d8ff7f0f85b3000000d97c24200fb74c242081e13f0c000083f93f0f859b00"
    "00000fae5c24248b4c242481e1807f000081f9801f00000f85800000000fb74c242081e10003000081f900010000746d"
    "660f6e8514ffffff8b55e00faf55200355282b5514899514ffffff89542444660f6eca660f62c1f30fe6c0f20f1145b8"
    "660f1745b085c97507660f5ac00f5ac0f30f7e4d14660f70c9e1f30fe6c9660f58c1660f5ac00f1300f30f6f0424f30f"
    "6f4c241083c43061e900000000f30f6f0424f30f6f4c241083c43061e900000000"
)
DISTANCE = bytes.fromhex(
    "6083ec40f30f7f0424f30f7f4c2410f30f7f5424208d590c39cb0f82890100008d701839c60f827e01000039c3760839"
    "ce0f87720100008d720c39d60f826701000039d3760839ce0f875b01000089c6bf060000008b1e81e3ffffff7f741e81"
    "e30000807f81fb0000800c0f823801000081fb0000807f0f832c01000083c6044f75d289d6bf03000000eb008b1e81e3"
    "ffffff7f741e81e30000807f81fb0000800c0f820101000081fb0000807f0f83f500000083c6044f75d2d97c24300fb7"
    "5c243081e33f0c000083fb3f0f85d70000000fae5c24348b5c243481e3807f000081fb801f00000f85bc0000000fb75c"
    "243081e30003000081fb000100000f84a5000000f30f7e00f30f7e0af30f7e500c0f5ac00f5ac90f5ad2660f5cc1660f"
    "5cca85db750e660f5ac00f5ac0660f5ac90f5ac9660f5fc8660fefc0660f5fc1660f5ac00f1301f30f104008f30f104a"
    "08f30f105014f30f5ac0f30f5ac9f30f5ad2f20f5cc1f20f5cca85db7510f20f5ac0f30f5ac0f20f5ac9f30f5ac9f20f"
    "5fc8660fefc0f20f5fc1f20f5ac0f30f114108f30f6f0424f30f6f4c2410f30f6f54242083c44061c3f30f6f0424f30f"
    "6f4c2410f30f6f54242083c44061e900000000"
)

HASH = bytes.fromhex(
    "6085c97434783489c78d580439c3722b89d601ce722539c6760439d3771d8b070fb61a01d889c3c1e30a01d889c3c1eb"
    "0631d8424975e9890761c361e900000000"
)

FRAMES = bytes.fromhex(
    "60e8000000005b81eb000000008b75fc8bbeec00000085ff7474837ffc02726e837ffc047768bd010000008b04af85c0"
    "740dc704af00000000508b10ff52088d04af506a088b86b4000000508b10ff92d801000085c0781b8b04af85c074146a"
    "01508b10ff521885c07808453b6ffc72baeb1b6a018d86ec0000008b93d86c5500b901000000e80000000083c404618b"
    "45fc31d28990f0000000e900000000"
)

ALLOCATOR = bytes.fromhex(
    "5181f9d0ffff7f771c83f90c7e0b83c10383e1f083c10ceb05b90c000000e80000000059c359e90000000083f9047707518b08890a59c35181f9d0ffff7f771c83f9047e0b83c10383e1f883c104eb05b904000000e80000000059c359e900000000"
)

GRID_BATCH = bytes.fromhex(
    "6081ecc0000000f30f7f0424f30f7f4c2410f30f7f542420f30f7f5c2430f30f7f642440f30f7f6c2450f30f7f742460"
    "f30f7f7c247085db0f88720300008b45ac85c00f886703000040898424a000000089d941898c24ac000000898c249c00"
    "0000f7e185d20f854403000085c00f883c03000089842490000000837ddc000f852b03000083bd0cffffff000f851e03"
    "0000837dc0000f8514030000817dc4000000800f850703000066817dc8ff3f0f85fb0200008b45d00b45d40f85ef0200"
    "0066f745d8ff7f0f85e3020000d9bc24800000000fb7842480000000253f0c000083f83f0f85c60200000fae9c248400"
    "00008b84248400000025807f00003d801f00000f85a70200000fb784248000000025000300003d000100000f848f0200"
    "008984248800000064a134000000898424a4000000e8000000005b8d83c502000050ff93f1ad7e118b9424a400000064"
    "89153400000085c00f845202000089c38b45fc85c00f84450200008b108d8be13f5000394a240f85340200008b78f485"
    "ff0f842902000089bc24980000008b178d8b459e5200394a300f85110200008d8be39e5200394a040f85020200008d8b"
    "ed9e5200394a080f85f3010000837ff81c0f85e90100008b8c2490000000394ffc0f82d90100008b47f485c00f84ce01"
    "00008984248c00000089c8ba1c000000f7e285d20f85b60100000384248c0000000f82a90100008d950cffffff8b45fc"
    "8b08ff51248b850cffffff3b8424980000000f85880100008b10ff52303b84248c0000000f857601000089c78b75ec2b"
    "751889b424940000008b55282b5514f30f7e5514660f70d2e1f30fe6d28b451c898424b0000000c78424b40000000000"
    "0000c78424b800000000000000c78424bc000000000080bff30f6f9c24b00000008b45e88b9c24880000008b8c24a000"
    "0000660f6ec6660f6eca660f62c1f30fe6c085db7507660f5ac00f5ac0660f58c2660f5ac00f1307f30f7f5f08894718"
    "03752c83c71c4975c9ff8c249c000000740c0355208bb42494000000ebadc78568ffffff00000000c7856cffffff0000"
    "0000c78570ffffff000080bf2b752c899514ffffff660f6ec6660f6eca660f62c1f30fe6c0f20f1145b8660f1745b08b"
    "8c2490000000894ddc49898c24d80000008b8c24ac000000894de08b8c24a0000000894de4c745a80000000083ef1c89"
    "bc24dc000000898424d4000000c78424d000000000000000f30f6f0424f30f6f4c2410f30f6f542420f30f6f5c2430f3"
    "0f6f642440f30f6f6c2450f30f6f742460f30f6f7c247081c4c000000061eb4af30f6f0424f30f6f4c2410f30f6f5424"
    "20f30f6f5c2430f30f6f642440f30f6f6c2450f30f6f742460f30f6f7c247081c4c00000006185db781043895da8c745"
    "e000000000e900000000e90000000043006f0072006500330044002e0064006c006c000000"
)


def align(value, boundary):
    return (value + boundary - 1) // boundary * boundary


def checksum(data, field):
    total = 0
    for i in range(0, len(data), 2):
        if field <= i < field + 4:
            continue
        total += int.from_bytes(data[i:i + 2], "little")
        total = (total & 0xffff) + (total >> 16)
    return ((total & 0xffff) + (total >> 16)) + len(data)


def patch(original, geometry_hash=False, frames_ahead=1, grid_batch=False, allocator_copies=False, bucket_lookups=False):
    digest = hashlib.sha256(original).hexdigest()
    if digest not in (ORIGINAL_SHA256, PCB_SHA256):
        raise ValueError("Unknown or already modified AD17 module; original left untouched")
    if frames_ahead not in (1, 2, 3):
        raise ValueError("Frames ahead must be 1, 2 or 3")
    if (geometry_hash or frames_ahead != 1) and digest != ORIGINAL_SHA256:
        raise ValueError("Hash and frame-query options apply only to Core3D.dll")
    if grid_batch and digest != PCB_SHA256:
        raise ValueError("Grid batching applies only to ADVPCB.DLL")
    if bucket_lookups and digest != PCB_SHA256:
        raise ValueError("Bucket lookups apply only to ADVPCB.DLL")
    data = bytearray(original)
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    count = struct.unpack_from("<H", data, pe + 6)[0]
    optional = pe + 24
    table = optional + struct.unpack_from("<H", data, pe + 20)[0]
    section_align, file_align = struct.unpack_from("<II", data, optional + 32)
    sections = []
    for i in range(count):
        virtual_size, va, size, raw = struct.unpack_from("<IIII", data, table + i * 40 + 8)
        sections.append((va, virtual_size, raw, size))

    def offset(rva):
        for va, _, raw, size in sections:
            if va <= rva < va + size:
                return raw + rva - va
        raise ValueError(f"RVA outside file: {rva:#x}")

    header = table + count * 40
    if header + 40 > min(raw for _, _, raw, size in sections if size):
        raise ValueError("No spare section header")
    new_va = align(max(va + max(size, vsize) for va, vsize, _, size in sections), section_align)
    new_raw = align(len(data), file_align)
    payload = bytearray()

    def append(code):
        start = align(len(payload), 16)
        payload.extend(bytes(start - len(payload)) + code)
        return start

    def branch(at, target, opcode=0xe9):
        if payload[at] != opcode:
            raise ValueError("Unexpected payload branch")
        struct.pack_into("<i", payload, at + 1, target - (new_va + at + 5))

    if digest == ORIGINAL_SHA256:
        bounds = append(BOUNDS)
        old_bounds = 0x4f52b0
        fallback = append(data[offset(old_bounds):offset(old_bounds) + 0x9c])
        # The copied fallback has six relative calls and no absolute relocations.
        for call in (0x16, 0x2d, 0x45, 0x5c, 0x74, 0x8c):
            if payload[fallback + call] != 0xe8:
                raise ValueError("Unexpected fallback call")
            rel = struct.unpack_from("<i", payload, fallback + call + 1)[0]
            target = old_bounds + call + 5 + rel
            struct.pack_into("<i", payload, fallback + call + 1,
                             target - (new_va + fallback + call + 5))
        branch(bounds + 0xe2, new_va + fallback)
        entries = ((old_bounds, new_va + bounds), (0x7274, new_va + append(MOVE)))
        if geometry_hash:
            entries = list(entries)
            for source in (0x4fd280, 0x4fd33c):
                helper = append(HASH)
                # Re-enter after the six-byte prologue for aliased/negative inputs.
                prologue = data[offset(source):offset(source) + 6]
                if prologue != bytes.fromhex("558bec83c4ec"):
                    raise ValueError("Unexpected hash prologue")
                fallback = append(prologue + b"\xe9" + bytes(4))
                branch(helper + len(HASH) - 5, new_va + fallback)
                branch(fallback + 6, source + 6)
                entries.append((source, new_va + helper))
        if frames_ahead >= 2:
            allocation = offset(0x55868a)
            initialization = offset(0x5586e6)
            if (data[allocation:allocation + 2] != b"\x6a\x01" or
                    data[initialization:initialization + 11] !=
                    bytes.fromhex("8b45fc33d28990f0000000")):
                raise ValueError("Unexpected frame-query constructor")
            helper = append(FRAMES)
            struct.pack_into("<I", payload, helper + 9, new_va + helper + 6)
            branch(helper + 0x86, 0xe5fc, opcode=0xe8)
            branch(helper + len(FRAMES) - 5, 0x5586f1)
            data[allocation + 1] = frames_ahead
            entries = list(entries) + [(0x5586e6, new_va + helper)]
    else:
        grid = append(GRID)
        old_grid, grid_size = 0xfd1110, 0x54
        fallback = append(data[offset(old_grid):offset(old_grid) + grid_size] + b"\xe9" + bytes(4))
        branch(grid + 0xf8, old_grid + grid_size)
        branch(grid + 0x10c, new_va + fallback)
        branch(fallback + grid_size, old_grid + grid_size)
        distance = append(DISTANCE)
        old_distance = 0x7529c8
        fallback = append(data[offset(old_distance):offset(old_distance) + 0xe9])
        branch(distance + len(DISTANCE) - 5, new_va + fallback)
        entries = ((old_grid, new_va + grid), (old_distance, new_va + distance),
                   (0x75f4, new_va + append(MOVE)))
        if grid_batch:
            if data[offset(0xfd10ae):offset(0xfd10ae) + 8] != bytes.fromhex("85db0f8c08010000"):
                raise ValueError("Unexpected grid-loop entry")
            batch = append(GRID_BATCH)
            # Resolve the verified Core3D getters through the existing GetModuleHandleW IAT.
            struct.pack_into("<i", payload, batch + 0x144,
                             0x27ec0d0 - (new_va + batch + 0x13a))
            branch(batch + 0x3f5, 0xfd10c1)
            branch(batch + 0x3fa, 0xfd11be)
            entries = list(entries) + [(0xfd10ae, new_va + batch)]
    if bucket_lookups:
        scan = append(BUCKET_SCAN)
        branch(scan + 0xaa, 0x696ff3)
        branch(scan + 0xc5, 0x697000)
        branch(scan + 0xe3, 0x696fe3)
        entries = list(entries) + [(0x696fde, new_va + scan)]
    if allocator_copies:
        is_core = digest == ORIGINAL_SHA256
        copy_entry = 0x7274 if is_core else 0x75f4
        copy_target = next(target for source, target in entries if source == copy_entry)
        long_entries = (0x53e0, 0x182c4, 0x19938) if is_core else (0x5760, 0x1d2a0, 0x1ec10)
        short_entry = 0x182f4 if is_core else 0x1d2d0
        long_original = data[offset(long_entries[0]):offset(long_entries[0]) + 0x2d]
        if (long_original[:9] != bytes.fromhex("83e90c01c801caf7d9") or
                any(data[offset(at):offset(at) + 0x2d] != long_original for at in long_entries) or
                data[offset(short_entry):offset(short_entry) + 5] != bytes.fromhex("83e9047e18")):
            raise ValueError("Unexpected allocator copy helpers")
        helper = append(ALLOCATOR)
        long_fallback = append(long_original)
        short_fallback = append(data[offset(short_entry):offset(short_entry) + 0x22])
        branch(helper + 0x1e, copy_target, opcode=0xe8)
        branch(helper + 0x55, copy_target, opcode=0xe8)
        branch(helper + 0x26, new_va + long_fallback)
        branch(helper + 0x5d, new_va + short_fallback)
        entries = list(entries) + [(at, new_va + helper) for at in long_entries]
        entries.append((short_entry, new_va + helper + 0x2b))
    for source, target in entries:
        at = offset(source)
        data[at:at + 5] = b"\xe9" + struct.pack("<i", target - source - 5)
    # Entry patches and all new instructions are position independent.
    # Existing relocations and the original exceptional-case fallback remain intact.
    size = align(len(payload), file_align)
    struct.pack_into("<8sIIIIIIHHI", data, header, b".ad17fp", len(payload), new_va,
                     size, new_raw, 0, 0, 0, 0, 0x60000020)
    struct.pack_into("<H", data, pe + 6, count + 1)
    struct.pack_into("<I", data, optional + 4, struct.unpack_from("<I", data, optional + 4)[0] + size)
    struct.pack_into("<I", data, optional + 56, align(new_va + len(payload), section_align))
    data.extend(bytes(new_raw - len(data)) + payload + bytes(size - len(payload)))
    struct.pack_into("<I", data, optional + 64, checksum(data, optional + 64))
    return bytes(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("original", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--geometry-hash", action="store_true",
                        help="Experimental faster, bit-exact Core3D geometry hashing")
    parser.add_argument("--frames-ahead", type=int, choices=(1, 2, 3), default=1,
                        help="Core3D GPU frame-query ring length (2 or 3 allow more CPU/GPU overlap)")
    parser.add_argument("--grid-batch", action="store_true",
                        help="Build verified zero-angle grids with one buffer lookup per batch")
    parser.add_argument("--allocator-copies", action="store_true",
                        help="Use SSE copies for the allocator's rounded buffer moves")
    parser.add_argument("--bucket-lookups", action="store_true",
                        help="Compare four geometry-cache keys per SSE2 lookup")
    args = parser.parse_args()
    if args.output.exists() or args.original.resolve() == args.output.resolve():
        parser.error("Output must be a new, separate file")
    created = False
    try:
        result = patch(args.original.read_bytes(), geometry_hash=args.geometry_hash,
                       frames_ahead=args.frames_ahead, grid_batch=args.grid_batch,
                       allocator_copies=args.allocator_copies, bucket_lookups=args.bucket_lookups)
        with args.output.open("xb") as stream:
            created = True
            stream.write(result)
    except (OSError, ValueError) as exc:
        if created:
            try:
                args.output.unlink()
            except OSError:
                pass
        parser.error(str(exc))
    print(f"{hashlib.sha256(result).hexdigest()}  {args.output}")


if __name__ == "__main__":
    main()
