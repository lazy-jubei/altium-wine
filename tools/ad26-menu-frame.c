/* Hide the light nonclient edge of Altium's custom popup menus under Wine. */
#include <windows.h>
#include <wchar.h>

static const WCHAR region_property[] = L"AltiumWine.PopupMenuFrame";

static BOOL belongs_to_altium(HWND window)
{
    DWORD pid = 0, length = MAX_PATH;
    WCHAR path[MAX_PATH];
    if (!GetWindowThreadProcessId(window, &pid)) return FALSE;
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) return FALSE;
    BOOL read = QueryFullProcessImageNameW(process, 0, path, &length);
    CloseHandle(process);
    if (!read) return FALSE;
    const WCHAR *name = wcsrchr(path, L'\\');
    return name && !_wcsicmp(name + 1, L"X2.EXE");
}

static void trim_popup_frame(HWND window)
{
    WCHAR class_name[64];
    if (!IsWindowVisible(window) || !GetClassNameW(window, class_name, 64)
            || wcscmp(class_name, L"TxpBarSubMenuControl") || !belongs_to_altium(window)) return;

    /* Keep the client area and hit coordinates unchanged. Leave any region
       supplied by the application alone. */
    RECT frame, client;
    if (!GetWindowRect(window, &frame) || !GetClientRect(window, &client)) return;
    MapWindowPoints(window, NULL, (POINT *)&client, 2);
    OffsetRect(&client, -frame.left, -frame.top);
    if (client.left != 1 || client.top != 1 || frame.right - frame.left - client.right != 1
            || frame.bottom - frame.top - client.bottom != 1) return;

    RECT existing;
    int shape = GetWindowRgnBox(window, &existing);
    if (shape != ERROR && (!GetPropW(window, region_property) || EqualRect(&existing, &client))) return;
    HRGN region = CreateRectRgnIndirect(&client);
    if (!region) return;
    if (SetWindowRgn(window, region, TRUE)) SetPropW(window, region_property, (HANDLE)1);
    else DeleteObject(region);
}

static void CALLBACK window_event(HWINEVENTHOOK hook, DWORD event, HWND window,
        LONG object, LONG child, DWORD thread, DWORD time)
{
    if (object == OBJID_WINDOW && child == CHILDID_SELF) trim_popup_frame(window);
}

static BOOL CALLBACK existing_window(HWND window, LPARAM unused)
{
    trim_popup_frame(window);
    return TRUE;
}

int main(void)
{
    SetProcessDPIAware();
    HWINEVENTHOOK show = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, NULL,
            window_event, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    HWINEVENTHOOK move = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, NULL,
            window_event, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    if (!show || !move) return 1;
    EnumWindows(existing_window, 0);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) DispatchMessageW(&msg);
    UnhookWinEvent(move);
    UnhookWinEvent(show);
    return 0;
}
