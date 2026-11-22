/* D3D11/GDI child composition regression. LGPL-2.1-or-later.
 * Self-authored visible test; no Altium installation or project is used.
 * --self-test pauses on a blue frame, covers the viewport, then uncovers it
 * and presents exactly one green frame. The transparent child's corner must
 * become green while its yellow circle remains. Exit 0 means both matched.
 * --late-child-test additionally creates the transparent child after the GPU
 * pauses. Without either switch, Space pauses/resumes and Esc closes.
 * This checks the optional Wine Metal/GDI bridge, not a universal GetPixel
 * contract for every Windows GPU renderer or compositor.
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <string.h>

static ID3D11Device *device;
static ID3D11DeviceContext *context;
static IDXGISwapChain *swapchain;
static ID3D11RenderTargetView *target;
static HWND viewport, opaque, transparent, cover;
static unsigned paints[2], frames;
static BOOL paused;
static BOOL self_test;
static BOOL late_child;
static unsigned timer_count;
static int test_result;

static void print_region(void)
{
    const DWORD flags[] = {DCX_CACHE | DCX_CLIPSIBLINGS, DCX_CACHE | DCX_CLIPSIBLINGS | DCX_CLIPCHILDREN};
    for (unsigned i = 0; i < 2; i++)
    {
        HDC dc = GetDCEx(viewport, NULL, flags[i]);
        HRGN region = CreateRectRgn(0, 0, 0, 0);
        RECT box, child;
        POINT origin;
        int result = GetRandomRgn(dc, region, SYSRGN);
        GetRgnBox(region, &box);
        GetDCOrgEx(dc, &origin);
        GetWindowRect(transparent, &child);
        int x = (child.left + child.right) / 2, y = (child.top + child.bottom) / 2;
        printf("region flags=%lx result=%d box=%ld,%ld,%ld,%ld origin=%ld,%ld transparent-center=%d,%d screen-inside=%d client-inside=%d\n",
               flags[i], result, box.left, box.top, box.right, box.bottom, origin.x, origin.y, x, y,
               PtInRegion(region, x, y), PtInRegion(region, x - origin.x, y - origin.y));
        DeleteObject(region);
        ReleaseDC(viewport, dc);
    }
    fflush(stdout);
}

static LRESULT CALLBACK child_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_ERASEBKGND) return 1;
    if (msg == WM_PAINT)
    {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT rect;
        BOOL is_transparent = !!(GetWindowLongPtrW(hwnd, GWL_EXSTYLE) & WS_EX_TRANSPARENT);
        GetClientRect(hwnd, &rect);
        if (is_transparent)
        {
            HBRUSH brush = CreateSolidBrush(RGB(240, 220, 20));
            HGDIOBJ old = SelectObject(dc, brush);
            Ellipse(dc, 4, 4, rect.right - 4, rect.bottom - 4);
            SelectObject(dc, old);
            DeleteObject(brush);
            SetBkMode(dc, TRANSPARENT);
            DrawTextW(dc, L"GDI circle", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        else
        {
            HBRUSH brush = CreateSolidBrush(RGB(220, 40, 40));
            FillRect(dc, &rect, brush);
            DeleteObject(brush);
            SetBkMode(dc, TRANSPARENT);
            SetTextColor(dc, RGB(255, 255, 255));
            DrawTextW(dc, L"GDI rectangle", -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        }
        paints[is_transparent]++;
        EndPaint(hwnd, &ps);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static LRESULT CALLBACK cover_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
 if(msg==WM_PAINT) {
  PAINTSTRUCT ps; HDC dc=BeginPaint(hwnd,&ps); RECT rc;GetClientRect(hwnd,&rc);
  HBRUSH b=CreateSolidBrush(RGB(48,48,48));FillRect(dc,&rc,b);DeleteObject(b);
  SetTextColor(dc,RGB(255,255,255));SetBkMode(dc,TRANSPARENT);
  DrawTextW(dc,L"HOME COVER",-1,&rc,DT_CENTER|DT_VCENTER|DT_SINGLELINE);
  EndPaint(hwnd,&ps);return 0;
 }
 return DefWindowProcW(hwnd,msg,wp,lp);
}

static LRESULT CALLBACK main_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg)
    {
    case WM_KEYDOWN:
        if (wp == VK_SPACE)
        {
            paused = !paused;
            HDC dc = GetDC(transparent);
            printf("pause=%d frames=%u paints=%u,%u transparent-corner=%08lx center=%08lx\n",
                   paused, frames, paints[0], paints[1], GetPixel(dc, 0, 0), GetPixel(dc, 80, 80));
            ReleaseDC(transparent, dc);
            fflush(stdout);
        }
        if (wp == VK_ESCAPE) DestroyWindow(hwnd);
        return 0;
    case WM_TIMER:
        timer_count++;
        if(timer_count==145) {
            cover=CreateWindowW(L"BackingCoverFixture",L"",WS_CHILD|WS_VISIBLE,20,20,820,500,hwnd,0,GetModuleHandleW(0),0);
            UpdateWindow(cover); printf("cover-shown frame=%u\n",frames);fflush(stdout);
        }
        if(timer_count==155) {
            DestroyWindow(cover);cover=0;
            const FLOAT final_color[4]={0.04f,0.65f,0.18f,1.0f};
            ID3D11DeviceContext_ClearRenderTargetView(context,target,final_color);
            IDXGISwapChain_Present(swapchain,0,0); frames++;
            RedrawWindow(transparent,NULL,0,RDW_INVALIDATE|RDW_NOERASE|RDW_UPDATENOW);
            printf("cover-removed frame=%u\n",frames);fflush(stdout);
        }
        if(late_child && timer_count==130) ShowWindow(transparent,SW_SHOW);
        if (self_test && timer_count == 120) paused = TRUE;
        if (!paused && target)
        {
            const FLOAT color[4] = {0.04f, 0.18f, 0.65f, 1.0f};
            ID3D11DeviceContext_ClearRenderTargetView(context, target, color);
            IDXGISwapChain_Present(swapchain, 0, 0);
            frames++;
            if (frames == 60) print_region();
        }
        InvalidateRect(opaque, NULL, FALSE);
        if (!late_child || timer_count < 130) InvalidateRect(transparent, NULL, FALSE);
        if (!(timer_count % 120))
        {
            printf("tick=%llu frames=%u opaque-paints=%u transparent-paints=%u paused=%d\n",
                   GetTickCount64(), frames, paints[0], paints[1], paused);
            fflush(stdout);
        }
        if (self_test && timer_count == 180)
        {
            HDC dc = GetDC(transparent);
            COLORREF corner = GetPixel(dc, 0, 0), center = GetPixel(dc, 80, 80);
            ReleaseDC(transparent, dc);
            test_result = !(GetRValue(corner) < 30 && GetBValue(corner) > 30 &&
                            GetBValue(corner) < 60 && GetGValue(corner) > 140 &&
                            GetRValue(center) > 200 && GetGValue(center) > 200 && GetBValue(center) < 40);
            printf("self-test frames=%u paints=%u,%u corner=%08lx center=%08lx green-background=%d\n",
                   frames, paints[0], paints[1], corner, center, !test_result);
            fflush(stdout);
            DestroyWindow(hwnd);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
    late_child = argc > 1 && !strcmp(argv[1], "--late-child-test");
    self_test = late_child || (argc > 1 && !strcmp(argv[1], "--self-test"));
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW wc = {.lpfnWndProc = main_proc, .hInstance = instance,
                   .hCursor = LoadCursorW(NULL, IDC_ARROW), .hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1),
                   .lpszClassName = L"SurfaceCompositionFixture"};
    RegisterClassW(&wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hbrBackground = NULL;
    wc.lpszClassName = L"D3DViewportFixture";
    RegisterClassW(&wc);
    wc.lpfnWndProc = child_proc;
    wc.hbrBackground = NULL;
    wc.lpszClassName = L"GDIChildFixture";
    RegisterClassW(&wc);
    wc.lpfnWndProc=cover_proc;wc.lpszClassName=L"BackingCoverFixture";RegisterClassW(&wc);
    HWND main = CreateWindowW(L"SurfaceCompositionFixture", L"GDI over D3D11 comparison - Space pauses GPU, Esc closes",
                              WS_OVERLAPPEDWINDOW | WS_VISIBLE, 140, 150, 900, 620,
                              NULL, NULL, instance, NULL);
    viewport = CreateWindowW(L"D3DViewportFixture", L"", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                              20, 20, 820, 500, main, NULL, instance, NULL);
    opaque = CreateWindowExW(0, L"GDIChildFixture", L"", WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS,
                              60, 80, 250, 130, viewport, NULL, instance, NULL);
    transparent = CreateWindowExW(WS_EX_TRANSPARENT, L"GDIChildFixture", L"", WS_CHILD | (late_child ? 0 : WS_VISIBLE) | WS_CLIPSIBLINGS,
                                   460, 240, 160, 160, viewport, NULL, instance, NULL);
    DXGI_SWAP_CHAIN_DESC desc = {.BufferDesc = {.Width = 820, .Height = 500, .Format = DXGI_FORMAT_R8G8B8A8_UNORM},
                                .SampleDesc = {.Count = 1}, .BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT,
                                .BufferCount = 2, .OutputWindow = viewport, .Windowed = TRUE,
                                .SwapEffect = DXGI_SWAP_EFFECT_DISCARD};
    D3D_FEATURE_LEVEL level;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                              D3D11_SDK_VERSION, &desc, &swapchain, &device, &level, &context);
    printf("D3D11CreateDeviceAndSwapChain=%08lx level=%x\n", hr, level);
    fflush(stdout);
    if (FAILED(hr)) return 2;
    ID3D11Texture2D *buffer = NULL;
    hr = IDXGISwapChain_GetBuffer(swapchain, 0, &IID_ID3D11Texture2D, (void **)&buffer);
    if (FAILED(hr)) return 3;
    hr = ID3D11Device_CreateRenderTargetView(device, (ID3D11Resource *)buffer, NULL, &target);
    ID3D11Texture2D_Release(buffer);
    if (FAILED(hr)) return 4;
    SetTimer(main, 1, 30, NULL);
    const ULONGLONG end = GetTickCount64() + 600000;
    MSG msg;
    while (GetTickCount64() < end && GetMessageW(&msg, NULL, 0, 0) > 0)
    {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (IsWindow(main)) DestroyWindow(main);
    ID3D11RenderTargetView_Release(target);
    IDXGISwapChain_Release(swapchain);
    ID3D11DeviceContext_Release(context);
    ID3D11Device_Release(device);
    return test_result;
}
