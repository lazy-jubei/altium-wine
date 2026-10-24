/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
struct entry {
  uint32_t key, value;
};
struct bucket {
  int count;
  struct entry *data;
};
struct map {
  void **v;
  uint32_t unused;
  struct bucket *b;
};
typedef unsigned(__attribute__((regparm(3), stdcall)) *
                 lookup)(struct map *, uint32_t, int *, int *);
__attribute__((naked, regparm(2))) static unsigned get_bucket(struct map *m,
                                                              uint32_t key) {
  __asm__ volatile("movl %edx,%eax;andl $3,%eax;ret");
}
static uint32_t seed = 42;
static uint32_t rnd(void) {
  seed ^= seed << 13;
  seed ^= seed >> 17;
  seed ^= seed << 5;
  return seed;
}
int main(int argc, char **argv) {
  if (argc != 3)
    return 1;
  HMODULE a = LoadLibraryExA(argv[1], NULL, DONT_RESOLVE_DLL_REFERENCES),
          b = LoadLibraryExA(argv[2], NULL, DONT_RESOLVE_DLL_REFERENCES);
  if (!a || !b)
    return 2;
  lookup original = (lookup)((BYTE *)a + 0x696fb8),
         fast = (lookup)((BYTE *)b + 0x696fb8);
  void *v[14] = {0};
  v[13] = get_bucket;
  struct bucket bucket[4];
  struct map map = {v, 0, bucket};
  unsigned cases = 0;
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  unsigned page = si.dwPageSize;
  BYTE *mem =
      VirtualAlloc(NULL, 4 * page, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  DWORD prot;
  if (!mem || !VirtualProtect(mem + 3 * page, page, PAGE_NOACCESS, &prot))
    return 3;
  for (unsigned n = 0; n <= 1024; n++)
    for (unsigned align = 0; align < 8; align++)
      for (unsigned which = 0; which < 8; which++) {
        struct entry *data = (struct entry *)(mem + 3 * page - n * 8 - align);
        for (unsigned i = 0; i < n; i++) {
          data[i].key = rnd() % 97;
          data[i].value = rnd();
        }
        uint32_t key = which < 6 && n ? data[(which == 0   ? 0
                                              : which == 1 ? n - 1
                                                           : rnd() % n)]
                                            .key
                                      : rnd();
        for (int i = 0; i < 4; i++)
          bucket[i] = (struct bucket){n, data};
        int a0 = -1, a1 = -2, b0 = -1, b1 = -2;
        unsigned x = original(&map, key, &a0, &a1),
                 y = fast(&map, key, &b0, &b1);
        if (x != y || a0 != b0 || a1 != b1) {
          printf(
              "FAIL n%u align%u mode%u key%08x ret%u/%u idx%d/%d bucket%d/%d\n",
              n, align, which, key, x, y, a1, b1, a0, b0);
          return 4;
        }
        cases++;
      }
  for (unsigned n = 0; n < 1024; n++) {
    struct entry *data = (struct entry *)(mem + 2 * page - n * 8);
    for (unsigned i = 0; i < n; i++) {
      data[i].key = 7;
      data[i].value = i;
    }
    for (int i = 0; i < 4; i++)
      bucket[i] = (struct bucket){n, data};
    int aa = -1, bb = -1;
    unsigned x = original(&map, 7, &aa, &aa), y = fast(&map, 7, &bb, &bb);
    if (x != y || aa != bb)
      return 5;
    cases++;
  }
  printf("PASS %u guarded bucket lookups: alignments, duplicates, first match, "
         "misses, empty and output aliases\n",
         cases);
  fflush(stdout);
  struct entry *data = (struct entry *)mem;
  for (int i = 0; i < 512; i++)
    data[i] = (struct entry){i, 0};
  for (int i = 0; i < 4; i++)
    bucket[i] = (struct bucket){512, data};
  LARGE_INTEGER f, t0, t1;
  QueryPerformanceFrequency(&f);
  for (int k = 0; k < 2; k++) {
    lookup fn = k ? fast : original;
    int out1, out2;
    QueryPerformanceCounter(&t0);
    for (int i = 0; i < 500000; i++)
      fn(&map, 511, &out1, &out2);
    QueryPerformanceCounter(&t1);
    printf("%s ms%.3f\n", k ? "SIMD" : "original",
           1000. * (t1.QuadPart - t0.QuadPart) / f.QuadPart);
    fflush(stdout);
  }
  return 0;
}
