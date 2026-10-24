/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build with i686-w64-mingw32-clang -O2; pass a --frames-ahead 2 Core3D DLL.
 * Runs the actual patched payload in an isolated mock module. No Altium startup.
 */
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct query { void **vtable; unsigned refs, issues, releases; };
struct array { unsigned refs, count; struct query *items[2]; };
static struct query first, second, previous;
static struct array storage;
static void *device_vtable[119], *query_vtable[8], *device = device_vtable;
static unsigned mode, creates, resizes;
static int failures;
#define VERIFY(x) do { if (!(x)) { printf("FAIL line %d mode %u\n", __LINE__, mode); failures++; } } while (0)

static HRESULT WINAPI issue(struct query *q, DWORD flags)
{
    VERIFY(q == &second && q->refs == 1 && flags == 1);
    q->issues++;
    return mode == 4 ? E_FAIL : mode == 5 ? S_FALSE : S_OK;
}

static ULONG WINAPI release(struct query *q)
{
    VERIFY((q == &second || q == &previous) && q->refs == 1);
    q->releases++;
    return --q->refs;
}

static HRESULT WINAPI create(void *dev, DWORD type, struct query **out)
{
    VERIFY(dev == &device && type == 8 && !*out);
    creates++;
    if (mode != 1 && mode != 2) {
        *out = &second;
        second.refs = 1;
    }
    return mode == 1 || mode == 3 ? E_FAIL : mode == 5 ? S_FALSE : S_OK;
}

/* Delphi register ABI: EAX field, EDX typeinfo, ECX dimensions, stack length. */
__attribute__((regparm(3), noinline))
static void resize(struct query ***field, void *type, unsigned dimensions, unsigned count)
{
    VERIFY(*field == storage.items && type == (void *)0x12345678);
    VERIFY(dimensions == 1 && count == 1 && storage.count == 2);
    if (storage.items[1]) release(storage.items[1]);
    storage.items[1] = NULL;
    storage.count = count;
    resizes++;
}

/* Give the payload its real caller's [EBP-4] object local and capture all GPRs. */
__attribute__((naked)) static void invoke(void *code, void *object, DWORD *registers)
{
    __asm__ volatile(
        "pushl %ebp; movl %esp,%ebp; subl $4,%esp; pushl %ebx; pushl %esi; pushl %edi;"
        "movl 12(%ebp),%eax; movl %eax,-4(%ebp);"
        "movl $0x11223344,%ebx; movl $0x22334455,%esi; movl $0x33445566,%edi;"
        "movl $0x44556677,%ecx; movl $0x55667788,%edx;"
        "call *8(%ebp); pushfl; pushal;"
        "movl 16(%ebp),%edi; movl %esp,%esi; movl $9,%ecx; cld; rep movsl;"
        "popal; popfl; popl %edi; popl %esi; popl %ebx; movl %ebp,%esp; popl %ebp; ret");
}

int main(int argc, char **argv)
{
    if (argc != 2) return 1;
    HMODULE module = LoadLibraryExA(argv[1], NULL, DONT_RESOLVE_DLL_REFERENCES);
    if (!module) return 1;
    BYTE *original = (BYTE *)module, *entry = original + 0x5586e6;
    if (*entry != 0xe9 || original[0x55868b] != 2) return 2;
    DWORD helper = 0x5586e6 + 5 + *(int32_t *)(entry + 1);
    DWORD bytes = helper + 4096;
    BYTE *mock = VirtualAlloc(NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE);
    if (!mock) return 1;
    memcpy(mock + helper, original + helper, 0x8c);
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
    for (unsigned repeat = 0; repeat < 2000; repeat++) {
        for (mode = 0; mode < 9; mode++) {
            memset(object, 0, sizeof(object));
            first = (struct query){query_vtable, 1, 0, 0};
            second = (struct query){query_vtable, 0, 0, 0};
            previous = (struct query){query_vtable, 1, 0, 0};
            storage = (struct array){1, mode == 7 ? 1 : 2, {&first, NULL}};
            if (mode == 8) storage.items[1] = &previous;
            *(void **)(object + 0xb4) = &device;
            *(void **)(object + 0xec) = mode == 6 ? NULL : storage.items;
            *(DWORD *)(object + 0xf0) = 0xdeadbeef;
            creates = resizes = 0;
            DWORD regs[9];
            invoke(mock + helper, object, regs);
            VERIFY(regs[0] == 0x33445566 && regs[1] == 0x22334455);
            VERIFY(regs[4] == 0x11223344 && regs[5] == 0 && regs[6] == 0x44556677);
            VERIFY(regs[7] == (DWORD)(uintptr_t)object && (regs[8] & 0x8c5) == 0x44);
            VERIFY(*(DWORD *)(object + 0xf0) == 0 && storage.items[0] == &first);
            VERIFY(first.refs == 1 && first.releases == 0 && first.issues == 0);
            unsigned active = mode < 6 || mode == 8, failed = mode >= 1 && mode <= 4;
            VERIFY(creates == active && resizes == failed);
            VERIFY(storage.count == (mode == 7 || failed ? 1 : 2));
            VERIFY(second.issues == (mode == 0 || mode == 4 || mode == 5 || mode == 8));
            VERIFY(second.releases == (mode == 3 || mode == 4));
            VERIFY(second.refs == (mode == 0 || mode == 5 || mode == 8));
            VERIFY(previous.releases == (mode == 8) && previous.refs == (mode != 8));
            if (second.refs) release(&second);
            checks++;
        }
    }
    VirtualFree(mock, 0, MEM_RELEASE);
    FreeLibrary(module);
    printf("%s %u frame-query success/failure, ownership, ABI and register checks\n",
           failures ? "FAIL" : "PASS", checks);
    return failures ? 3 : 0;
}
