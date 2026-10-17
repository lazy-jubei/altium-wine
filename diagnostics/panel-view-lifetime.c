/* Build as DXP.EXE or X2.EXE. Run in a disposable Wine prefix.
 * --baseline expects late deactivation; --fixed expects it before view detach.
 * This models the panel/view lifetime without loading Altium or a CAD file. */
#define _WIN32_WINNT 0x0a00
#include <windows.h>
#include <stdio.h>
#include <string.h>

static HWND owner, panel, container, view, edit;
static BOOL detached, testing, reenter;
static unsigned early, late, failures;

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (testing && hwnd == panel && msg == WM_ACTIVATE && LOWORD(wp) == WA_INACTIVE)
    {
        if (detached) ++late;
        else ++early;
        if (reenter && IsWindowVisible(view)) ShowWindow(view, SW_HIDE);
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void pump(void)
{
    DWORD start = GetTickCount();
    do
    {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    } while (GetTickCount() - start < 100);
}

static void setup(void)
{
    detached = testing = reenter = FALSE;
    owner = CreateWindowW(L"PanelTestOwner", L"Panel lifetime test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                          50, 50, 450, 300, NULL, NULL, GetModuleHandleW(NULL), NULL);
    panel = CreateWindowW(L"TClientBarControl", L"Test panel", WS_POPUP | WS_CAPTION | WS_VISIBLE,
                          80, 90, 300, 180, owner, NULL, GetModuleHandleW(NULL), NULL);
    container = CreateWindowW(L"STATIC", L"View container", WS_CHILD | WS_VISIBLE,
                              0, 0, 280, 120, panel, NULL, GetModuleHandleW(NULL), NULL);
    view = CreateWindowW(L"TViewComponent", L"Test view", WS_CHILD | WS_VISIBLE,
                         0, 0, 280, 120, container, NULL, GetModuleHandleW(NULL), NULL);
    edit = CreateWindowW(L"EDIT", L"Focused child", WS_CHILD | WS_VISIBLE,
                         5, 5, 200, 30, view, NULL, GetModuleHandleW(NULL), NULL);
    pump();
    SetActiveWindow(panel);
    SetFocus(edit);
    pump();
    if (GetActiveWindow() != panel || GetFocus() != edit) ++failures;
}

static void teardown(void)
{
    testing = FALSE;
    DestroyWindow(owner);
    pump();
}

int main(int argc, char **argv)
{
    BOOL fixed = argc == 2 && !strcmp(argv[1], "--fixed");
    if (argc != 2 || (!fixed && strcmp(argv[1], "--baseline"))) return 64;
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = window_proc;
    cls.hInstance = GetModuleHandleW(NULL);
    const WCHAR *names[] = {L"PanelTestOwner", L"TClientBarControl", L"TViewComponent"};
    for (unsigned i = 0; i < 3; ++i) { cls.lpszClassName = names[i]; RegisterClassW(&cls); }

    for (unsigned i = 0; i < 9; ++i)
    {
        setup();
        testing = TRUE;
        reenter = i == 6;
        if (i >= 7)
            SetWindowPos(container, NULL, 0, 0, 0, 0,
                         SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        if (i & 1) ShowWindow(view, SW_HIDE);
        else SetWindowPos(view, NULL, 0, 0, 0, 0,
                          SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        if ((GetActiveWindow() == owner) != fixed) ++failures;
        detached = TRUE; /* Altium removes the Delphi parent after hiding the view. */
        SetActiveWindow(owner);
        teardown();
    }

    setup();
    SetActiveWindow(owner);
    SetFocus(owner);
    ShowWindow(view, SW_HIDE);
    if (GetActiveWindow() != owner) ++failures; /* An inactive panel must not steal focus. */
    teardown();

    setup();
    EnableWindow(owner, FALSE);
    ShowWindow(view, SW_HIDE);
    if (GetActiveWindow() != panel) ++failures; /* Never activate a disabled owner. */
    EnableWindow(owner, TRUE);
    teardown();

    if (early != (fixed ? 9u : 0u) || late != (fixed ? 0u : 9u)) ++failures;
    printf("early=%u late=%u failures=%u\n", early, late, failures);
    return failures ? 1 : 0;
}
