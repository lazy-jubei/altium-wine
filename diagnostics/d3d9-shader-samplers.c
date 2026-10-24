/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Owned SM3 shader test: alternate color textures and passing/failing depth
 * comparisons on the same sampler binding. Optional argument enables MSAA4.
 * Build: i686-w64-mingw32-gcc -O2 d3d9-shader-samplers.c -ld3dx9 -ld3d9
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <d3dx9.h>
#include <stdio.h>
#include <string.h>
#define CHECK(x)                                                               \
    do {                                                                       \
        HRESULT hr = (x);                                                      \
        if (FAILED(hr)) {                                                      \
            printf("FAIL line %d hr=%08lx\n", __LINE__, hr);                   \
            return 1;                                                          \
        }                                                                      \
    } while (0)
struct vertex {
    float x, y, z;
    DWORD color;
};
static LRESULT CALLBACK proc(HWND w, UINT m, WPARAM wp, LPARAM lp) {
    return DefWindowProcA(w, m, wp, lp);
}
static const char vs_src[] =
    "float4x4 transform:register(c0); float4 tint:register(c4); struct "
    "V{float4 p:POSITION0;float4 c:COLOR0;};V main(V v){V "
    "o;o.p=mul(v.p,transform);o.c=v.c*tint;return o;}";
static const char ps_src[] =
    "sampler2D tex:register(s0); float4 tint:register(c0); float4 main(float4 "
    "c:COLOR0):COLOR0{return tex2D(tex,float2(.5,.5))*c*tint;}";
static int compile(const char *src, const char *profile, ID3DXBuffer **out) {
    ID3DXBuffer *err = NULL;
    HRESULT hr =
        D3DXCompileShader(src, strlen(src), NULL, NULL, "main", profile,
                          D3DXSHADER_OPTIMIZATION_LEVEL3, out, &err, NULL);
    if (err) {
        printf("compile %s: %s\n", profile,
               (char *)ID3DXBuffer_GetBufferPointer(err));
        ID3DXBuffer_Release(err);
    }
    return FAILED(hr);
}
int main(int argc, char **argv) {
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "SM3Check";
    RegisterClassA(&wc);
    HWND h = CreateWindowA(wc.lpszClassName, "SM3 constant checks",
                           WS_OVERLAPPEDWINDOW, 100, 100, 180, 200, NULL, NULL,
                           wc.hInstance, NULL);
    IDirect3D9 *d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d)
        return 2;
    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE;
    pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.hDeviceWindow = h;
    pp.BackBufferWidth = pp.BackBufferHeight = 128;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    if (argc > 1)
        pp.MultiSampleType = D3DMULTISAMPLE_4_SAMPLES;
    IDirect3DDevice9 *dev = NULL;
    CHECK(IDirect3D9_CreateDevice(d, 0, D3DDEVTYPE_HAL, h,
                                  D3DCREATE_HARDWARE_VERTEXPROCESSING |
                                      D3DCREATE_FPU_PRESERVE,
                                  &pp, &dev));
    IDirect3DTexture9 *tex = NULL;
    CHECK(IDirect3DDevice9_CreateTexture(dev, 1, 1, 1, 0, D3DFMT_A8R8G8B8,
                                         D3DPOOL_MANAGED, &tex, NULL));
    D3DLOCKED_RECT tbits;
    CHECK(IDirect3DTexture9_LockRect(tex, 0, &tbits, NULL, 0));
    *(DWORD *)tbits.pBits = 0xffffffff;
    CHECK(IDirect3DTexture9_UnlockRect(tex, 0));
    CHECK(IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)tex));
    IDirect3DTexture9 *depth[2] = {NULL, NULL};
    IDirect3DSurface9 *savedRT = NULL, *savedDS = NULL, *smallRT = NULL;
    D3DVIEWPORT9 savedVP;
    CHECK(IDirect3DDevice9_GetRenderTarget(dev, 0, &savedRT));
    IDirect3DDevice9_GetDepthStencilSurface(dev, &savedDS);
    CHECK(IDirect3DDevice9_GetViewport(dev, &savedVP));
    CHECK(IDirect3DDevice9_CreateRenderTarget(dev, 1, 1, D3DFMT_X8R8G8B8,
                                              D3DMULTISAMPLE_NONE, 0, FALSE,
                                              &smallRT, NULL));
    CHECK(IDirect3DDevice9_SetRenderTarget(dev, 0, smallRT));
    D3DVIEWPORT9 smallVP = {0, 0, 1, 1, 0, 1};
    CHECK(IDirect3DDevice9_SetViewport(dev, &smallVP));
    for (int j = 0; j < 2; j++) {
        IDirect3DSurface9 *ds = NULL;
        CHECK(IDirect3DDevice9_CreateTexture(dev, 1, 1, 1,
                                             D3DUSAGE_DEPTHSTENCIL, D3DFMT_D16,
                                             D3DPOOL_DEFAULT, &depth[j], NULL));
        CHECK(IDirect3DTexture9_GetSurfaceLevel(depth[j], 0, &ds));
        CHECK(IDirect3DDevice9_SetDepthStencilSurface(dev, ds));
        CHECK(IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_ZBUFFER, 0,
                                     j ? .75f : .25f, 0));
        IDirect3DSurface9_Release(ds);
    }
    CHECK(IDirect3DDevice9_SetDepthStencilSurface(dev, savedDS));
    CHECK(IDirect3DDevice9_SetRenderTarget(dev, 0, savedRT));
    CHECK(IDirect3DDevice9_SetViewport(dev, &savedVP));
    if (savedDS)
        IDirect3DSurface9_Release(savedDS);
    IDirect3DSurface9_Release(savedRT);
    IDirect3DSurface9_Release(smallRT);
    ID3DXBuffer *vcode = NULL, *pcode = NULL;
    if (compile(vs_src, "vs_3_0", &vcode) || compile(ps_src, "ps_3_0", &pcode))
        return 3;
    IDirect3DVertexShader9 *vs = NULL;
    IDirect3DPixelShader9 *ps = NULL;
    CHECK(IDirect3DDevice9_CreateVertexShader(
        dev, ID3DXBuffer_GetBufferPointer(vcode), &vs));
    CHECK(IDirect3DDevice9_CreatePixelShader(
        dev, ID3DXBuffer_GetBufferPointer(pcode), &ps));
    CHECK(IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZ | D3DFVF_DIFFUSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE));
    CHECK(IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE));
    CHECK(IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, FALSE));
    CHECK(IDirect3DDevice9_SetVertexShader(dev, vs));
    CHECK(IDirect3DDevice9_SetPixelShader(dev, ps));
    float identity[16] = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1};
    CHECK(IDirect3DDevice9_SetVertexShaderConstantF(dev, 0, identity, 4));
    IDirect3DSurface9 *rt = NULL, *single = NULL, *copy = NULL;
    CHECK(IDirect3DDevice9_GetRenderTarget(dev, 0, &rt));
    CHECK(IDirect3DDevice9_CreateOffscreenPlainSurface(
        dev, 128, 128, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &copy, NULL));
    if (pp.MultiSampleType)
        CHECK(IDirect3DDevice9_CreateRenderTarget(
            dev, 128, 128, D3DFMT_X8R8G8B8, D3DMULTISAMPLE_NONE, 0, FALSE,
            &single, NULL));
    struct vertex vertices[] = {{-.8f, .8f, .5f, 0xffffffff},
                                {.8f, .8f, .5f, 0xffffffff},
                                {-.8f, -.8f, .5f, 0xffffffff},
                                {.8f, -.8f, .5f, 0xffffffff}};
    DWORD expected[] = {0xff0000, 0x00ff00, 0x0000ff, 0xffffff};
    unsigned checks = 0;
    for (int n = 0; n < 16; n++) {
        DWORD c = expected[n % 4];
        CHECK(IDirect3DDevice9_SetTexture(
            dev, 0, (IDirect3DBaseTexture9 *)(n % 3 ? depth[n % 3 - 1] : tex)));
        float v[4] = {((c >> 16) & 255) / 255.f, ((c >> 8) & 255) / 255.f,
                      (c & 255) / 255.f, 1};
        float white[4] = {1, 1, 1, 1};
        CHECK(IDirect3DDevice9_SetVertexShaderConstantF(dev, 4,
                                                        n & 1 ? white : v, 1));
        CHECK(IDirect3DDevice9_SetPixelShaderConstantF(dev, 0,
                                                       n & 1 ? v : white, 1));
        CHECK(IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, 0, 1, 0));
        CHECK(IDirect3DDevice9_BeginScene(dev));
        CHECK(IDirect3DDevice9_DrawPrimitiveUP(dev, D3DPT_TRIANGLESTRIP, 2,
                                               vertices, sizeof(*vertices)));
        CHECK(IDirect3DDevice9_EndScene(dev));
        if (single)
            CHECK(IDirect3DDevice9_StretchRect(dev, rt, NULL, single, NULL,
                                               D3DTEXF_NONE));
        CHECK(IDirect3DDevice9_GetRenderTargetData(dev, single ? single : rt,
                                                   copy));
        D3DLOCKED_RECT bits;
        CHECK(IDirect3DSurface9_LockRect(copy, &bits, NULL, D3DLOCK_READONLY));
        DWORD actual =
            *(DWORD *)((BYTE *)bits.pBits + 64 * bits.Pitch + 64 * 4) &
            0xffffff;
        CHECK(IDirect3DSurface9_UnlockRect(copy));
        if (n % 3 == 1)
            c = 0;
        if (actual != c) {
            printf("FAIL frame%d expected=%06lx actual=%06lx MSAA=%u\n", n, c,
                   actual, pp.MultiSampleType);
            return 4;
        }
        checks++;
        CHECK(IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL));
    }
    IDirect3DSurface9_Release(copy);
    if (single)
        IDirect3DSurface9_Release(single);
    IDirect3DSurface9_Release(rt);
    IDirect3DDevice9_SetVertexShader(dev, NULL);
    IDirect3DDevice9_SetPixelShader(dev, NULL);
    IDirect3DVertexShader9_Release(vs);
    IDirect3DPixelShader9_Release(ps);
    ID3DXBuffer_Release(vcode);
    ID3DXBuffer_Release(pcode);
    IDirect3DDevice9_SetTexture(dev, 0, NULL);
    IDirect3DTexture9_Release(tex);
    IDirect3DTexture9_Release(depth[0]);
    IDirect3DTexture9_Release(depth[1]);
    IDirect3DDevice9_Release(dev);
    IDirect3D9_Release(d);
    DestroyWindow(h);
    printf("PASS %u SM3 color/depth sampler switches and matrix/constant "
           "updates, MSAA%u\n",
           checks, pp.MultiSampleType);
    return 0;
}
