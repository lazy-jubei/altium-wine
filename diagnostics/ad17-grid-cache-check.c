/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Build with tools/ad17-grid-cache.S and -ld3dx9 -ld3d9.
 * Check the integer-to-float guard used before GPU grid translations.
 */
#include "../tools/ad17-grid-cache.c"
#include <stdio.h>
static uint32_t rng = 42;
static uint32_t random_word(void) {
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return rng;
}
int main(void) {
  unsigned accepted = 0, rejected = 0;
  for (unsigned i = 0; i < 200000; i++) {
    int origin = (int)random_word();
    int start = (int)random_word();
    int step = 1 + random_word() % 100000;
    int n = 1 + random_word() % 256;
    int shift = (int)(random_word() % 2000001) - 1000000;
    int64_t end = (int64_t)start + (int64_t)step * (n - 1);
    if (end > INT32_MAX || (int64_t)start + shift < INT32_MIN ||
        end + shift > INT32_MAX)
      continue;
    if (!exact_axis(start, end, origin, step) ||
        !exact_axis(start + shift, end + shift, origin, step) ||
        !exact_axis(shift, shift, 0, 0)) {
      rejected++;
      continue;
    }
    for (int j = 0; j < n; j++) {
      int64_t local = (int64_t)start + (int64_t)step * j - origin;
      volatile float a = (float)local, delta = (float)shift;
      volatile float gpu = a + delta, original = (float)(local + shift);
      if (memcmp((const void *)&gpu, (const void *)&original, sizeof(float)))
        return 1;
      accepted++;
    }
  }
  unsigned rounded = 0;
  for (unsigned i = 0; i < 500000; i++) {
    int value = (int)(random_word() % 0x10000001) - 0x8000000;
    int shift = ((int)(random_word() % 100001) - 50000) * 32;
    if (!shift_in_band((int)(float)value, (int)(float)value, shift))
      continue;
    volatile float cached = (float)value, delta = (float)shift;
    volatile float gpu = cached + delta,
                   original = (float)((int64_t)value + shift);
    if (memcmp((const void *)&gpu, (const void *)&original, 4))
      return 3;
    rounded++;
  }
  printf("PASS %u guarded translations across float rounding boundaries\n",
         rounded);
  if (!accepted || !rejected)
    return 2;
  printf("PASS %u exact translated vertices; %u unsupported ranges rejected\n",
         accepted, rejected);
  return 0;
}
