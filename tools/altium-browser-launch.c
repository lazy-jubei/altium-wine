/* Manage Wine setup and forward Altium sign-in to the host-browser bridge.
 * Install beside X2.EXE as cmd.exe. Other cmd invocations go to Wine's real cmd.exe.
 */
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

static DWORD run_system_program(const wchar_t *name, wchar_t *command, BOOL wait)
{
    wchar_t executable[MAX_PATH];
    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process;
    DWORD result = 0;
    UINT length = GetSystemDirectoryW(executable, MAX_PATH);
    if (!length || length + wcslen(name) + 2 > MAX_PATH)
        return ERROR_INSUFFICIENT_BUFFER;
    executable[length++] = L'\\';
    wcscpy(executable + length, name);
    if (!CreateProcessW(executable, command, NULL, NULL, wait, 0, NULL, NULL, &startup, &process))
        return GetLastError();
    CloseHandle(process.hThread);
    if (wait) {
        WaitForSingleObject(process.hProcess, INFINITE);
        if (!GetExitCodeProcess(process.hProcess, &result))
            result = GetLastError();
    }
    CloseHandle(process.hProcess);
    return result;
}

static DWORD open_altium_url(const wchar_t *url)
{
    static const wchar_t prefix[] = L"winebrowser.exe \"";
    size_t length = wcslen(url) + sizeof(prefix) / sizeof(*prefix) + 1;
    wchar_t *command = malloc(length * sizeof(*command));
    wchar_t *dest;
    DWORD code;

    if (!command)
        return ERROR_OUTOFMEMORY;
    wcscpy(command, prefix);
    dest = command + wcslen(command);
    /* Altium escapes separators for cmd. winebrowser expects the actual URL. */
    while (*url) {
        if (*url == L'^' && url[1] == L'&')
            ++url;
        if (*url <= L' ' || *url == L'"') {
            free(command);
            return ERROR_INVALID_PARAMETER;
        }
        *dest++ = *url++;
    }
    *dest++ = L'"';
    *dest = 0;
    code = run_system_program(L"winebrowser.exe", command, FALSE);
    free(command);
    return code;
}

static DWORD setup_on_desktop(const wchar_t *exe)
{
    wchar_t desktop[64];
    DWORD required, result = 0;
    size_t length = wcslen(exe) + 3;
    wchar_t *command;
    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process;

    if (!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME,
            desktop, sizeof(desktop), &required) || wcscmp(desktop, L"Altium-Setup"))
        return ERROR_INVALID_PARAMETER;
    command = malloc(length * sizeof(*command));
    if (!command) {
        result = ERROR_OUTOFMEMORY;
    } else {
        swprintf(command, length, L"\"%ls\"", exe);
        if (!CreateProcessW(exe, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
            result = GetLastError();
        } else {
            CloseHandle(process.hThread);
            WaitForSingleObject(process.hProcess, INFINITE);
            if (!GetExitCodeProcess(process.hProcess, &result))
                result = GetLastError();
            CloseHandle(process.hProcess);
        }
        free(command);
    }
    PostMessageW(GetDesktopWindow(), WM_CLOSE, 0, 0);
    return result;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, wchar_t *command, int show)
{
    static const wchar_t authorize[] = L"https://auth.altium.com/connect/authorize?";
    int argc;
    DWORD result;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv)
        return GetLastError();
    if (argc == 3 && !wcscmp(argv[1], L"--setup-desktop")) {
        result = setup_on_desktop(argv[2]);
    } else if (argc == 4 && !_wcsicmp(argv[1], L"/c") && !_wcsicmp(argv[2], L"start") &&
            !wcsncmp(argv[3], authorize, wcslen(authorize))) {
        result = open_altium_url(argv[3]);
    } else {
        wchar_t *original = _wcsdup(GetCommandLineW());
        result = original ? run_system_program(L"cmd.exe", original, TRUE) : ERROR_OUTOFMEMORY;
        free(original);
    }
    LocalFree(argv);
    return result;
}
