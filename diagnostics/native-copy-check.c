/* Verify the actual driver's native client against its arm64 worker. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
static char native_worker_path[PATH_MAX];
#include "native_gdi_client.h"

int main(int argc, char **argv)
{
    enum { width = 2049, height = 700, stride = 12800 };
    size_t size = (stride * height + 32767) & ~(size_t)16383;
    mach_vm_address_t address[2] = {0};
    unsigned char *expected = malloc(size), *pixels[2];
    int i, y, reverse, source;

    if (argc != 2 || !expected || strlen(argv[1]) >= sizeof(native_worker_path)) return 2;
    strcpy(native_worker_path, argv[1]);
    for (i = 0; i < 2; ++i)
    {
        if (mach_vm_allocate(mach_task_self(), &address[i], size, VM_FLAGS_ANYWHERE)) return 3;
        pixels[i] = (void *)address[i];
    }
    /* Reverse source/destination roles while their cached mappings remain live.
     * A source initially mapped read-only must acquire write access. */
    for (source = 0; source < 2; ++source)
        for (reverse = 0; reverse < 2; ++reverse)
        {
            unsigned char *s = pixels[source], *d = pixels[1 - source];
            int step = reverse ? -stride : stride;
            for (size_t n = 0; n < size; ++n) s[n] = n * 17 ^ (n >> 9);
            memset(d, 121, size);
            memcpy(expected, d, size);
            if (reverse) { s += (height - 1) * stride; d += (height - 1) * stride; }
            for (y = 0; y < height; ++y)
                memcpy(expected + (d - pixels[1 - source]) + (int64_t)y * step,
                       s + (int64_t)y * step, width * 4);
            if (!arm_copy(d, s, step, step, width, height, 0, 2, NULL) ||
                memcmp(expected, pixels[1 - source], size)) return 4;
        }
    /* Reusing an address for a new allocation must not reuse the old VM object. */
    mach_vm_deallocate(mach_task_self(), address[0], size);
    if (mach_vm_allocate(mach_task_self(), &address[0], size, VM_FLAGS_FIXED)) return 5;
    memset((void *)address[0], 42, size);
    if (!arm_copy(pixels[1], (void *)address[0], stride, stride, width, height, 0, 2, NULL) ||
        pixels[1][0] != 42 || pixels[1][(height - 1) * stride] != 42) return 6;
    altium_native_shutdown();
    for (i = 0; i < 2; ++i) mach_vm_deallocate(mach_task_self(), address[i], size);
    free(expected);
    puts("PASS native copies, padding, both orientations, reversed roles and remapped allocations");
    return 0;
}
