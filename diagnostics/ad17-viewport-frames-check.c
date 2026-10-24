/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build with i686-w64-mingw32-clang -O2; pass a --frames-ahead 2 Core3D DLL.
 * Runs the actual patched payload in an isolated mock module. No Altium
 * startup.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct query {
  void **vtable;
  unsigned refs, issues, releases;
};
struct array {
  unsigned refs, count;
  struct query *items[4];
};
static struct query first, q[3], previous[3];
static struct array storage;
static void *device_vtable[119], *query_vtable[8], *device = device_vtable;
static unsigned mode, creates, resizes, fail_at, depth;
static int failures;
#define VERIFY(x)                                                              \
  do {                                                                         \
    if (!(x)) {                                                                \
      printf("FAIL line %d mode%u depth%u fail%u\n", __LINE__, mode, depth,    \
             fail_at);                                                         \
      failures++;                                                              \
      if (failures > 10)                                                       \
        return 3;                                                              \
    }                                                                          \
  } while (0)
static HRESULT WINAPI issue(struct query *obj, DWORD flags) {
  if (obj < q || obj >= q + 3 || obj->refs != 1 || flags != 1) {
    failures++;
    return E_FAIL;
  }
  obj->issues++;
  return (unsigned)(obj - q) + 1 == fail_at && mode == 4 ? E_FAIL
         : mode == 5                                     ? S_FALSE
                                                         : S_OK;
}
static ULONG WINAPI release(struct query *obj) {
  if (!obj->refs) {
    failures++;
    return 0;
  }
  obj->releases++;
  return --obj->refs;
}
static HRESULT WINAPI create(void *dev, DWORD type, struct query **out) {
  if (dev != &device || type != 8 || *out) {
    failures++;
    return E_FAIL;
  }
  unsigned index = creates++;
  int selected = index + 1 == fail_at;
  if (!selected || (mode != 1 && mode != 2)) {
    *out = &q[index];
    q[index].refs = 1;
  }
  return selected && (mode == 1 || mode == 3) ? E_FAIL
         : mode == 5                          ? S_FALSE
                                              : S_OK;
}
__attribute__((regparm(3), noinline)) static void
resize(struct query ***field, void *type, unsigned dims, unsigned count) {
  if (*field != storage.items || type != (void *)0x12345678 || dims != 1 ||
      count != 1) {
    failures++;
    return;
  }
  for (unsigned i = 1; i < storage.count; i++) {
    if (storage.items[i])
      release(storage.items[i]);
    storage.items[i] = NULL;
  }
  storage.count = count;
  resizes++;
}
/* Give the payload its real caller's [EBP-4] object local and capture all GPRs.
 */
__attribute__((naked)) static void invoke(void *code, void *object,
                                          DWORD *registers) {
  __asm__ volatile(
      "pushl %ebp; movl %esp,%ebp; subl $4,%esp; pushl %ebx; pushl %esi; pushl "
      "%edi;"
      "movl 12(%ebp),%eax; movl %eax,-4(%ebp);"
      "movl $0x11223344,%ebx; movl $0x22334455,%esi; movl $0x33445566,%edi;"
      "movl $0x44556677,%ecx; movl $0x55667788,%edx;"
      "call *8(%ebp); pushfl; pushal;"
      "movl 16(%ebp),%edi; movl %esp,%esi; movl $9,%ecx; cld; rep movsl;"
      "popal; popfl; popl %edi; popl %esi; popl %ebx; movl %ebp,%esp; popl "
      "%ebp; ret");
}

int main(int argc, char **argv) {
  if (argc < 2 || argc > 3)
    return 1;
  depth = argc > 2 ? atoi(argv[2]) : 2;
  if (depth < 2 || depth > 3)
    return 1;
  HMODULE module = LoadLibraryExA(argv[1], NULL, DONT_RESOLVE_DLL_REFERENCES);
  if (!module)
    return 1;
  BYTE *original = (BYTE *)module, *entry = original + 0x5586e6;
  if (*entry != 0xe9 || original[0x55868b] != depth)
    return 2;
  DWORD helper = 0x5586e6 + 5 + *(int32_t *)(entry + 1);
  DWORD bytes = helper + 4096;
  BYTE *mock = VirtualAlloc(NULL, bytes, MEM_COMMIT | MEM_RESERVE,
                            PAGE_EXECUTE_READWRITE);
  if (!mock)
    return 1;
  memcpy(mock + helper, original + helper, 159);
  *(void **)(mock + 0x556cd8) = (void *)0x12345678;
  mock[0xe5fc] = 0xe9;
  *(int32_t *)(mock + 0xe5fd) = (BYTE *)resize - (mock + 0xe601);
  mock[0x5586f1] = 0xc3;
  FlushInstructionCache(GetCurrentProcess(), mock, bytes);
  device_vtable[118] = create;
  query_vtable[2] = release;
  query_vtable[6] = issue;
  BYTE object[0xf4];
  unsigned checks = 0;
  for (unsigned repeat = 0; repeat < 300; repeat++)
    for (unsigned reinit = 0; reinit < 2; reinit++)
      for (fail_at = 1; fail_at < depth; fail_at++)
        for (mode = 0; mode < 9; mode++) {
          memset(object, 0, sizeof(object));
          first = (struct query){query_vtable, 1, 0, 0};
          storage = (struct array){
              1, mode == 7 ? 1 : depth, {&first, NULL, NULL, NULL}};
          for (unsigned i = 0; i < 3; i++) {
            q[i] = (struct query){query_vtable, 0, 0, 0};
            previous[i] = (struct query){query_vtable,
                                         reinit && i + 1 < storage.count, 0, 0};
            if (previous[i].refs)
              storage.items[i + 1] = &previous[i];
          }
          *(void **)(object + 0xb4) = &device;
          *(void **)(object + 0xec) = mode == 6 ? NULL : storage.items;
          *(DWORD *)(object + 0xf0) = 0xdeadbeef;
          creates = resizes = 0;
          DWORD regs[9];
          invoke(mock + helper, object, regs);
          VERIFY(regs[0] == 0x33445566 && regs[1] == 0x22334455 &&
                 regs[4] == 0x11223344 && regs[5] == 0 &&
                 regs[6] == 0x44556677 && regs[7] == (DWORD)(uintptr_t)object &&
                 (regs[8] & 0x8c5) == 0x44);
          unsigned active = mode < 6 || mode == 8,
                   failed = mode >= 1 && mode <= 4;
          VERIFY(*(DWORD *)(object + 0xf0) == 0 && first.refs == 1 &&
                 first.releases == 0 && first.issues == 0);
          VERIFY(creates == (active ? (failed ? fail_at : depth - 1) : 0) &&
                 resizes == failed);
          VERIFY(storage.count == (mode == 7 || failed ? 1 : depth));
          for (unsigned i = 0; i < depth - 1; i++) {
            unsigned made =
                active && (!failed || i + 1 < fail_at ||
                           (i + 1 == fail_at && (mode == 3 || mode == 4)));
            unsigned issued = active && (!failed || i + 1 < fail_at ||
                                         (i + 1 == fail_at && mode == 4));
            VERIFY(q[i].issues == issued && q[i].releases == (made && failed) &&
                   q[i].refs == (made && !failed));
            VERIFY(previous[i].releases == (reinit && active) &&
                   previous[i].refs == (reinit && !active && mode != 7));
            if (q[i].refs)
              release(&q[i]);
            if (previous[i].refs)
              release(&previous[i]);
          }
          checks++;
        }
  VirtualFree(mock, 0, MEM_RELEASE);
  FreeLibrary(module);
  printf(
      "%s %u frame-query success/failure, ownership, ABI and register checks\n",
      failures ? "FAIL" : "PASS", checks);
  return failures ? 3 : 0;
}
