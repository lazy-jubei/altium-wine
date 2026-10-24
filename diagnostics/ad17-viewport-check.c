/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build: i686-w64-mingw32-clang -O2 ad17-viewport-check.c -o check.exe
 * Run:   wine check.exe ORIGINAL_CORE3D_DLL PATCHED_CORE3D_DLL
 * Maps both modules without running Altium initialization or resolving imports.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <xmmintrin.h>

typedef void (__attribute__((regparm(3))) *bounds_fn)(float *, const float *);
typedef void (__attribute__((regparm(3))) *move_fn)(const void *, void *, int);

static uint32_t random_bits(uint32_t *state)
{
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return *state;
}

int main(int argc, char **argv)
{
    HMODULE original, patched;
    bounds_fn old_bounds, new_bounds;
    move_fn old_move, new_move;
    uint32_t seed = 42;
    unsigned comparisons = 0, copies = 0, saved_mxcsr = _mm_getcsr();
    unsigned char before[4096], after[4096];
    const uint32_t cases[] = {
        0, 0x80000000, 1, 0x80000001, 0x007fffff, 0x807fffff,
        0x00800000, 0x80800000, 0x3f800000, 0xbf800000, 0x7f7fffff,
        0xff7fffff, 0x7f800000, 0xff800000, 0x7fc00000, 0xffc00000,
        0x7f800001, 0xff800001
    };

    if (argc != 3) return 1;
    original = LoadLibraryExA(argv[1], NULL, DONT_RESOLVE_DLL_REFERENCES);
    patched = LoadLibraryExA(argv[2], NULL, DONT_RESOLVE_DLL_REFERENCES);
    if (!original || !patched || original == patched) {
        printf("Cannot map separate modules: %lu\n", GetLastError());
        return 1;
    }
    old_bounds = (bounds_fn)((char *)original + 0x4f52b0);
    new_bounds = (bounds_fn)((char *)patched + 0x4f52b0);
    old_move = (move_fn)((char *)original + 0x7274);
    new_move = (move_fn)((char *)patched + 0x7274);

    for (int flags = 0; flags < 4; flags++) {
        _mm_setcsr(0x1f80 | (flags & 1 ? 0x40 : 0) | (flags & 2 ? 0x8000 : 0));
        for (int alias = -1; alias < 6; alias++) {
            for (int i = 0; i < 100000; i++) {
                union { uint32_t bits[12]; float values[12]; } a, b;
                for (int j = 0; j < 12; j++)
                    a.bits[j] = i < 18 ? cases[(i + j) % 18] : random_bits(&seed);
                b = a;
                old_bounds(a.values, a.values + (alias < 0 ? 8 : alias));
                new_bounds(b.values, b.values + (alias < 0 ? 8 : alias));
                if (memcmp(&a, &b, sizeof(a))) {
                    printf("FAIL bounds: MXCSR mode %d, overlap %d, case %d\n", flags, alias, i);
                    return 2;
                }
                comparisons++;
            }
        }
    }
    _mm_setcsr(saved_mxcsr);
    printf("PASS %u bit-exact bounds comparisons, overlaps and MXCSR modes\n", comparisons);

    const int negative[] = {-1, -8, -1024, INT32_MIN};
    for (unsigned i = 0; i < sizeof(negative) / sizeof(*negative); i++) {
        old_move(NULL, (void *)1, negative[i]);
        new_move(NULL, (void *)1, negative[i]);
        copies++;
    }
    for (int size = 0; size <= 1024; size++) {
        for (int shift = -33; shift <= 33; shift++) {
            for (int i = 0; i < 4096; i++) before[i] = after[i] = (i * 53 + size) & 255;
            old_move(before + 512, before + 512 + shift, size);
            new_move(after + 512, after + 512 + shift, size);
            if (memcmp(before, after, sizeof(before))) {
                printf("FAIL Move: size %d, overlap %d\n", size, shift);
                return 3;
            }
            copies++;
        }
    }
    for (int size = 1; size <= 256; size++) {
        for (int alignment = 0; alignment < 16; alignment++) {
            SYSTEM_INFO info;
            DWORD protection;
            unsigned char *pages, *src, *dst;
            GetSystemInfo(&info);
            pages = VirtualAlloc(NULL, info.dwPageSize * 3, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
            if (!pages || !VirtualProtect(pages + info.dwPageSize, info.dwPageSize,
                                          PAGE_NOACCESS, &protection)) return 4;
            src = pages + info.dwPageSize - size;
            dst = pages + info.dwPageSize * 2 + alignment;
            for (int i = 0; i < size; i++) src[i] = (i * 19) & 255;
            new_move(src, dst, size);
            if (memcmp(src, dst, size)) return 4;
            VirtualFree(pages, 0, MEM_RELEASE);
            copies++;
        }
    }
    printf("PASS %u overlap, alignment, padding and guard-page copies\n", copies);
    FreeLibrary(patched);
    FreeLibrary(original);
    return 0;
}
