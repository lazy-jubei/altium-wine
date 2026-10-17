/* Keep WebView cleanup away from startup, modal dialogs and other Wine prefixes. */
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>
#include <stdio.h>
#include <string.h>

static BOOL image_is(HANDLE process, const WCHAR *name)
{
    WCHAR path[32768];
    DWORD length = sizeof(path) / sizeof(path[0]);
    WCHAR *base;
    if (!QueryFullProcessImageNameW(process, 0, path, &length)) return FALSE;
    base = wcsrchr(path, L'\\');
    return !_wcsicmp(base ? base + 1 : path, name);
}

int main(int argc, char **argv)
{
    BOOL cleanup = argc >= 2 && !strcmp(argv[1], "--cleanup");
    HWND window = FindWindowW(L"TDocumentForm", NULL);
    DWORD owner;
    DWORD_PTR result;
    HANDLE main_process, snapshot;
    PROCESSENTRY32W entry = {0};
    FILETIME now;
    FILETIME created, exited, kernel, user;
    char identity[64];
    ULARGE_INTEGER current;
    if (argc > 3 || (argc > 1 && !cleanup)) return 64;
    if (!window) return 3;
    GetWindowThreadProcessId(window, &owner);
    main_process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, owner);
    if (!main_process) return 1;
    if (!image_is(main_process, L"X2.EXE")) {
        CloseHandle(main_process);
        return 3;
    }
    if (!GetProcessTimes(main_process, &created, &exited, &kernel, &user)) {
        CloseHandle(main_process);
        return 1;
    }
    CloseHandle(main_process);
    snprintf(identity, sizeof(identity), "%lu:%08lx%08lx", owner,
             created.dwHighDateTime, created.dwLowDateTime);
    if (cleanup && argc == 3 && strcmp(identity, argv[2])) return 3;
    if (!cleanup) puts(identity);
    if (!IsWindowVisible(window) || !IsWindowEnabled(window) ||
        !SendMessageTimeoutW(window, WM_NULL, 0, 0,
            SMTO_ABORTIFHUNG | SMTO_BLOCK, 1000, &result)) return 1;
    if (!cleanup) return 0;

    /* Toolhelp sees only this prefix. Never kill processes using a global pgrep. */
    snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return 1;
    GetSystemTimeAsFileTime(&now);
    current.LowPart = now.dwLowDateTime; current.HighPart = now.dwHighDateTime;
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) do {
        HANDLE child;
        FILETIME created, exited, kernel, user;
        ULARGE_INTEGER birth;
        if (entry.th32ParentProcessID != owner ||
            _wcsicmp(entry.szExeFile, L"msedgewebview2.exe")) continue;
        child = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE,
                            FALSE, entry.th32ProcessID);
        if (!child) continue;
        if (image_is(child, L"msedgewebview2.exe") &&
            GetProcessTimes(child, &created, &exited, &kernel, &user)) {
            birth.LowPart = created.dwLowDateTime; birth.HighPart = created.dwHighDateTime;
            if (current.QuadPart >= birth.QuadPart &&
                current.QuadPart - birth.QuadPart >= 20ULL * 10000000 &&
                TerminateProcess(child, 0))
                printf("WebView2 cleanup: ended Altium browser (Windows pid %lu)\n", entry.th32ProcessID);
        }
        CloseHandle(child);
    } while (Process32NextW(snapshot, &entry));
    CloseHandle(snapshot);
    return 0;
}
