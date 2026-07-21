/*
 * stub_target.c — Minimal stub process for injection testing.
 *
 * Stands in for Darktide.exe during unit tests. On startup, sleeps briefly
 * then exits with code 0. The test harness creates this process SUSPENDED,
 * injects a DLL, resumes it, and verifies clean exit.
 */
#include <windows.h>

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR cmd, int show) {
    (void)hInst; (void)hPrev; (void)cmd; (void)show;
    /* Brief sleep so the process doesn't exit before injection completes. */
    Sleep(2000);
    return 0;
}
