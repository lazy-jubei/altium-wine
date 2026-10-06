/* Reproduce AD17's duplex overlapped-pipe / NULL-overlapped WriteFile race.
 * Build as 32-bit AltiumMS.exe to exercise the scoped kernelbase workaround.
 * --overlapped verifies that ordinary asynchronous writes still work.
 * No Altium code or files are used. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

#define BLOCK 61440
#define BLOCKS 64
static char pipe_name[128];
static BYTE read_ping;
static OVERLAPPED read_op;
static int async_writes;

static void fail(const char *operation, DWORD error)
{
    fprintf(stderr, "FAIL %s: error=%lu\n", operation, error);
    fflush(stderr);
    /* An unpatched NULL-overlapped WriteFile can return while its stack IOSB
     * is still live in ntdll. Exit immediately to avoid reusing that stack. */
    TerminateProcess(GetCurrentProcess(), 1);
}

static BYTE expected(DWORD offset)
{
    return (BYTE)((offset * 31u + (offset >> 8)) & 255);
}

static DWORD WINAPI client(void *unused)
{
    HANDLE pipe;
    BYTE buffer[8192], ping = 0x5a;
    DWORD done, offset = 0, i;
    (void)unused;
    pipe = CreateFileA(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, NULL,
                       OPEN_EXISTING, 0, NULL);
    if (pipe == INVALID_HANDLE_VALUE) fail("client open", GetLastError());
    Sleep(75);
    if (!WriteFile(pipe, &ping, 1, &done, NULL) || done != 1)
        fail("client ping", GetLastError());
    Sleep(225);
    while (offset < BLOCK * BLOCKS)
    {
        if (!ReadFile(pipe, buffer, sizeof(buffer), &done, NULL) || !done)
            fail("client read", GetLastError());
        for (i = 0; i < done; ++i)
            if (buffer[i] != expected(offset + i)) fail("payload mismatch", offset + i);
        offset += done;
    }
    CloseHandle(pipe);
    return offset;
}

int main(int argc, char **argv)
{
    HANDLE pipe, thread;
    OVERLAPPED connect_op = {0}, write_op = {0};
    BYTE buffer[BLOCK];
    DWORD done, offset, i, received, started, first_ms = 0, error;
    BOOL ok;
    async_writes = argc == 2 && !strcmp(argv[1], "--overlapped");
    snprintf(pipe_name, sizeof(pipe_name), "\\\\.\\pipe\\ad17-write-probe-%lu", GetCurrentProcessId());
    pipe = CreateNamedPipeA(pipe_name, PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
                            1, 4096, 4096, 0, NULL);
    if (pipe == INVALID_HANDLE_VALUE) fail("server create", GetLastError());
    connect_op.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    ok = ConnectNamedPipe(pipe, &connect_op);
    error = GetLastError();
    if (!ok && error != ERROR_IO_PENDING) fail("connect pending", error);
    thread = CreateThread(NULL, 0, client, NULL, 0, NULL);
    if (!thread) fail("client thread", GetLastError());
    if (!GetOverlappedResult(pipe, &connect_op, &done, TRUE)) fail("connect result", GetLastError());
    /* This read signals the shared pipe handle while a large write is pending. */
    if (ReadFile(pipe, &read_ping, 1, &done, &read_op) || GetLastError() != ERROR_IO_PENDING)
        fail("read pending", GetLastError());
    if (async_writes) write_op.hEvent = CreateEventA(NULL, TRUE, FALSE, NULL);
    started = GetTickCount();
    for (offset = 0; offset < BLOCK * BLOCKS; offset += BLOCK)
    {
        for (i = 0; i < BLOCK; ++i) buffer[i] = expected(offset + i);
        if (async_writes) ResetEvent(write_op.hEvent);
        ok = WriteFile(pipe, buffer, BLOCK, &done, async_writes ? &write_op : NULL);
        error = GetLastError();
        if (!ok && async_writes && error == ERROR_IO_PENDING)
            ok = GetOverlappedResult(pipe, &write_op, &done, TRUE);
        if (!ok || done != BLOCK) fail("server write", ok ? ERROR_WRITE_FAULT : GetLastError());
        if (!offset) first_ms = GetTickCount() - started;
    }
    if (!GetOverlappedResult(pipe, &read_op, &done, TRUE) || done != 1 || read_ping != 0x5a)
        fail("read result", GetLastError());
    if (WaitForSingleObject(thread, 10000) != WAIT_OBJECT_0) fail("client finish", ERROR_TIMEOUT);
    if (!GetExitCodeThread(thread, &received) || received != BLOCK * BLOCKS)
        fail("received byte count", received);
    if (first_ms < 200) fail("write returned before consumer", first_ms);
    printf("PASS mode=%s bytes=%lu first_write_ms=%lu: payload and duplex read verified\n",
           async_writes ? "overlapped" : "NULL-overlapped", received, first_ms);
    CloseHandle(thread);
    CloseHandle(connect_op.hEvent);
    if (write_op.hEvent) CloseHandle(write_op.hEvent);
    CloseHandle(pipe);
    return 0;
}
