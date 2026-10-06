/* Cross-process GetWindowRect must agree with the window's owning process,
 * including negative coordinates at high DPI. Build as a Windows console exe. */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc == 7 && (!strcmp(argv[1], "read") || !strcmp(argv[1], "read96")))
    {
        if (!strcmp(argv[1], "read96")) SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_UNAWARE);
        HWND window = (HWND)(ULONG_PTR)strtoull(argv[2], NULL, 16);
        RECT rect;
        if (!GetWindowRect(window, &rect)) return 2;
        printf("foreign: %ld,%ld,%ld,%ld dpi=%u\n", rect.left, rect.top, rect.right, rect.bottom, GetDpiForWindow(window));
        return rect.left != strtol(argv[3], NULL, 10) || rect.top != strtol(argv[4], NULL, 10) ||
                rect.right != strtol(argv[5], NULL, 10) || rect.bottom != strtol(argv[6], NULL, 10);
    }
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "CoordinateProbe";
    if (!RegisterClassA(&wc)) return 3;
    const POINT cases[] = {{-3,25}, {-20,-30}, {20,-100}, {-10000,100}, {400,300}};
    char exe[MAX_PATH]; GetModuleFileNameA(NULL, exe, sizeof(exe));
    unsigned int failed = 0;
    for (unsigned int i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i)
    {
        HWND window = CreateWindowA(wc.lpszClassName, "coordinate test", WS_OVERLAPPEDWINDOW,
                cases[i].x, cases[i].y, 420, 300, NULL, NULL, wc.hInstance, NULL);
        RECT rect;
        if (!window || !GetWindowRect(window, &rect)) return 4;
        printf("owner:   %ld,%ld,%ld,%ld dpi=%u\n", rect.left, rect.top, rect.right, rect.bottom, GetDpiForWindow(window));
        fflush(stdout);
        char command[1024];
        UINT dpi = GetDpiForWindow(window);
        snprintf(command, sizeof(command), "\"%s\" read96 %llx %d %d %d %d", exe,
                (unsigned long long)(ULONG_PTR)window, MulDiv(rect.left, 96, dpi), MulDiv(rect.top, 96, dpi),
                MulDiv(rect.right, 96, dpi), MulDiv(rect.bottom, 96, dpi));
        STARTUPINFOA si = {0}; si.cb = sizeof(si);
        PROCESS_INFORMATION pi = {0};
        if (!CreateProcessA(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) return 5;
        DWORD result;
        if (WaitForSingleObject(pi.hProcess, 10000) != WAIT_OBJECT_0) return 6;
        GetExitCodeProcess(pi.hProcess, &result);
        failed += result != 0;
        CloseHandle(pi.hThread); CloseHandle(pi.hProcess); DestroyWindow(window);
    }
    printf("%s (%u/5 failures)\n", failed ? "FAIL" : "PASS", failed);
    return failed ? 1 : 0;
}
