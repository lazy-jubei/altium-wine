/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Experimental AD17.1 PCB grid cache. See docs/technical-notes.md.
 */
#define COBJMACROS
#include <d3d9.h>
#include <d3dx9.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>
extern void cache_pre(void), cache_post(void);
void *cache_pre_continue, *cache_post_continue, *cache_hit_continue;
static BYTE *pcb, *core;
static HWND main_window;
static WNDPROC old_proc;
static UINT message;
static int installed, mode, device_paused;
static LONG grid_dx, grid_dy;
static DWORD gui;
static unsigned shader_ready;
static IDirect3DDevice9 *grid_device;
static IDirect3DVertexShader9 *shift_shader;
static IDirect3DVertexBuffer9 *gpu_buffer;
static unsigned gpu_ready, gpu_count;
static int gpu_min_x, gpu_min_y, gpu_max_x, gpu_max_y;
static LONG gpu_dx, gpu_dy;
static int pending_proxy;
static BYTE proxy_vertices[4][4 * 28];
static unsigned proxy_mask, replay_up;

static void **draw_slot, **up_slot;
static HRESULT(WINAPI *old_up)(IDirect3DDevice9 *, D3DPRIMITIVETYPE, UINT,
                               const void *, UINT);
static HRESULT(WINAPI *old_draw)(IDirect3DDevice9 *, D3DPRIMITIVETYPE, UINT,
                                 UINT);
static const char shift_source[] =
    "float4 rows[4]:register(c0);float4 shift:register(c5);struct V{float3 "
    "p:POSITION0;float4 c:COLOR0;};struct O{float4 p:POSITION0;float4 "
    "c:COLOR0;};O main(V v){O o;float4 "
    "p=float4(v.p.xy+shift.xy,v.p.z,1);o.p=float4(dot(p,rows[0]),dot(p,rows[1])"
    ",dot(p,rows[2]),dot(p,rows[3]));o.c=v.c;return o;}";
static uint32_t fingerprint(const BYTE *p, unsigned n) {
  uint32_t h = 2166136261u;
  for (unsigned i = 0; i < n; i++)
    h = (h ^ p[i]) * 16777619u;
  return h;
}
static int replace_slot(void **slot, void *fn) {
  DWORD old;
  if (!VirtualProtect(slot, 4, PAGE_READWRITE, &old))
    return 0;
  InterlockedExchangePointer(slot, fn);
  return VirtualProtect(slot, 4, old, &old) != 0;
}

static BYTE saved_pre[7], saved_post[6];
static void *pre_dispatch = cache_pre, *post_dispatch = cache_post;
static DWORD get(BYTE *p, int off) { return *(DWORD *)(p + off); }
static void put(BYTE *p, int off, DWORD n) { *(DWORD *)(p + off) = n; }
struct grid {
  DWORD self, context, geometry, color, z, ox, oy, other, extra, cw, mx;
  int x0, x1, xs, y0, y1, ys, cols, rows;
  DWORD proxy;
};
static struct grid cache[4], pending;
static int pending_slot = -1;
static unsigned hits;
static void ref(void *p, int slot) {
  if (p) {
    void **v = *(void ***)p;
    ((ULONG(WINAPI *)(void *))v[slot])(p);
  }
}
static void clear_cache(void) {
  for (int i = 0; i < 4; i++) {
    if (cache[i].geometry) {
      ref((void *)(uintptr_t)cache[i].geometry, 2);
      ref((void *)(uintptr_t)cache[i].context, 2);
    }
    memset(&cache[i], 0, sizeof(cache[i]));
  }
  pending_slot = -1;
  pending_proxy = 0;
  gpu_ready = 0;
  grid_dx = grid_dy = 0;
}
static int valid_context(DWORD p) {
  if (!p)
    return 0;
  void **v = *(void ***)(uintptr_t)p;
  return v[1] == core + 0x55ecc1 && v[2] == core + 0x55eccb;
}
static int valid_geometry(DWORD p) {
  if (!p)
    return 0;
  void **v = *(void ***)(uintptr_t)p;
  return v[1] == core + 0x504078 && v[2] == core + 0x504082 &&
         v[9] == core + 0x503fe1;
}
static int exact_axis(int start, int end, DWORD origin, int step) {
  int64_t a = (int64_t)start - (int32_t)origin,
          b = (int64_t)end - (int32_t)origin;
  uint64_t bound = llabs(a) > llabs(b) ? llabs(a) : llabs(b), quantum = 1;
  while (bound > 0x1000000u) {
    bound = (bound + 1) / 2;
    quantum *= 2;
  }
  return a % (int64_t)quantum == 0 && b % (int64_t)quantum == 0 &&
         step % (int64_t)quantum == 0;
}
static int shift_in_band(int lo, int hi, int64_t shift) {
  if (shift % 32)
    return 0;
  if (lo > hi) {
    int tmp = lo;
    lo = hi;
    hi = tmp;
  }
  if (lo <= 0 && hi >= 0)
    return 0;
  uint64_t a = llabs((int64_t)lo), b = llabs((int64_t)hi);
  uint64_t low = a < b ? a : b, high = a > b ? a : b, band = 1;
  while (band * 2 <= low)
    band *= 2;
  if (high >= band * 2)
    return 0;
  int64_t x = (int64_t)lo + shift, y = (int64_t)hi + shift;
  return lo > 0 ? x >= (int64_t)band && y < (int64_t)(band * 2)
                : x > -(int64_t)(band * 2) && y <= -(int64_t)band;
}
static int safe_coord(int64_t n, DWORD origin) {
  return n >= INT32_MIN && n <= INT32_MAX && n - (int32_t)origin >= INT32_MIN &&
         n - (int32_t)origin <= INT32_MAX;
}
static int key_equal(const struct grid *a, const struct grid *b) {
  return a->self == b->self && a->context == b->context &&
         a->color == b->color && a->z == b->z && a->ox == b->ox &&
         a->oy == b->oy && a->other == b->other && a->extra == b->extra &&
         a->cw == b->cw && a->mx == b->mx && a->xs == b->xs && a->ys == b->ys;
}
static int contains_axis(int c0, int c1, int step, int count, int n0, int n1,
                         int ncount) {
  int64_t d = (int64_t)n0 - c0;
  if (d % step || d / step < 0 || d / step + (int64_t)ncount > count)
    return 0;
  return step > 0 ? n0 >= c0 && n1 <= c1 : n0 <= c0 && n1 >= c1;
}
static int reuse_grid(BYTE *f, int rows) {
  pending_slot = -1;
  pending_proxy = 0;
  if (!mode) {
    proxy_mask = 0;
    return 0;
  }
  if (!(GetAsyncKeyState(VK_RBUTTON) & 0x8000) ||
      ((GetAsyncKeyState(VK_SHIFT) | GetAsyncKeyState(VK_CONTROL) |
        GetAsyncKeyState(VK_MENU) | GetAsyncKeyState(VK_LBUTTON) |
        GetAsyncKeyState(VK_MBUTTON)) &
       0x8000) ||
      GetForegroundWindow() != main_window) {
    clear_cache();
    proxy_mask = 0;
    return 0;
  }
  struct grid g = {0};
  g.self = get(f, -12);
  g.context = get((BYTE *)(uintptr_t)g.self, 0x45);
  g.x0 = get(f, -0x14);
  g.x1 = get(f, 0x30);
  g.xs = get(f, 0x2c);
  g.y0 = get(f, 0x28);
  g.y1 = get(f, 0x24);
  g.ys = get(f, 0x20);
  g.cols = get(f, -0x54) + 1;
  g.rows = rows + 1;
  g.color = get(f, -0x18);
  g.z = get(f, 0x1c);
  g.ox = get(f, 0x18);
  g.oy = get(f, 0x14);
  g.other = get(f, 8);
  g.extra = get(f, -0x10);
  WORD cw;
  __asm__ volatile("fnstcw %0" : "=m"(cw));
  __asm__ volatile("stmxcsr %0" : "=m"(g.mx));
  g.cw = cw;
  if (!shader_ready || get(f, 0x10) != 0 || (cw & 0xc3f) != 0x3f ||
      (cw & 0x300) < 0x200 || (g.mx & 0x7f80) != 0x1f80 ||
      !valid_context(g.context) || g.xs == 0 || g.ys == 0 ||
      g.xs == INT32_MIN || g.ys == INT32_MIN || g.x0 == g.x1 || g.y0 == g.y1 ||
      g.cols < 1 || g.rows < 1 || g.cols > 20000 || g.rows > 20000) {
    return 0;
  }
  if (g.xs < 0)
    g.xs = -g.xs;
  if (g.x0 > g.x1)
    g.xs = -g.xs;
  if (g.ys < 0)
    g.ys = -g.ys;
  if (g.y0 > g.y1)
    g.ys = -g.ys;
  if (!exact_axis(g.x0, g.x1, g.ox, g.xs) ||
      !exact_axis(g.y0, g.y1, g.oy, g.ys) ||
      llabs((int64_t)(g.cols - 1) * g.xs) > INT32_MAX ||
      llabs((int64_t)(g.rows - 1) * g.ys) > INT32_MAX) {
    clear_cache();
    return 0;
  }
  int slot = -1, minstep = INT_MAX, maxstep = 0;
  for (int i = 0; i < 4; i++)
    if (cache[i].geometry) {
      int step = abs(cache[i].xs);
      if (step < minstep)
        minstep = step;
      if (step > maxstep)
        maxstep = step;
      if (key_equal(&cache[i], &g))
        slot = i;
    }
  if (mode >= 3 && abs(g.xs) <= minstep) {
    if (slot < 0) {
      clear_cache();
      minstep = INT_MAX;
      maxstep = 0;
    } else {
      struct grid *c = &cache[slot];
      if (maxstep != abs(g.xs) && (int64_t)maxstep != 2 * (int64_t)abs(g.xs)) {
        clear_cache();
        slot = -1;
      } else {
        int64_t dx = (int64_t)g.x0 - ((int64_t)c->x0 + 2 * (int64_t)c->xs),
                dy = (int64_t)g.y0 - ((int64_t)c->y0 + 2 * (int64_t)c->ys);
        int64_t sx = maxstep, sy = 0;
        for (int i = 0; i < 4; i++)
          if (cache[i].geometry && abs(cache[i].ys) > sy)
            sy = abs(cache[i].ys);
        dx = dx / sx * sx;
        dy = dy / sy * sy;
        if (llabs(dx) > (int64_t)c->cols * abs(c->xs) / 3 ||
            llabs(dy) > (int64_t)c->rows * abs(c->ys) / 3) {
          clear_cache();
          slot = -1;
        } else if (!exact_axis(dx, dx, 0, 0) || !exact_axis(dy, dy, 0, 0)) {
          clear_cache();
          slot = -1;
        } else {
          if (gpu_ready && (!shift_in_band(gpu_min_x, gpu_max_x, dx) ||
                            !shift_in_band(gpu_min_y, gpu_max_y, dy))) {
            clear_cache();
            slot = -1;
          } else {
            grid_dx = (LONG)dx;
            grid_dy = (LONG)dy;
          }
        }
      }
    }
  }
  if (slot >= 0 && !gpu_ready) {
    clear_cache();
    slot = -1;
  }
  if (slot >= 0) {
    struct grid *c = &cache[slot];
    int64_t x0 = (int64_t)c->x0 + grid_dx, x1 = (int64_t)c->x1 + grid_dx,
            y0 = (int64_t)c->y0 + grid_dy, y1 = (int64_t)c->y1 + grid_dy;
    if (x0 >= INT32_MIN && x0 <= INT32_MAX && x1 >= INT32_MIN &&
        x1 <= INT32_MAX && y0 >= INT32_MIN && y0 <= INT32_MAX &&
        y1 >= INT32_MIN && y1 <= INT32_MAX &&
        contains_axis(x0, x1, c->xs, c->cols, g.x0, g.x1, g.cols) &&
        contains_axis(y0, y1, c->ys, c->rows, g.y0, g.y1, g.rows)) {
      if (mode == 4 && gpu_ready && !c->proxy) {
        pending_proxy = 1;
        pending_slot = slot;
        put(f, -0x14, c->x0);
        put(f, 0x30, c->x0 + (c->cols - 1) * c->xs);
        put(f, 0x28, c->y0);
        put(f, 0x24, c->y0 + (c->rows - 1) * c->ys);
        put(f, 0x2c, (c->cols - 1) * c->xs);
        put(f, 0x20, (c->rows - 1) * c->ys);
        put(f, -0x54, 1);
        return 2;
      }
      ref((void *)(uintptr_t)c->geometry, 1);
      put(f, -4, c->geometry);
      put(f, -0x24, c->proxy ? 4 : c->cols * c->rows);
      put(f, -0x14, c->x0);
      put(f, 0x30, c->x1);
      put(f, 0x28, c->y0);
      put(f, 0x24, c->y1);
      hits++;
      return 1;
    }
  }
  if (slot < 0)
    for (int i = 0; i < 4; i++)
      if (!cache[i].geometry) {
        slot = i;
        break;
      }
  if (slot < 0) {
    return 0;
  }
  if (mode >= 3) {
    int xp = 2, yp = 2;
    int64_t x0 = (int64_t)g.x0 - (int64_t)xp * g.xs - grid_dx,
            x1 = (int64_t)g.x1 + (int64_t)xp * g.xs - grid_dx,
            y0 = (int64_t)g.y0 - (int64_t)yp * g.ys - grid_dy,
            y1 = (int64_t)g.y1 + (int64_t)yp * g.ys - grid_dy;
    if (!safe_coord(x0, g.ox) || !safe_coord(x1, g.ox) ||
        !safe_coord(y0, g.oy) || !safe_coord(y1, g.oy) ||
        !exact_axis(x0, x1, g.ox, g.xs) || !exact_axis(y0, y1, g.oy, g.ys) ||
        (int64_t)(g.cols + 2 * xp) * (g.rows + 2 * yp) > 2000000) {
      return 0;
    }
    g.x0 = x0;
    g.x1 = x1;
    g.y0 = y0;
    g.y1 = y1;
    g.cols += 2 * xp;
    g.rows += 2 * yp;
    put(f, -0x14, g.x0);
    put(f, 0x30, g.x1);
    put(f, 0x28, g.y0);
    put(f, 0x24, g.y1);
    put(f, -0x54, g.cols - 1);
  }
  pending = g;
  pending_slot = slot;
  return mode >= 3 ? g.rows : 0;
}
int cache_pre_helper(BYTE *f, int rows) {
  DWORD last = GetLastError();
  if (GetCurrentThreadId() != gui)
    return 0;
  int result = reuse_grid(f, rows);
  SetLastError(last);
  return result;
}
void cache_post_helper(BYTE *f) {
  DWORD last = GetLastError();
  if (GetCurrentThreadId() != gui)
    return;
  if (pending_slot >= 0) {
    int i = pending_slot;
    pending_slot = -1;
    DWORD geo = get(f, -4);
    if (pending_proxy) {
      pending_proxy = 0;
      if (valid_geometry(geo)) {
        BYTE *storage = *(BYTE **)((BYTE *)(uintptr_t)geo - 12);
        if (!storage || *(DWORD *)(storage - 8) != 28 ||
            *(DWORD *)(storage - 4) < 4 || !*(BYTE **)(storage - 12)) {
          SetLastError(last);
          return;
        }
        memcpy(proxy_vertices[i], *(BYTE **)(storage - 12), 4 * 28);
        proxy_mask |= 1u << i;
        ref((void *)(uintptr_t)geo, 1);
        ref((void *)(uintptr_t)cache[i].geometry, 2);
        cache[i].geometry = geo;
        cache[i].proxy = 1;
      }
      SetLastError(last);
      return;
    }
    if (valid_geometry(geo) &&
        pending.context == get((BYTE *)(uintptr_t)pending.self, 0x45)) {
      ref((void *)(uintptr_t)geo, 1);
      ref((void *)(uintptr_t)pending.context, 1);
      if (cache[i].geometry) {
        ref((void *)(uintptr_t)cache[i].geometry, 2);
        ref((void *)(uintptr_t)cache[i].context, 2);
      }
      pending.geometry = geo;
      cache[i] = pending;
    }
  }
  SetLastError(last);
}
static int upload_grid(IDirect3DDevice9 *d) {
  unsigned total = 0;
  for (int i = 0; i < 4; i++)
    if (cache[i].geometry) {
      if (cache[i].proxy)
        return 0;
      total += cache[i].cols * cache[i].rows;
    }
  if (!total || total > 4000000)
    return 0;
  IDirect3DVertexBuffer9 *buffer = NULL;
  if (FAILED(IDirect3DDevice9_CreateVertexBuffer(
          d, total * 28, D3DUSAGE_WRITEONLY, 0, D3DPOOL_MANAGED, &buffer,
          NULL)))
    return 0;
  BYTE *data = NULL;
  if (FAILED(IDirect3DVertexBuffer9_Lock(buffer, 0, total * 28, (void **)&data,
                                         0))) {
    IDirect3DVertexBuffer9_Release(buffer);
    return 0;
  }
  unsigned used = 0;
  int min_x = INT_MAX, min_y = INT_MAX, max_x = INT_MIN, max_y = INT_MIN;
  int ok = 1;
  for (int i = 0; i < 4; i++)
    if (cache[i].geometry) {
      BYTE *geo = (BYTE *)(uintptr_t)cache[i].geometry;
      BYTE *storage = *(BYTE **)(geo - 12);
      unsigned count = cache[i].cols * cache[i].rows;
      if (!storage || *(DWORD *)(storage - 8) != 28 ||
          *(DWORD *)(storage - 4) < count || !*(BYTE **)(storage - 12)) {
        ok = 0;
        break;
      }
      const BYTE *source = *(BYTE **)(storage - 12);
      for (unsigned edge = 0; edge < 2; edge++)
        for (unsigned axis = 0; axis < 2; axis++) {
          uint32_t bits;
          float value;
          memcpy(&bits, source + (edge ? count - 1 : 0) * 28 + axis * 4, 4);
          bits &= 0x7fffffffu;
          if (bits > 0x4d000000u) {
            ok = 0;
            break;
          }
          memcpy(&value, source + (edge ? count - 1 : 0) * 28 + axis * 4, 4);
          int bound = (int)value;
          if (axis == 0) {
            if (bound < min_x)
              min_x = bound;
            if (bound > max_x)
              max_x = bound;
          } else {
            if (bound < min_y)
              min_y = bound;
            if (bound > max_y)
              max_y = bound;
          }
        }
      if (!ok)
        break;
      memcpy(data + used * 28, *(BYTE **)(storage - 12), count * 28);
      used += count;
    }
  IDirect3DVertexBuffer9_Unlock(buffer);
  if (!shift_in_band(min_x, max_x, 0) || !shift_in_band(min_y, max_y, 0))
    ok = 0;
  if (!ok) {
    IDirect3DVertexBuffer9_Release(buffer);
    return 0;
  }
  if (gpu_buffer)
    IDirect3DVertexBuffer9_Release(gpu_buffer);
  gpu_buffer = buffer;
  proxy_mask = 0;
  gpu_count = total;
  gpu_min_x = min_x;
  gpu_min_y = min_y;
  gpu_max_x = max_x;
  gpu_max_y = max_y;
  gpu_ready = 1;
  return 1;
}
static int match_proxy(const BYTE *vertices, UINT count) {
  unsigned matched = 0;
  if (!count || count > 16 || count % 4)
    return 0;
  for (unsigned group = 0; group < count / 4; group++) {
    unsigned i;
    for (i = 0; i < 4; i++)
      if ((proxy_mask & ~matched & (1u << i)) &&
          !memcmp(vertices + group * 4 * 28, proxy_vertices[i], 4 * 28))
        break;
    if (i == 4)
      return 0;
    matched |= 1u << i;
  }
  return matched && matched == proxy_mask;
}
static int grid_shader(IDirect3DVertexShader9 *shader) {
  BYTE code[392];
  UINT length = 0;
  return SUCCEEDED(IDirect3DVertexShader9_GetFunction(shader, NULL, &length)) &&
         length == sizeof(code) &&
         SUCCEEDED(IDirect3DVertexShader9_GetFunction(shader, code, &length)) &&
         fingerprint(code, length) == 0x5f138ed9u;
}
static HRESULT WINAPI draw(IDirect3DDevice9 *d, D3DPRIMITIVETYPE type,
                           UINT start, UINT count) {
  if (GetCurrentThreadId() != gui || type != D3DPT_POINTLIST ||
      (count < 10000 && (!gpu_buffer || count > 16)))
    return old_draw(d, type, start, count);
  IDirect3DVertexShader9 *old_shader = NULL;
  if (FAILED(IDirect3DDevice9_GetVertexShader(d, &old_shader)) || !old_shader)
    return old_draw(d, type, start, count);
  int valid = grid_shader(old_shader);
  if (valid && grid_device && d != grid_device) {
    clear_cache();
    mode = 0;
    device_paused = 1;
    IDirect3DVertexShader9_Release(old_shader);
    return old_draw(d, type, start, count);
  }
  if (valid && device_paused && d == grid_device) {
    mode = 4;
    device_paused = 0;
  }
  if (valid && !shift_shader) {
    ID3DXBuffer *compiled = NULL, *errors = NULL;
    HRESULT hr = D3DXCompileShader(
        shift_source, strlen(shift_source), NULL, NULL, "main", "vs_3_0",
        D3DXSHADER_OPTIMIZATION_LEVEL3, &compiled, &errors, NULL);
    if (SUCCEEDED(hr)) {
      hr = IDirect3DDevice9_CreateVertexShader(
          d, ID3DXBuffer_GetBufferPointer(compiled), &shift_shader);
      ID3DXBuffer_Release(compiled);
    }
    if (errors)
      ID3DXBuffer_Release(errors);
    if (SUCCEEDED(hr)) {
      grid_device = d;
      shader_ready = 1;
    }
  }
  unsigned expected = 0;
  for (int i = 0; i < 4; i++)
    if (cache[i].geometry)
      expected += cache[i].proxy ? 4 : cache[i].cols * cache[i].rows;
  if (mode == 4 && valid && count >= 10000 && count == expected && !gpu_ready) {
    upload_grid(d);
    gpu_dx = grid_dx;
    gpu_dy = grid_dy;
  }
  int proxy = 0;
  if (valid && gpu_buffer && count && count <= 16 && count % 4 == 0) {
    if (replay_up)
      proxy = 1;
    else {
      IDirect3DVertexBuffer9 *vb = NULL;
      UINT offset = 0, stride = 0;
      BYTE *vertices = NULL;
      if (SUCCEEDED(
              IDirect3DDevice9_GetStreamSource(d, 0, &vb, &offset, &stride)) &&
          vb && stride == 28 &&
          SUCCEEDED(IDirect3DVertexBuffer9_Lock(vb, offset + start * 28,
                                                count * 28, (void **)&vertices,
                                                D3DLOCK_READONLY))) {
        proxy = match_proxy(vertices, count);
        IDirect3DVertexBuffer9_Unlock(vb);
      }
      if (vb)
        IDirect3DVertexBuffer9_Release(vb);
    }
  }
  if (proxy && gpu_ready) {
    gpu_dx = grid_dx;
    gpu_dy = grid_dy;
  }
  LONG dx = proxy ? gpu_dx : grid_dx, dy = proxy ? gpu_dy : grid_dy;
  HRESULT result;
  if (valid && shift_shader &&
      (proxy || (mode >= 3 && count == expected && (dx || dy)))) {
    float saved[4], shift[4] = {(float)dx, (float)dy, 0, 0};
    IDirect3DVertexBuffer9 *old_buffer = NULL;
    UINT old_offset = 0, old_stride = 0;
    if (proxy)
      IDirect3DDevice9_GetStreamSource(d, 0, &old_buffer, &old_offset,
                                       &old_stride);
    if (SUCCEEDED(IDirect3DDevice9_GetVertexShaderConstantF(d, 5, saved, 1)) &&
        SUCCEEDED(IDirect3DDevice9_SetVertexShader(d, shift_shader))) {
      IDirect3DDevice9_SetVertexShaderConstantF(d, 5, shift, 1);
      if (proxy)
        IDirect3DDevice9_SetStreamSource(d, 0, gpu_buffer, 0, 28);
      result = old_draw(d, type, proxy ? 0 : start, proxy ? gpu_count : count);
      if (proxy) {
        IDirect3DDevice9_SetStreamSource(d, 0, old_buffer, old_offset,
                                         old_stride);
      }
      IDirect3DDevice9_SetVertexShaderConstantF(d, 5, saved, 1);
      IDirect3DDevice9_SetVertexShader(d, old_shader);
    } else {
      result = old_draw(d, type, start, count);
    }
    if (old_buffer)
      IDirect3DVertexBuffer9_Release(old_buffer);
  } else {
    result = old_draw(d, type, start, count);
  }
  if (mode == 0 && count >= 10000 && gpu_buffer) {
    IDirect3DVertexBuffer9_Release(gpu_buffer);
    gpu_buffer = NULL;
    gpu_ready = 0;
  }
  IDirect3DVertexShader9_Release(old_shader);
  return result;
}
static HRESULT WINAPI draw_up(IDirect3DDevice9 *d, D3DPRIMITIVETYPE type,
                              UINT count, const void *vertices, UINT stride) {
  if (GetCurrentThreadId() == gui && d == grid_device && gpu_buffer &&
      type == D3DPT_POINTLIST && count <= 16 && count % 4 == 0 &&
      stride == 28) {
    IDirect3DVertexShader9 *vs = NULL;
    int valid = 0;
    if (SUCCEEDED(IDirect3DDevice9_GetVertexShader(d, &vs)) && vs) {
      valid = grid_shader(vs);
      IDirect3DVertexShader9_Release(vs);
    }
    if (valid && match_proxy(vertices, count)) {
      replay_up = 1;
      HRESULT result = draw(d, type, 0, count);
      replay_up = 0;
      IDirect3DDevice9_SetStreamSource(d, 0, NULL, 0, 0);
      return result;
    }
  }
  return old_up(d, type, count, vertices, stride);
}
static int write_code(void *at, const void *bytes, unsigned n) {
  DWORD old;
  if (!VirtualProtect(at, n, PAGE_EXECUTE_READWRITE, &old))
    return 0;
  memcpy(at, bytes, n);
  FlushInstructionCache(GetCurrentProcess(), at, n);
  return VirtualProtect(at, n, old, &old) != 0;
}
static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM wp, LPARAM lp) {
  if (m == WM_TIMER && wp == 0x17ca5e) {
    DWORD last = GetLastError();
    if (!(GetAsyncKeyState(VK_RBUTTON) & 0x8000) ||
        GetForegroundWindow() != main_window)
      clear_cache();
    SetLastError(last);
    return 0;
  }
  if (m != message || lp != 0x5ad1734)
    return CallWindowProcW(old_proc, w, m, wp, lp);
  if (wp == 900) {
    const BYTE a[] = {0x8b, 0x45, 0xac, 0x40, 0x8d, 0x53, 0x01},
               b[] = {0x8b, 0x45, 0xec, 0x3b, 0x45, 0x30};
    if (installed || memcmp(pcb + 0xfd101c, a, 7) ||
        memcmp(pcb + 0xfd11be, b, 6))
      return -1;
    memcpy(saved_pre, a, 7);
    memcpy(saved_post, b, 6);
    cache_pre_continue = pcb + 0xfd1023;
    cache_post_continue = pcb + 0xfd11c4;
    cache_hit_continue = pcb + 0xfd11be;
    BYTE hook[7] = {0xff, 0x25, 0, 0, 0, 0, 0x90};
    *(DWORD *)(hook + 2) = (DWORD)(uintptr_t)&pre_dispatch;
    if (!write_code(pcb + 0xfd101c, hook, 7))
      return -2;
    *(DWORD *)(hook + 2) = (DWORD)(uintptr_t)&post_dispatch;
    if (!write_code(pcb + 0xfd11be, hook, 6)) {
      write_code(pcb + 0xfd101c, saved_pre, 7);
      return -3;
    }
    installed = 1;
    return 1;
  }
  if (wp == 0 || wp == 3 || wp == 4) {
    clear_cache();
    device_paused = 0;
    mode = wp;
    SetTimer(w, 0x17ca5e, 100, NULL);
    return 1;
  }
  if (wp == 100) {
    hits = 0;
    return 1;
  }
  if (wp == 101)
    return hits;
  if (wp == 102)
    return installed;
  if (wp == 99 && installed) {
    clear_cache();
    KillTimer(w, 0x17ca5e);
    if (!write_code(pcb + 0xfd101c, saved_pre, 7) ||
        !write_code(pcb + 0xfd11be, saved_post, 6))
      return -5;
    replace_slot(draw_slot, old_draw);
    replace_slot(up_slot, old_up);
    if (gpu_buffer) {
      IDirect3DVertexBuffer9_Release(gpu_buffer);
      gpu_buffer = NULL;
    }
    if (shift_shader) {
      IDirect3DVertexShader9_Release(shift_shader);
      shift_shader = NULL;
    }
    installed = 0;
    return 1;
  }
  return -99;
}
static DWORD WINAPI worker(void *unused) {
  (void)unused;
  main_window = FindWindowA("TDocumentForm", NULL);
  DWORD owner;
  gui = GetWindowThreadProcessId(main_window, &owner);
  pcb = (BYTE *)GetModuleHandleA("ADVPCB.DLL");
  core = (BYTE *)GetModuleHandleA("Core3D.dll");
  if (owner != GetCurrentProcessId() || !pcb || !core)
    return 1;
  IMAGE_NT_HEADERS *pcb_pe =
      (IMAGE_NT_HEADERS *)(pcb + ((IMAGE_DOS_HEADER *)pcb)->e_lfanew);
  IMAGE_NT_HEADERS *core_pe =
      (IMAGE_NT_HEADERS *)(core + ((IMAGE_DOS_HEADER *)core)->e_lfanew);
  if (pcb_pe->FileHeader.TimeDateStamp != 0x59f248e4 ||
      pcb_pe->OptionalHeader.SizeOfImage != 0x3728000 ||
      core_pe->FileHeader.TimeDateStamp != 0x59f24901 ||
      core_pe->OptionalHeader.SizeOfImage != 0x8ad000)
    return 2;
  if (memcmp(pcb + 0xfd101c, "\x8b\x45\xac\x40\x8d\x53\x01", 7) ||
      memcmp(pcb + 0xfd11be, "\x8b\x45\xec\x3b\x45\x30", 6))
    return 2;
  BYTE *d3d = (BYTE *)GetModuleHandleA("d3d9.dll");
  if (!d3d)
    return 3;
  DWORD image_size =
      ((IMAGE_NT_HEADERS *)(d3d + ((IMAGE_DOS_HEADER *)d3d)->e_lfanew))
          ->OptionalHeader.SizeOfImage;
  /* Known DXVK builds (before/after partial-present repair) and Wine D3D9.
     Keep both function-pointer checks before changing any vtable slot. */
  static const DWORD layouts[][3] = {
      {0x440438, 0x128c0, 0x13bd0},
      {0x441438, 0x128c0, 0x13bd0},
      {0x1c424, 0x9cc0, 0xa460}};
  for (unsigned i = 0; i < sizeof(layouts) / sizeof(layouts[0]); i++) {
    DWORD table = layouts[i][0];
    if (image_size < table + 84 * 4 ||
        *(void **)(d3d + table + 81 * 4) != (void *)(d3d + layouts[i][1]) ||
        *(void **)(d3d + table + 83 * 4) != (void *)(d3d + layouts[i][2]))
      continue;
    draw_slot = (void **)(d3d + table + 81 * 4);
    up_slot = (void **)(d3d + table + 83 * 4);
    break;
  }
  if (!draw_slot)
    return 4;
  old_draw = *draw_slot;
  old_up = *up_slot;
  if (!replace_slot(draw_slot, draw))
    return 5;
  if (!replace_slot(up_slot, draw_up)) {
    replace_slot(draw_slot, old_draw);
    return 5;
  }
  message = RegisterWindowMessageW(L"Codex.AD17.GridCache.20261024");
  old_proc = (WNDPROC)GetWindowLongPtrW(main_window, GWLP_WNDPROC);
  SetWindowLongPtrW(main_window, GWLP_WNDPROC, (LONG_PTR)proc);
  DWORD_PTR r = 0;
  SendMessageTimeoutW(main_window, message, 900, 0x5ad1734, SMTO_ABORTIFHUNG,
                      5000, &r);
  if (r == 1)
    SendMessageTimeoutW(main_window, message, 4, 0x5ad1734, SMTO_ABORTIFHUNG,
                        5000, &r);
  return r == 1 ? 0 : 2;
}
BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, void *unused) {
  (void)unused;
  if (reason == DLL_PROCESS_ATTACH) {
    DisableThreadLibraryCalls(h);
    HANDLE t = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    if (t)
      CloseHandle(t);
  }
  return TRUE;
}
