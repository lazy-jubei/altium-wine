#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>

struct tab {
    HWND window, page;
    IDXGISwapChain *chain;
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    ID3D11RenderTargetView *target;
};

static const RECT canvas = {80, 44, 680, 400};
static HWND home, home_page, other_gdi, other_page, banner;
static struct tab blue, green;
static unsigned int tick;

static HRESULT prepare_canvas(struct tab *tab, HWND hwnd)
{
    DXGI_SWAP_CHAIN_DESC desc = {0};
    ID3D11Texture2D *buffer;
    HRESULT hr;

    tab->window = hwnd;
    desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 2;
    desc.OutputWindow = hwnd;
    desc.Windowed = TRUE;
    desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
        D3D11_SDK_VERSION, &desc, &tab->chain, &tab->device, NULL, &tab->context);
    if (FAILED(hr)) return hr;
    hr = IDXGISwapChain_GetBuffer(tab->chain, 0, &IID_ID3D11Texture2D, (void **)&buffer);
    if (FAILED(hr)) return hr;
    hr = ID3D11Device_CreateRenderTargetView(tab->device, (ID3D11Resource *)buffer, NULL, &tab->target);
    ID3D11Texture2D_Release(buffer);
    return hr;
}

static void present_canvas(struct tab *tab, const float color[4])
{
    ID3D11DeviceContext_ClearRenderTargetView(tab->context, tab->target, color);
    HRESULT hr = IDXGISwapChain_Present(tab->chain, 1, 0);
    if (FAILED(hr)) { printf("present failed %08lx\n", hr); PostQuitMessage(4); }
}

static void mark(const char *name)
{
    printf("%llu %s\n", (unsigned long long)GetTickCount64(), name);
}

static LRESULT CALLBACK gdi_proc(HWND window, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_PAINT)
    {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        COLORREF color = window == home ? RGB(205, 35, 30) : window == other_gdi ? RGB(215, 185, 45)
                                                         : (tick % 2 ? RGB(50, 58, 65) : RGB(75, 80, 85));
        HBRUSH brush = CreateSolidBrush(color);
        FillRect(dc, &paint.rcPaint, brush);
        DeleteObject(brush);
        EndPaint(window, &paint);
        if (window != banner) mark(window == home ? "home painted" : "other GDI painted");
        return 0;
    }
    return DefWindowProcW(window, msg, wp, lp);
}

static void paint_disconnected_strips(HWND window)
{
    RECT left = {0, 0, 65, 423}, right = {685, 0, 715, 423};
    HDC dc = GetDC(window);
    HBRUSH brush = CreateSolidBrush(RGB(92, 94, 98));
    FillRect(dc, &left, brush);
    FillRect(dc, &right, brush);
    DeleteObject(brush);
    ReleaseDC(window, dc);
    GdiFlush();
    mark("painted opposing strips, canvas untouched");
}

static LRESULT CALLBACK root_proc(HWND window, UINT msg, WPARAM wp, LPARAM lp)
{
    static const float blue_color[4] = {0.06f, 0.27f, 0.8f, 1.0f};
    static const float green_color[4] = {0.04f, 0.68f, 0.20f, 1.0f};
    if (msg == WM_TIMER)
    {
        ++tick;
        InvalidateRect(banner, NULL, FALSE);
        UpdateWindow(banner);
        switch (tick)
        {
        case 14:
            ShowWindow(home_page, SW_HIDE);
            ShowWindow(blue.page, SW_SHOWNA);
            mark("blue shown");
            break;
        case 26:
            ShowWindow(blue.page, SW_HIDE);
            mark("blue retired");
            paint_disconnected_strips(window);
            break;
        case 29:
            ShowWindow(green.page, SW_SHOWNA);
            mark("green shown");
            break;
        case 40:
            ShowWindow(green.page, SW_HIDE);
            mark("green retired");
            break;
        case 43:
            ShowWindow(other_page, SW_SHOWNA);
            UpdateWindow(other_gdi);
            break;
        case 52:
            ShowWindow(other_page, SW_HIDE);
            ShowWindow(blue.page, SW_SHOWNA);
            mark("blue shown again");
            break;
        case 62:
            ShowWindow(blue.page, SW_HIDE);
            mark("blue retired before explicit Home");
            break;
        case 65:
            ShowWindow(home_page, SW_SHOWNA);
            UpdateWindow(home);
            break;
        case 68:
            ShowWindow(home_page, SW_HIDE);
            ShowWindow(blue.page, SW_SHOWNA);
            mark("blue shown for unreplaced hide");
            break;
        case 70:
            ShowWindow(blue.page, SW_HIDE);
            mark("blue hidden with no replacement");
            break;
        case 78:
            PostQuitMessage(0);
            break;
        }
        if ((tick >= 14 && tick < 26) || (tick >= 52 && tick < 62) || (tick >= 68 && tick < 70)) present_canvas(&blue, blue_color);
        if (tick >= 29 && tick < 40) present_canvas(&green, green_color);
        return 0;
    }
    if (msg == WM_PAINT)
    {
        PAINTSTRUCT paint;
        BeginPaint(window, &paint);
        EndPaint(window, &paint);
        return 0;
    }
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(window, msg, wp, lp);
}

static HWND child(HWND parent, const WCHAR *class_name, const RECT *rect, BOOL visible)
{
    return CreateWindowW(class_name, NULL, WS_CHILD | WS_CLIPSIBLINGS | (visible ? WS_VISIBLE : 0),
        rect->left, rect->top, rect->right - rect->left, rect->bottom - rect->top,
        parent, NULL, GetModuleHandleW(NULL), NULL);
}

int main(void)
{
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW root_class = {.lpfnWndProc = root_proc, .hInstance = instance, .lpszClassName = L"CompositionProbe"};
    WNDCLASSW gdi_class = {.lpfnWndProc = gdi_proc, .hInstance = instance, .lpszClassName = L"CompositionGDIChild"};
    WNDCLASSW gpu_class = {.lpfnWndProc = DefWindowProcW, .hInstance = instance, .lpszClassName = L"CompositionGPUChild"};
    WNDCLASSW binder_class = {.lpfnWndProc = DefWindowProcW, .hInstance = instance, .lpszClassName = L"CompositionContainer"};
    WNDCLASSW page_class = {.lpfnWndProc = DefWindowProcW, .hInstance = instance, .lpszClassName = L"CompositionPage"};
    RECT banner_rect = {10, 10, 50, 400}, child_rect = {0, 0, 600, 356};
    MSG message;
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!RegisterClassW(&root_class) || !RegisterClassW(&gdi_class) || !RegisterClassW(&gpu_class) ||
        !RegisterClassW(&binder_class) || !RegisterClassW(&page_class)) return 1;
    HWND root = CreateWindowW(root_class.lpszClassName, L"Tab composition probe", WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        560, 260, 740, 470, NULL, NULL, instance, NULL);
    if (!root) return 2;
    HWND binder = child(root, binder_class.lpszClassName, &canvas, TRUE);
    home_page = child(binder, page_class.lpszClassName, &child_rect, TRUE);
    other_page = child(binder, page_class.lpszClassName, &child_rect, FALSE);
    blue.page = child(binder, page_class.lpszClassName, &child_rect, FALSE);
    green.page = child(binder, page_class.lpszClassName, &child_rect, FALSE);
    if (!binder || !home_page || !other_page || !blue.page || !green.page) return 2;
    home = child(home_page, gdi_class.lpszClassName, &child_rect, TRUE);
    other_gdi = child(other_page, gdi_class.lpszClassName, &child_rect, TRUE);
    banner = child(root, gdi_class.lpszClassName, &banner_rect, TRUE);
    HWND a = child(blue.page, gpu_class.lpszClassName, &child_rect, TRUE);
    HWND b = child(green.page, gpu_class.lpszClassName, &child_rect, TRUE);
    if (!home || !other_gdi || !banner || !a || !b) return 2;
    if (FAILED(prepare_canvas(&blue, a)) || FAILED(prepare_canvas(&green, b))) return 3;
    ShowWindow(root, SW_SHOWNA);
    UpdateWindow(home);
    SetTimer(root, 1, 130, NULL);
    while (GetMessageW(&message, NULL, 0, 0) > 0) DispatchMessageW(&message);
    return (int)message.wParam;
}
