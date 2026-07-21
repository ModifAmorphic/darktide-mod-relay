# MinHook (vendored)

Source: https://github.com/TsudaKageyu/minhook
Version: **1.3.3** (latest tagged release as of vendoring).
License: 2-clause BSD (see `LICENSE.txt`).

## What's vendored

Only the **x64** paths are included (the target Darktide process is x86-64;
we never build x86 here). The x86 HDE files (`hde32.c`, `hde32.h`,
`table32.h`) are intentionally omitted.

```
include/MinHook.h         — public API
src/buffer.{c,h}          — trampoline buffer allocator
src/hook.c                — top-level hook management (MH_Initialize, etc.)
src/trampoline.{c,h}      — per-hook trampoline construction
src/hde/hde64.{c,h}       — Hacker Disassembler Engine x64 (instruction length)
src/hde/table64.h         — HDE64 lookup table
src/hde/pstdint.h         — stdint polyfill (only used when the compiler lacks <stdint.h>)
```

## Build

`build.sh` compiles these into `build/minhook.a` (mingw static lib) with
the same `-O2 -g -Wall -Wextra` flags as the rest of the DLL, then links
the archive into `dbghelp.dll`. MinHook is `static`-only here — we never
ship it as a separate DLL.

## Loader-lock safety

MinHook does **not** call `LoadLibrary`, `GetModuleHandle`, `GetProcAddress`,
or any other loader API. Its only runtime touches during `MH_CreateHook` /
`MH_EnableHook` are:

1. `VirtualProtect` (make the target page writable, then restore).
2. `FlushInstructionCache` (force the patch to take effect).
3. `HeapAlloc` for the trampoline buffer (or `VirtualAlloc` with
   `MEM_COMMIT|MEM_RESERVE` for the indirect trampoline pool near the
   target, when the trampoline can't reach via rel32).

All three are safe inside `DllMain` (loader lock held). The detour
functions themselves run later, when the engine calls the hooked function
— well outside `DllMain`.
