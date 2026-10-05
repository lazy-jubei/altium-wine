/* Small dynamic-buffer upload probe for the AD17 Wine investigation.
 * Synthetic workload; its frame rate is not an Altium board frame rate.
 */
#define COBJMACROS
#include <d3d9.h>
#include <stdio.h>
#include <string.h>
#include <windows.h>
static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) {
  return DefWindowProcA(h, m, w, l);
}
static double secs(LARGE_INTEGER a, LARGE_INTEGER b, LARGE_INTEGER f) {
  return (double)(b.QuadPart - a.QuadPart) / f.QuadPart;
}
int main(void) {
  WNDCLASSA wc = {0};
  wc.lpfnWndProc = proc;
  wc.hInstance = GetModuleHandleA(0);
  wc.lpszClassName = "BufferBench";
  RegisterClassA(&wc);
  HWND h = CreateWindowA(wc.lpszClassName, "AD17 buffer upload probe",
                         WS_OVERLAPPEDWINDOW, 80, 150, 340, 260, 0, 0,
                         wc.hInstance, 0);
  ShowWindow(h, SW_SHOW);
  IDirect3D9 *d = Direct3DCreate9(D3D_SDK_VERSION);
  if (!d)
    return 1;
  D3DPRESENT_PARAMETERS pp = {0};
  pp.Windowed = TRUE;
  pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
  pp.hDeviceWindow = h;
  pp.BackBufferWidth = 320;
  pp.BackBufferHeight = 200;
  pp.BackBufferFormat = D3DFMT_UNKNOWN;
  pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
  IDirect3DDevice9 *dev = 0;
  HRESULT hr =
      IDirect3D9_CreateDevice(d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, h,
                              D3DCREATE_HARDWARE_VERTEXPROCESSING, &pp, &dev);
  if (FAILED(hr)) {
    printf("CreateDevice %08lx\n", (long)hr);
    return 2;
  }
  IDirect3DVertexBuffer9 *vb = 0;
  hr = IDirect3DDevice9_CreateVertexBuffer(
      dev, 420, D3DUSAGE_DYNAMIC | D3DUSAGE_WRITEONLY,
      D3DFVF_XYZRHW | D3DFVF_DIFFUSE, D3DPOOL_DEFAULT, &vb, 0);
  if (FAILED(hr))
    return 3;
  struct V {
    float x, y, z, r;
    DWORD color;
  } data[21];
  memset(data, 0, sizeof(data));
  for (int j = 0; j < 21; j++) {
    data[j].r = 1;
    data[j].color = 0xffff8000;
  }
  data[0].x = 20;
  data[0].y = 20;
  data[1].x = 28;
  data[1].y = 20;
  data[2].x = 20;
  data[2].y = 28;
  IDirect3DDevice9_SetFVF(dev, D3DFVF_XYZRHW | D3DFVF_DIFFUSE);
  IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
  IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
  IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, FALSE);
  LARGE_INTEGER freq, start, end, a, b;
  QueryPerformanceFrequency(&freq);
  double total = 0, lock = 0, unlock = 0;
  int frames = 8;
  for (int frame = 0; frame < frames + 2; frame++) {
    MSG msg;
    while (PeekMessageA(&msg, 0, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageA(&msg);
    }
    QueryPerformanceCounter(&start);
    if (FAILED(IDirect3DDevice9_Clear(dev, 0, 0, D3DCLEAR_TARGET,
                                    0xff203040, 1, 0)) ||
        FAILED(IDirect3DDevice9_BeginScene(dev)))
      return 15;
    for (int i = 0; i < 2600; i++) {
      void *p = 0;
      QueryPerformanceCounter(&a);
      hr = IDirect3DVertexBuffer9_Lock(vb, 0, 420, &p, D3DLOCK_DISCARD);
      QueryPerformanceCounter(&b);
      if (FAILED(hr))
        return 4;
      if (frame >= 2)
        lock += secs(a, b, freq);
      memcpy(p, data, sizeof(data));
      QueryPerformanceCounter(&a);
      hr = IDirect3DVertexBuffer9_Unlock(vb);
      QueryPerformanceCounter(&b);
      if (FAILED(hr))
        return 16;
      if (frame >= 2)
        unlock += secs(a, b, freq);
      if (FAILED(IDirect3DDevice9_SetStreamSource(dev, 0, vb, 0,
                                                  sizeof(struct V))) ||
          FAILED(IDirect3DDevice9_DrawPrimitive(dev, D3DPT_TRIANGLELIST, 0, 1)))
        return 5;
    }
    if (FAILED(IDirect3DDevice9_EndScene(dev)))
      return 6;
    if (frame == frames + 1) {
      IDirect3DSurface9 *rt = 0, *copy = 0;
      D3DSURFACE_DESC desc;
      D3DLOCKED_RECT bits;
      if (FAILED(IDirect3DDevice9_GetRenderTarget(dev, 0, &rt)))
        return 7;
      if (FAILED(IDirect3DSurface9_GetDesc(rt, &desc)))
        return 8;
      if (desc.Format != D3DFMT_X8R8G8B8 && desc.Format != D3DFMT_A8R8G8B8)
        return 9;
      if (FAILED(IDirect3DDevice9_CreateOffscreenPlainSurface(
              dev, desc.Width, desc.Height, desc.Format, D3DPOOL_SYSTEMMEM,
              &copy, 0)))
        return 10;
      if (FAILED(IDirect3DDevice9_GetRenderTargetData(dev, rt, copy)))
        return 11;
      if (FAILED(IDirect3DSurface9_LockRect(copy, &bits, 0, D3DLOCK_READONLY)))
        return 12;
      DWORD pixel = *(DWORD *)((BYTE *)bits.pBits + 22 * bits.Pitch + 22 * 4);
      DWORD background =
          *(DWORD *)((BYTE *)bits.pBits + 100 * bits.Pitch + 100 * 4);
      IDirect3DSurface9_UnlockRect(copy);
      IDirect3DSurface9_Release(copy);
      IDirect3DSurface9_Release(rt);
      printf("READBACK triangle=%08lx background=%08lx\n", (long)pixel,
             (long)background);
      if ((pixel & 0xffffff) != 0xff8000 || (background & 0xffffff) != 0x203040)
        return 13;
    }
    if (FAILED(IDirect3DDevice9_Present(dev, 0, 0, 0, 0)))
      return 14;
    QueryPerformanceCounter(&end);
    double t = secs(start, end, freq);
    if (frame >= 2)
      total += t;
    printf("frame %d %.6f s\n", frame, t);
    fflush(stdout);
  }
  printf("RESULT frames=%d draws_per_frame=2600 buffer_bytes=420 fps=%.2f "
         "lock_us=%.1f unlock_us=%.1f\n",
         frames, frames / total, lock * 1e6 / (frames * 2600),
         unlock * 1e6 / (frames * 2600));
  IDirect3DVertexBuffer9_Release(vb);
  IDirect3DDevice9_Release(dev);
  IDirect3D9_Release(d);
  DestroyWindow(h);
  return 0;
}
