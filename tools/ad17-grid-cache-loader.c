/* Copyright 2026 lazy-jubei. SPDX-License-Identifier: MIT
 * Load the optional grid helper in AD17 without suspending its GUI thread.
 */
#include <stdint.h>
#include <stdio.h>
#include <windows.h>
#include <tlhelp32.h>
#include <wchar.h>

static int load(DWORD pid, const wchar_t *path) {
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, pid);
  if (snapshot == INVALID_HANDLE_VALUE)
    return 0;
  MODULEENTRY32W m = {.dwSize = sizeof(m)};
  HMODULE kernel = NULL;
  int pcb = 0, core = 0, d3d = 0, target = 0, loaded = 0;
  const wchar_t *name = wcsrchr(path, L'\\');
  name = name ? name + 1 : path;
  if (Module32FirstW(snapshot, &m))
    do {
      if (!_wcsicmp(m.szModule, L"DXP.EXE"))
        target = 1;
      if (!_wcsicmp(m.szModule, L"kernel32.dll"))
        kernel = m.hModule;
      if (!_wcsicmp(m.szModule, L"ADVPCB.DLL"))
        pcb = 1;
      if (!_wcsicmp(m.szModule, L"Core3D.dll"))
        core = 1;
      if (!_wcsicmp(m.szModule, L"d3d9.dll"))
        d3d = 1;
      if (!_wcsicmp(m.szModule, name))
        loaded = 1;
    } while (Module32NextW(snapshot, &m));
  CloseHandle(snapshot);
  if (loaded)
    return 1;
  if (!target || !pcb || !core || !d3d ||
      kernel != GetModuleHandleW(L"kernel32.dll"))
    return 0;
  HANDLE process = OpenProcess(PROCESS_CREATE_THREAD | PROCESS_VM_OPERATION |
                                   PROCESS_VM_WRITE | PROCESS_QUERY_INFORMATION,
                               FALSE, pid);
  if (!process)
    return 0;
  SIZE_T size = (wcslen(path) + 1) * sizeof(wchar_t);
  void *remote = VirtualAllocEx(process, NULL, size, MEM_COMMIT | MEM_RESERVE,
                                PAGE_READWRITE);
  int result = 0;
  HANDLE thread = NULL;
  if (remote && WriteProcessMemory(process, remote, path, size, NULL))
    thread = CreateRemoteThread(process, NULL, 0,
                                (LPTHREAD_START_ROUTINE)(uintptr_t)LoadLibraryW,
                                remote, 0, NULL);
  if (thread) {
    if (WaitForSingleObject(thread, 10000) == WAIT_OBJECT_0) {
      DWORD module = 0;
      if (GetExitCodeThread(thread, &module))
        result = module != 0;
    } else {
      /* LoadLibrary may still be reading the path. The process owns it now. */
      remote = NULL;
    }
    CloseHandle(thread);
  }
  if (remote)
    VirtualFreeEx(process, remote, 0, MEM_RELEASE);
  CloseHandle(process);
  return result;
}

int wmain(int argc, wchar_t **argv) {
  if (argc != 3 || wcscmp(argv[1], L"--watch")) {
    fputs("Usage: ad17-grid-cache-loader.exe --watch FULL_WINDOWS_DLL_PATH\n",
          stderr);
    return 2;
  }
  wchar_t path[32768];
  DWORD length = GetFullPathNameW(argv[2], 32768, path, NULL);
  if (!length || length >= 32768 ||
      GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES)
    return 2;
  for (unsigned i = 0; i < 600; i++) {
    HWND w = FindWindowW(L"TDocumentForm", NULL);
    DWORD pid = 0;
    wchar_t title[512];
    GetWindowThreadProcessId(w, &pid);
    GetWindowTextW(w, title, 512);
    DWORD_PTR response = 0;
    if (pid && wcsstr(title, L"(17.1)") && IsWindowEnabled(w) &&
        SendMessageTimeoutW(w, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 100,
                            &response) &&
        load(pid, path)) {
      UINT status = RegisterWindowMessageW(L"Codex.AD17.GridCache.20261024");
      for (unsigned attempt = 0; attempt < 240; attempt++) {
        response = 0;
        if (SendMessageTimeoutW(w, status, 102, 0x5ad1734,
                                SMTO_ABORTIFHUNG, 100, &response)) {
          if (response == 1) {
            /* A delayed install may have outlived the worker's timeout.
               Confirm the mode as well as the hooks before reporting success. */
            if (SendMessageTimeoutW(w, status, 4, 0x5ad1734,
                                    SMTO_ABORTIFHUNG, 100, &response) && response == 1) {
              printf("AD17 grid helper active in process %lu\n", pid);
              return 0;
            }
          } else if (response == 0) {
            /* Initial scene creation can temporarily stop the GUI pumping.
               The helper validates its bytes again before installing. */
            SendMessageTimeoutW(w, status, 900, 0x5ad1734,
                                SMTO_ABORTIFHUNG, 100, &response);
          }
        }
        Sleep(500);
      }
      fputs("Grid helper loaded but did not activate; renderer/module layout is unsupported or busy\n", stderr);
      return 1;
    }
    Sleep(1000);
  }
  fputs("No ready AD17.1 PCB renderer found within ten minutes\n", stderr);
  return 1;
}
