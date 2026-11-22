/* Build: x86_64-w64-mingw32-clang retina-popup-frame.c -o retina-popup-frame.exe -lgdi32 */
#include <windows.h>
#include <stdio.h>

static LRESULT CALLBACK popup_proc(HWND window, UINT message, WPARAM wparam, LPARAM lparam)
{
    if (message == WM_NCCALCSIZE)
    {
        RECT *client = wparam ? &((NCCALCSIZE_PARAMS *)lparam)->rgrc[0] : (RECT *)lparam;
        InflateRect(client, -1, -1);
        return 0;
    }
    if (message == WM_NCPAINT)
    {
        RECT frame;
        GetWindowRect(window, &frame);
        OffsetRect(&frame, -frame.left, -frame.top);
        HDC dc = GetWindowDC(window);
        HBRUSH brush = CreateSolidBrush(RGB(28, 28, 28));
        FrameRect(dc, &frame, brush);
        DeleteObject(brush);
        ReleaseDC(window, dc);
        return 0;
    }
    if (message == WM_PAINT)
    {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(window, &paint);
        HBRUSH brush = CreateSolidBrush(RGB(62, 62, 62));
        FillRect(dc, &paint.rcPaint, brush);
        DeleteObject(brush);
        EndPaint(window, &paint);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}

int main(void)
{
    SetProcessDPIAware();
    WNDCLASSW popup = {0};
    popup.hInstance = GetModuleHandleW(NULL);
    popup.lpfnWndProc = popup_proc;
    popup.lpszClassName = L"RetinaPopupFrameProbe";
    if (!RegisterClassW(&popup)) return 1;

    const struct
    {
        const WCHAR *name;
        int width, height;
        int inset;
        BOOL resized;
    } cases[] = {
        {L"Frame probe odd", 325, 105, -1, FALSE},
        {L"Frame probe even", 326, 106, -1, FALSE},
        {L"Frame probe shaped", 325, 105, 0, FALSE},
        {L"Frame probe inset", 325, 105, 8, FALSE},
        {L"Frame probe width", 325, 106, -1, FALSE},
        {L"Frame probe height", 326, 105, -1, FALSE},
        {L"Frame probe resized", 326, 106, -1, TRUE},
    };
    for (unsigned i = 0; i < ARRAYSIZE(cases); i++)
    {
        HWND window = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, popup.lpszClassName,
                cases[i].name, WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
                GetSystemMetrics(SM_CXSCREEN) - 360, 100 + 140 * i,
                cases[i].width - cases[i].resized, cases[i].height - cases[i].resized,
                NULL, NULL, popup.hInstance, NULL);
        if (!window) return 2;
        if (cases[i].inset >= 0)
        {
            int inset = cases[i].inset;
            HRGN region = CreateRectRgn(inset, inset, cases[i].width - inset, cases[i].height - inset);
            if (!region) return 3;
            if (!SetWindowRgn(window, region, FALSE))
            {
                DeleteObject(region);
                return 4;
            }
        }
        ShowWindow(window, SW_SHOWNOACTIVATE);
        UpdateWindow(window);
        if (cases[i].resized && !SetWindowPos(window, NULL, 0, 0, cases[i].width, cases[i].height,
                SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)) return 5;
        wprintf(L"%ls: %d x %d Win32 pixels\n", cases[i].name, cases[i].width, cases[i].height);
    }
    fflush(stdout);
    ULONGLONG until = GetTickCount64() + 20000;
    while (GetTickCount64() < until)
    {
        MSG message;
        while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
            DispatchMessageW(&message);
        Sleep(10);
    }
    return 0;
}
