/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Visual regression: partial/scaled presents, edge clipping, refresh and resize.
 * Build: i686-w64-mingw32-clang -O2 d3d9-partial-present.c -o partial-present-test.exe
 * Run: partial-present-test.exe FULL_PATH_TO_D3D9_DLL [4 for MSAA compatibility]
 * Checks front-buffer pixels automatically; capture each FRAME within two seconds
 * to check actual display output too. The borderless client is 512x384,
 * then 640x480. Verify the red and green rectangles retain the blue background.
 * MSAA uses DISCARD to exercise Altium's tolerated partial-present behavior;
 * the default COPY case follows the D3D9 contract.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d9.h>
#include <stdio.h>
#include <stdlib.h>

static IDirect3DDevice9 *device;
static D3DPRESENT_PARAMETERS params;
static unsigned frame;
static int failed;
static BOOL resized;

static void check_front_buffer(unsigned stage) {
    IDirect3DSurface9 *copy = NULL;
    HRESULT result = IDirect3DDevice9_CreateOffscreenPlainSurface(device,
        params.BackBufferWidth, params.BackBufferHeight, D3DFMT_A8R8G8B8,
        D3DPOOL_SYSTEMMEM, &copy, NULL);
    if (SUCCEEDED(result)) result = IDirect3DDevice9_GetFrontBufferData(device, 0, copy);
    D3DLOCKED_RECT bits;
    if (SUCCEEDED(result)) result = IDirect3DSurface9_LockRect(copy, &bits, NULL, D3DLOCK_READONLY);
    if (SUCCEEDED(result)) {
        POINT points[] = {{10, 10}, {220, 120}, {320, 220},
            {(LONG)params.BackBufferWidth - 10, (LONG)params.BackBufferHeight - 10}};
        for (unsigned i = 0; i < 4; i++) {
            DWORD want = stage == 3 ? 0x704090 : 0x204080;
            if ((stage == 1 || stage == 2 || stage >= 5) && i == 1) want = 0xc03020;
            if (stage >= 6 && i == 0) want = 0xc03020;
            if ((stage == 2 && i == 2) || (stage == 7 && i == 3)) want = 0x20b050;
            DWORD got = *(DWORD *)((BYTE *)bits.pBits + points[i].y * bits.Pitch + points[i].x * 4);
            if ((got & 0xffffff) != want) {
                printf("FAIL front buffer stage %u point %u: %06lx != %06lx\n",
                    stage, i, got & 0xffffff, want);
                failed = 1;
            }
        }
        IDirect3DSurface9_UnlockRect(copy);
    } else { printf("FAIL front buffer readback %08lx\n", result); failed = 1; }
    if (copy) IDirect3DSurface9_Release(copy);
}

static LRESULT CALLBACK proc(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_TIMER) {
        RECT source = {200, 100, 240, 140}, dest = source;
        DWORD colour = 0xff204080;
        BOOL partial = frame == 1 || frame == 2 || frame >= 5;
        if (frame == 8) { DestroyWindow(window); return 0; }
        if (frame == 4 && !resized) {
            SetWindowPos(window, NULL, 0, 0, 640, 480, SWP_NOMOVE | SWP_NOZORDER);
            params.BackBufferWidth = 640; params.BackBufferHeight = 480;
            HRESULT result = IDirect3DDevice9_Reset(device, &params);
            if (FAILED(result)) { failed = 1; DestroyWindow(window); return 0; }
            resized = TRUE;
            return 0; /* Let the native window finish resizing before drawing. */
        }
        if (frame == 1 || frame == 5) colour = 0xffc03020;
        if (frame == 2) {
            colour = 0xff20b050;
            source = (RECT){0, 0, 20, 20}; dest = (RECT){300, 200, 340, 240};
        }
        if (frame == 6) {
            colour = 0xffc03020; source = dest = (RECT){-10, -10, 30, 30};
        }
        if (frame == 7) {
            colour = 0xff20b050; source = dest = (RECT){620, 460, 660, 500};
        }
        if (frame == 3) colour = 0xff704090;
        HRESULT result = IDirect3DDevice9_Clear(device, 0, NULL, D3DCLEAR_TARGET, colour, 1, 0);
        if (SUCCEEDED(result)) result = IDirect3DDevice9_Present(device,
            partial ? &source : NULL, partial ? &dest : NULL, NULL, NULL);
        if (FAILED(result)) { failed = 1; DestroyWindow(window); return 0; }
        check_front_buffer(frame);
        printf("FRAME %u %u %u\n", frame++, params.BackBufferWidth, params.BackBufferHeight);
        fflush(stdout);
        return 0;
    }
    if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(window, message, w, l);
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) return 1;
    SetProcessDPIAware();
    HMODULE module = LoadLibraryA(argv[1]);
    if (!module) return 1;
    IDirect3D9 *(WINAPI *create)(UINT) = (void *)GetProcAddress(module, "Direct3DCreate9");
    if (!create) return 1;
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = proc; wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "PartialPresentRegression";
    if (!RegisterClassA(&wc)) return 1;
    HWND window = CreateWindowA(wc.lpszClassName, "Partial present regression",
        WS_POPUP | WS_VISIBLE, 320, 320, 512, 384, NULL, NULL, wc.hInstance, NULL);
    IDirect3D9 *d3d = create(D3D_SDK_VERSION);
    if (!window || !d3d) return 1;
    params.Windowed = TRUE; params.hDeviceWindow = window; params.BackBufferCount = 1;
    params.BackBufferWidth = 512; params.BackBufferHeight = 384;
    params.BackBufferFormat = D3DFMT_X8R8G8B8;
    params.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;
    params.MultiSampleType = argc == 3 && atoi(argv[2]) == 4
        ? D3DMULTISAMPLE_4_SAMPLES : D3DMULTISAMPLE_NONE;
    params.SwapEffect = params.MultiSampleType ? D3DSWAPEFFECT_DISCARD : D3DSWAPEFFECT_COPY;
    HRESULT result = IDirect3D9_CreateDevice(d3d, 0, D3DDEVTYPE_HAL, window,
        D3DCREATE_HARDWARE_VERTEXPROCESSING | D3DCREATE_FPU_PRESERVE, &params, &device);
    if (FAILED(result)) return 1;
    SetTimer(window, 1, 2000, NULL);
    MSG message;
    while (GetMessageA(&message, NULL, 0, 0) > 0) {
        TranslateMessage(&message); DispatchMessageA(&message);
    }
    IDirect3DDevice9_Release(device); IDirect3D9_Release(d3d); FreeLibrary(module);
    if (frame != 8) failed = 1;
    printf("%s front-buffer retention and resize\n", failed ? "FAIL" : "PASS");
    return failed;
}
