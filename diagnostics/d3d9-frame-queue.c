/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * i686-w64-mingw32-clang -O2 d3d9-frame-queue.c -ld3d9 -lgdi32 -o check.exe
 * Run with ALTIUM_D3D9_UPLOADS=1 ALTIUM_D3D9_UPLOAD_HINTS=1.
 * Two or three outstanding frames share a dynamic VB, with frequent ring discards.
 * Read back every frame before its render target is reused.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>
#define CHECK(x) do { HRESULT hr = (x); if (FAILED(hr)) { printf("FAIL line %d hr=%08lx\n", __LINE__, hr); return 1; } } while (0)
struct vertex { float x, y, z, rhw; DWORD colour; };
static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }
static DWORD colour(unsigned frame, unsigned tile) { return (frame * 9173 + tile * 3719 + 0x104080) & 0xffffff; }
static int verify(IDirect3DDevice9 *dev, IDirect3DSurface9 *rt, IDirect3DSurface9 *copy, unsigned frame)
{
    CHECK(IDirect3DDevice9_GetRenderTargetData(dev, rt, copy));
    D3DLOCKED_RECT bits;
    CHECK(IDirect3DSurface9_LockRect(copy, &bits, NULL, D3DLOCK_READONLY));
    int failed = 0;
    for (unsigned tile = 0; tile < 64; tile++) {
        DWORD pixel = *(DWORD *)((BYTE *)bits.pBits + (tile / 8 * 16 + 4) * bits.Pitch + (tile % 8 * 16 + 4) * 4) & 0xffffff;
        if (pixel != colour(frame, tile)) {
            printf("FAIL frame %u tile %u expected=%06lx actual=%06lx\n", frame, tile, colour(frame, tile), pixel);
            failed = 1;
        }
    }
    CHECK(IDirect3DSurface9_UnlockRect(copy));
    return failed;
}
static int wait_query(IDirect3DQuery9 *query)
{
    DWORD start = GetTickCount();
    HRESULT hr;
    while ((hr = IDirect3DQuery9_GetData(query, NULL, 0, D3DGETDATA_FLUSH)) == S_FALSE) {
        if (GetTickCount() - start > 5000) return 1;
        Sleep(1);
    }
    return FAILED(hr);
}
int main(int argc, char **argv)
{
    unsigned depth = argc > 1 ? atoi(argv[1]) : 2;
    if (depth < 2 || depth > 3) return 1;
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "FrameQueue";
    if (!RegisterClassA(&wc)) return 1;
    HWND h = CreateWindowA(wc.lpszClassName, "Frame queue test", WS_OVERLAPPEDWINDOW, 0, 0, 160, 180, NULL, NULL, wc.hInstance, NULL);
    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!h || !d3d) return 1;
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD; pp.hDeviceWindow = h;
    pp.BackBufferWidth = pp.BackBufferHeight = 128; pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    IDirect3DDevice9 *dev = NULL;
    CHECK(IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, h, D3DCREATE_HARDWARE_VERTEXPROCESSING | D3DCREATE_FPU_PRESERVE, &pp, &dev));
    IDirect3DVertexBuffer9 *vb = NULL;
    CHECK(IDirect3DDevice9_CreateVertexBuffer(dev, 2 * 1024 * 1024, D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY,
          D3DFVF_XYZRHW | D3DFVF_DIFFUSE, D3DPOOL_DEFAULT, &vb, NULL));
    IDirect3DSurface9 *rt[3], *copy;
    IDirect3DQuery9 *queries[3];
    for (unsigned n = 0; n < depth; n++) {
        CHECK(IDirect3DDevice9_CreateRenderTarget(dev, 128, 128, D3DFMT_X8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE, &rt[n], NULL));
        CHECK(IDirect3DDevice9_CreateQuery(dev, D3DQUERYTYPE_EVENT, &queries[n]));
    }
    CHECK(IDirect3DDevice9_CreateOffscreenPlainSurface(dev, 128, 128, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL));
    CHECK(IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_DIFFUSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE));
    CHECK(IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, FALSE));
    for (unsigned frame = 0; frame < 128; frame++) {
        unsigned slot = frame % depth;
        if (frame >= depth && (wait_query(queries[slot]) || verify(dev, rt[slot], copy, frame - depth))) return 2;
        CHECK(IDirect3DDevice9_SetRenderTarget(dev, 0, rt[slot]));
        CHECK(IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, 0, 1, 0));
        CHECK(IDirect3DDevice9_BeginScene(dev));
        for (unsigned tile = 0; tile < 64; tile++) {
            UINT offset = (tile % 4) * 4096;
            struct vertex *p;
            CHECK(IDirect3DVertexBuffer9_Lock(vb, offset, 4 * sizeof(*p), (void **)&p, tile % 4 ? D3DLOCK_NOOVERWRITE : D3DLOCK_DISCARD));
            const float dx[] = {0, 14, 0, 14}, dy[] = {0, 0, 14, 14};
            for (unsigned n = 0; n < 4; n++) p[n] = (struct vertex){tile % 8 * 16 + 1 + dx[n], tile / 8 * 16 + 1 + dy[n], 0, 1, 0xff000000 | colour(frame, tile)};
            CHECK(IDirect3DVertexBuffer9_Unlock(vb));
            CHECK(IDirect3DDevice9_SetStreamSource(dev, 0, vb, offset, sizeof(*p)));
            CHECK(IDirect3DDevice9_DrawPrimitive(dev, D3DPT_TRIANGLESTRIP, 0, 2));
        }
        CHECK(IDirect3DDevice9_EndScene(dev));
        CHECK(IDirect3DQuery9_Issue(queries[slot], D3DISSUE_END));
    }
    for (unsigned slot = 0; slot < depth; slot++) {
        if (wait_query(queries[slot]) || verify(dev, rt[slot], copy, 127 - (127 - slot) % depth)) return 2;
        IDirect3DQuery9_Release(queries[slot]); IDirect3DSurface9_Release(rt[slot]);
    }
    IDirect3DSurface9_Release(copy); IDirect3DVertexBuffer9_Release(vb);
    IDirect3DDevice9_Release(dev); IDirect3D9_Release(d3d); DestroyWindow(h);
    printf("PASS 128 frames, 8192 GPU tile checks, %u-query ring and shared VB discards\n", depth);
    return 0;
}
