/* Manage Wine setup and forward Altium sign-in to the host-browser bridge.
 * Used as cmd.exe by setup and Designer. Other cmd invocations go to Wine's cmd.exe.
 */
#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>
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

static const wchar_t *setup_executable;
static BOOL setup_hide_overlays;
static BOOL setup_online;
static wchar_t setup_browser_bridge[MAX_PATH];

static void prepare_setup_browser(DWORD pid)
{
    MODULEENTRY32W module = { .dwSize = sizeof(module) };
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, pid);
    wchar_t source[MAX_PATH], *name;
    DWORD attributes, length;

    if (snapshot == INVALID_HANDLE_VALUE)
        return;
    for (BOOL found = Module32FirstW(snapshot, &module); found;
            found = Module32NextW(snapshot, &module)) {
        if (_wcsicmp(module.szModule, L"AltiumDesigner.dll"))
            continue;
        name = wcsrchr(module.szExePath, L'\\');
        if (!name || ARRAYSIZE(module.szExePath) - (name + 1 - module.szExePath) <
                ARRAYSIZE(L"Authorizer.exe"))
            break;
        /* Authorizer runs from the unpacked installer components. Windows
         * searches that directory for cmd before falling back to the system cmd. */
        wcscpy(++name, L"Authorizer.exe");
        attributes = GetFileAttributesW(module.szExePath);
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY))
            break;
        wcscpy(name, L"cmd.exe");
        length = GetModuleFileNameW(NULL, source, ARRAYSIZE(source));
        if (length && length < ARRAYSIZE(source) && CopyFileW(source, module.szExePath, TRUE))
            wcscpy(setup_browser_bridge, module.szExePath);
        break;
    }
    CloseHandle(snapshot);
}

static void CALLBACK setup_window_shown(HWINEVENTHOOK hook, DWORD event, HWND window,
        LONG object, LONG child, DWORD thread, DWORD time)
{
    wchar_t class_name[64], path[MAX_PATH];
    DWORD pid, length = MAX_PATH;
    HANDLE process;
    BOOL prepare_browser, hide_overlay;

    if (object != OBJID_WINDOW || child != CHILDID_SELF || !IsWindowVisible(window) ||
            !GetClassNameW(window, class_name, ARRAYSIZE(class_name)))
        return;

    prepare_browser = setup_online && !setup_browser_bridge[0] &&
            (!wcscmp(class_name, L"TInstallerForm") || !wcscmp(class_name, L"TSignInUnifiedForm"));
    hide_overlay = setup_hide_overlays &&
            (!wcscmp(class_name, L"TBehindWindow") || !wcscmp(class_name, L"TVeilWindow")) &&
            GetClassNameW(GetWindow(window, GW_OWNER), class_name, ARRAYSIZE(class_name)) &&
            !wcscmp(class_name, L"TInstallerForm");
    if (!prepare_browser && !hide_overlay)
        return;
    if (!GetWindowThreadProcessId(window, &pid))
        return;
    process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process)
        return;
    if (QueryFullProcessImageNameW(process, 0, path, &length) && !_wcsicmp(path, setup_executable)) {
        if (prepare_browser)
            prepare_setup_browser(pid);
        else
            ShowWindowAsync(window, SW_HIDE);
    }
    CloseHandle(process);
}

static DWORD wait_for_setup(HANDLE process, BOOL events)
{
    DWORD result, ready;
    MSG message;

    if (events) {
        while ((ready = MsgWaitForMultipleObjects(1, &process, FALSE, INFINITE,
                QS_ALLINPUT)) == WAIT_OBJECT_0 + 1) {
            while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE))
                DispatchMessageW(&message);
        }
    } else {
        ready = WaitForSingleObject(process, INFINITE);
    }
    if (ready != WAIT_OBJECT_0 || !GetExitCodeProcess(process, &result))
        return GetLastError();
    return result;
}

static DWORD run_setup(const wchar_t *exe, BOOL desktop_mode, BOOL hide_overlays, BOOL online)
{
    wchar_t desktop[64];
    DWORD required, result = 0;
    size_t length = wcslen(exe) + 3;
    wchar_t *command;
    HWINEVENTHOOK hook = NULL;
    STARTUPINFOW startup = { .cb = sizeof(startup) };
    PROCESS_INFORMATION process;

    if (desktop_mode && (!GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME,
            desktop, sizeof(desktop), &required) || wcscmp(desktop, L"Altium-Setup")))
        return ERROR_INVALID_PARAMETER;
    if (hide_overlays || online) {
        /* The installer dims the owner and draws a glow in separate windows.
         * An X11 compositor can stack either one over the actual modal dialog. */
        setup_executable = exe;
        setup_hide_overlays = hide_overlays;
        setup_online = online;
        hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, NULL,
                setup_window_shown, 0, 0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        if (!hook)
            return ERROR_FUNCTION_FAILED;
    }

    command = malloc(length * sizeof(*command));
    if (!command) {
        result = ERROR_OUTOFMEMORY;
    } else {
        swprintf(command, length, L"\"%ls\"", exe);
        if (!CreateProcessW(exe, command, NULL, NULL, FALSE, 0, NULL, NULL, &startup, &process)) {
            result = GetLastError();
        } else {
            CloseHandle(process.hThread);
            result = wait_for_setup(process.hProcess, hook != NULL);
            CloseHandle(process.hProcess);
        }
        free(command);
    }
    if (hook)
        UnhookWinEvent(hook);
    if (setup_browser_bridge[0])
        DeleteFileW(setup_browser_bridge);
    if (desktop_mode)
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
    if (argc == 3 && !wcscmp(argv[1], L"--setup-online")) {
        result = run_setup(argv[2], FALSE, FALSE, TRUE);
    } else if ((argc == 3 || (argc == 4 && !wcscmp(argv[3], L"--online"))) &&
            (!wcscmp(argv[1], L"--setup-desktop") || !wcscmp(argv[1], L"--setup-native"))) {
        BOOL desktop_mode = !wcscmp(argv[1], L"--setup-desktop");
        result = run_setup(argv[2], desktop_mode, !desktop_mode, argc == 4);
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
