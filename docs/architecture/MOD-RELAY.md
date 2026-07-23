# Mod Relay (runtime) — architecture

**Mod Relay (runtime)** is the injected modding runtime + its launcher for
Darktide. It's a **Hybrid** — a Rust discovery pure-library
+ a C live-game shell, linked into one DLL, delivered by `CreateRemoteThread`.
See `docs/architecture/README.md` for the project-wide architecture.

## Subcomponents

### `discovery/` — Rust discovery pure-library  *(built, stable)*

A pure function: a PE image (`&[u8]`) → the 16 LuaJIT/engine function
addresses. No I/O, no global state; 100% safe Rust in core logic;
offline-testable against a binary fixture. Compiled to a C-ABI staticlib.

- **Interface (the seam):** `relay_discover` / `relay_discover_detail`
  (C-ABI). Shared contract: `RelayAddressTable` (`#[repr(C)]`, mirrored in
  `shell/include/relay_discovery.h`) + return codes.
- **State:** production-quality (the Relay runtime seed). The canonical 16
  engine/LuaJIT function addresses are stable.

### `shell/` — C live-game shell (the injected DLL)  *(built; live-validated)*

This is **`relay_shell.dll`** — the C shell linked with the Rust **discovery**
staticlib (`librelay_discovery.a`) + MinHook, into one PE DLL.

The DLL injected into Darktide. `DllMain` spawns a worker that: runs discovery
(via the seam) → installs the two production hooks → stages the trampoline →
signals hook-ready.

- **Two production hooks.** The shell installs exactly two MinHook detours,
  both required (a failure to install either is fatal — the worker exits and
  the launcher's hook-ready wait times out, terminating the game rather than
  resuming half-modded):
  - **`lua_newstate`** — captures the single Lua VM (`g_L`) and emits a
    one-time `lua_gettop(L)=0` structural sanity log (confirms the LJ_64
    non-GC64 struct layout in-process).
  - **`lua_pcall`** — counts calls and runs the staged trampoline exactly
    once at pcall#1, BEFORE the original pcall.
- **Engine-context mechanism (proven).** A chunk injected at the first
  `lua_pcall` (after `luaL_openlibs`, while `io`/`loadstring` are still in
  globals) sees the engine's real facilities and can `io.open` + `loadstring`
  staged Lua — validated end-to-end in the live game. The engine removes
  `io`/`loadstring` from globals by ~pcall#10, so the trampoline runs in the
  pcall#1 → pcall#10 window and captures them first. There is no `setfenv`
  sandbox at pcall#1 (a chunk's env *is* the globals table). **`Managers`** is
  an engine global (appears late in boot); **`CLASS`** is never engine-set, so
  the mod loader sets it.
- **Production trampoline + the mod loader.** The production trampoline is
   wired in `dllmain.c`: on the first `lua_pcall` (one-shot, before the
   engine's pcall) it injects the proven chunk — set the two root globals
   (`MOD_LOADER_DIR` + `RELAY_MOD_PATH`) plus a temporary private handoff of the
   same manifest-derived full product version used by launcher `--version`,
   `io.open` the staged entry
   (`<MOD_LOADER_DIR>/init.lua`) → read → `loadstring` → run. (When the Lua
   print tee is enabled, the trampoline also registers the private
   `__mod_relay_lua_log_sink` callback immediately before loading the chunk —
   see [Logging](#logging); this adds **no new hook**.) The mod loader
  Lua is **packaged with the Relay runtime** (staged into `bin/mod_loader/`
  by `make build`, deployed next to the launcher/DLL; the shell self-locates it
  from its own DLL path as `<dll-dir>\mod_loader\` and publishes that dir as the
  internal `MOD_LOADER_DIR` global — not an env var/flag). The mod root is read
  from `RELAY_MOD_PATH` (the launcher sets it in the child env from
  `--mod-path`); if unset the chunk emits an empty `RELAY_MOD_PATH` (the
  loader runs, finds no mod root, and degrades gracefully — mods won't load, no
  crash). If the loader dir can't be self-located (DLL path unreadable/too
  long), the trampoline is SKIPPED (logged) and the game runs **vanilla**. The
  chunk template and game-safety discipline (one-shot, stack-clean,
  re-entrancy-guarded) are unchanged.
- **Built + live-validated (the full modding chain).** The mod loader
  (`src/mod_loader/init.lua`, the runtime-staged entry) runs in
  engine-context at pcall#1, captures the engine's real
  `io`/`loadstring`/`require`/`print`/`os` into the `Mods` table **before
  the engine removes `io`/`loadstring` (~pcall#6)**, publishes the engine LuaJIT
  FFI module via the pre-wrap module loader (`Mods.original_require("ffi")`,
  since `require("ffi")` creates no global in LuaJIT 2.1), and bridges pcall#1 to the
  engine's late boot via a **deferred bootstrap**:
  - the **require bridge** (`require_bridge.lua`) preserves the engine's real
    `require` (as `Mods.original_require`), wraps global `require` to record
    each distinct table result in `Mods.require_store` (identity-deduped, for
    DMF's `hook_require`), and calls the lifecycle coordinator after every
    successful require;
  - the **class registry** (`class_registry.lua`) is installed once by the
    coordinator the moment the engine's global `class` appears. It wraps
    `class()` so every class object is recorded in the `CLASS` table. Missing
    keys return the unresolved name as a **string sentinel** (e.g.
    `CLASS.InputService == "InputService"` before the class is registered) so
    official DMF's string/table hook validator accepts `dmf:hook_safe(CLASS.X,
    …)` calls issued before the class exists and queues them as delayed hooks;
    `rawget(CLASS, name)` still returns nil for unresolved classes so the
    lifecycle's readiness checks treat them as absent. Each registered class is
    also mirrored to `_G[name]` (rawget-guarded so explicit engine/DMF
    assignments are preserved) for mod compatibility (mods cache class globals
    like `_G.Promise`, which the engine defines via `class("Promise")` in
    `scripts/foundation/utilities/promise.lua` but does not publish to `_G`);
  - the **lifecycle** (`lifecycle.lua`) coordinator then directly
    closure-wraps `BootStateRequireGameScripts._state_update` exactly once it
    exists. That wrapper calls the original first (preserving its returns,
    never swallowing its errors), then a protected `advance_bootstrap` that —
    with per-step retry/idempotency — loads the loader driver
    (`mod_manager.lua`, which itself loads the DMF adapter
    `dmf_adapter.lua` from the loader root), instantiates `Managers.mod`, and
    directly closure-wraps `StateGame.update` + `GameStateMachine._change_state`
    + `GameStateMachine.destroy` (no generic hook API, no loadstring-generated
    hook chain, no string-path deferred queue). The `destroy` wrapper dispatches
    one final `on_game_state_changed("exit", …)` for the active state before
    destruction (deduplicated against `_change_state` per state machine).
  The loader splits load into two phases: `init()` SCANs (reads `mods.lst`,
    builds the `_mods` table — the order file is authoritative, the loader
    injects nothing — restores persisted manager settings via the adapter, and
    registers the DMF IO observer via the adapter; no mod loaded), and the first
    `StateGame.update` tick LOADs (per-mod `run()` → nil/table validation →
    optional object `init()`, then
    `_state="done"` via the adapter) — deferred so boot-complete globals like
    `Managers.input` exist. Every `update` tick also polls the developer-mode-
    gated hot-reload shortcut (LEFT Ctrl + LEFT Shift + R) and drives the
    reload state machine: a request is consumed at the start of an update into a
    teardown frame (`on_reload` forward → `on_unload` reverse → retire stale DMF
    generation globals → reread authoritative `mods.lst`), then the next update
    loads the new generation in order (`init(reload_data_for_name)` per mod) and
    publishes `done` — non-transactional best-effort, no shadow load/rollback.
    The same `ModManager` instance, `_settings` table, require store, `CLASS`,
    file service/observer, and `Managers.dmf.persistent_tables` survive every
    generation. The file observer adapts DMF's mod-facing IO at the mod root
    mid-DMF-init (after `core/io.lua` appears, before Phase 2) and re-adapts
    each DMF generation across reload — tracking both the `DMFMod` table
    identity and the exact Relay-installed `io_dofile` wrapper, so a reused
    class table whose methods were overwritten by the new `core/io.lua` is
    correctly re-adapted (not silently left on stock `./../mods`). Stock-DMF-specific
    integration — persisted `_settings` restoration, the DMF-visible contract
    fields (`_settings.developer_mode`, `_state`, `_mod_load_index`), DMF-required
    entry-shape validation, the eight `DMFMod:io_*` overrides, and stale-
    generation-global retirement — is centralized in `dmf_adapter.lua`;
    `mod_manager.lua` stays generic and drives those through the adapter's
    transition methods. Successful `run()` calls accept only nil (DMF-driven)
    or a table (outer-driven); malformed values fail only their entry and both
    initial/replacement attempts finalize unconditionally. Accepted descriptors
    publish guarded per-generation `Mod:<name> = true` Crashify metadata, while
    the private version snapshot publishes process-lifetime
    `ModRelay:Version` exactly once and is never removed during reload.
    The first escaped outer `init`/`update`/state-change error disables and
    best-effort unloads that entry for the generation. If the escaped outer
    boundary is `dmf`, Relay stops and reverse-cleans all current outer objects
    without inspecting or blaming DMF-managed inner mods. Guarded engine-event
    alerts remain active at a controlled cadence until restart or completed
    user-requested hot reload; they do not depend on DMF or expose
    `Mods.message`. The loader exposes itself as `Managers.mod`. Bootstrap setup
    remains pcall-contained so an infrastructure failure degrades to vanilla +
    a log line rather than crashing the game. The full chain is live-validated
    on Linux/Proton: DMF and user mods load from the configured root; the FFI,
    final-state-exit, Crashify metadata, standalone/framework failure, alert,
    cleanup, and hot-reload recovery contracts execute in the game; repeated
    clean reloads do not stack; and a normal Steam launch remains vanilla. The
    offline LuaJIT harness (`make mod-loader-test`) covers the same loader
    contracts with Relay-owned fakes. See
    `docs/architecture/MOD_LOADER-DMF.md` for the DMF integration + the IO
    adaptation + the load timing + the [hot-reload](MOD_LOADER-DMF.md#hot-reload)
    contract.
- **Bootstrap-only C helpers.** C functions are acceptable only at the
  bootstrap boundary (crossing from DLL injection into the Lua lifecycle) or
  for runtime-private plumbing (status/log) — never as loader/DMF/mod-visible
  replacements for engine Lua facilities (`require`, `io`, …). See the
  compatibility section below.

### `launcher/` — C injector  *(built)*

This is **`mod_relay.exe`** — the C injector (`src/launcher/`), the
process that creates the game suspended, injects the shell, and resumes it.
`CreateProcess(Darktide.exe, SUSPENDED)`
→ inject `relay_shell.dll` → wait for `relay_hook_ready` → `ResumeThread` →
exit. Sets `SteamAppId`/`SteamGameId`.

- **Built:** injection + hook-ready handshake + Steam appID.
- **Interface (the CLI):** a **flag-based CLI**, where every setting
  follows **flag > env var > default**. `--game-binary` is the only required
  flag; the shell DLL is hardcoded next to the launcher (the shell self-locates
  the mod loader from its path), and the log file defaults next to the launcher
  exe.

  | Flag | Env var | Default |
  | --- | --- | --- |
  | `--game-binary <path>` | `RELAY_GAME_BINARY` | — **(required)** |
  | `--mod-path <path>` | `RELAY_MOD_PATH` | unset (mods won't load) |
  | `--log-file <path>` | `RELAY_LOG_FILE` | `<launcher-dir>\relay.log` |
  | `--log-level <level>` | `RELAY_LOG_LEVEL` | `info` (`error`/`warn`/`info`/`debug`/`trace`) |
  | `--steam-app-id <id>` | `RELAY_STEAM_APP_ID` | `1361210` |
  | `--lua-logs` | `RELAY_LUA_LOGS=1` | off (value-less; only the exact env value `1` enables) |
  | `--` (separator) | — (none) | unset (rest-of-line forwarded to the game, in order) |
  | `--version` | — (none) | — (value-less; prints the build-injected version and exits 0) |

  The injected DLL (`relay_shell.dll`) is hardcoded to `<launcher-dir>\` and
  self-locates the mod loader (`<dll-dir>\mod_loader\`); neither path is
  configurable. The launcher resolves the config, then publishes the
  shell-contract values (`SteamAppId`/`SteamGameId`, `RELAY_MOD_PATH`,
  `RELAY_LOG_FILE`, `RELAY_LOG_LEVEL`, and — only when enabled —
  `RELAY_LUA_LOGS=1`) into the child env before `CreateProcess`, so the
  injected shell inherits them. `RELAY_LUA_LOGS` is canonicalized: the launcher
  sets it to exactly `1` when the resolved config enables the Lua print tee
  (`--lua-logs` or `RELAY_LUA_LOGS=1`), and **removes** it (not set to `0`)
  when disabled, so a stale parent value cannot leak into the child as a
  non-`1`. Game arguments are NOT published to the env — they go on the child
  command line: the quoted exe as argv[0] (byte-for-byte the legacy form),
  followed by every token after the end-of-options `--` separator, each
  rendered with the MSVC CRT quoting algorithm. A bare `--` ends option
  parsing; Relay's own flags must precede it, and a flag-looking token after
  `--` is a raw game arg (no `--` is the legacy exe-only launch). The command
  line is ANSI only (active code page; Darktide args are ASCII) and capped at
  `RELAY_CMDLINE_MAX` (32,767 chars incl. NUL — the `CreateProcessA` ceiling);
  oversize is rejected before any process is created. `-h`/`--help` prints the
  full table.

## Contracts

### Launcher invocation (the external interface)

The launcher is a standalone CLI — run it from a shell, or invoke it from an
app (it's the runtime that powers Mod Curator, but any caller works).
`--game-binary` is required; the rest is flag > env > default (full table in
`launcher/` above).

- **Two roots:** the mod loader Lua (`init.lua` + its modules) ships WITH the
  runtime — `make build` stages it into `bin/mod_loader/`, deployed next to
  the launcher/DLL. The shell self-locates the loader root from its own DLL
  path (`<dll-dir>\mod_loader\`, set as the internal `MOD_LOADER_DIR` global
  — not an env var/flag). The **mod path** (`--mod-path` /
  `RELAY_MOD_PATH`) is yours: point it at the directory that **contains**
  your `mods/` subdirectory (the "boundary" — DMF + user mods + `mods.lst`
  live at `<mod_path>/mods/`). The trampoline sets `RELAY_MOD_PATH` from
  it; the loader derives `Mods._mod_root` as `<mod_path>/mods` (what
  `Mods.file.*` roots at) and uses `Mods._mod_path` as the containment
  boundary for the `Mods.lua.io` raw-read wrapper (see
  `docs/architecture/MOD_LOADER-DMF.md` → "Raw `Mods.lua.io` redirection").
- **`mods.lst`** is a plain text file you author (or your app generates): one
  mod folder name per line, in load order. It is **the Relay↔caller load-order
  contract** — the mod loader reads it authoritatively and loads exactly the
  listed mods in order; it injects nothing (DMF does not read it). When DMF is
  used it **must be listed first** (the loader makes no framework assumption;
  DMF is first only because `mods.lst` says so). Missing/empty → no mod loads
  (graceful). Relay uses `mods.lst` exclusively — it has no use for the
  community toolchain's `mod_load_order.txt`.
- **Not the runtime's job:** load-order computation, dependency resolution,
  profile/staging management. You handle those — by hand, or in the app
  driving the launcher. The runtime is the conduit.
- **Platform:** Windows — run the launcher directly, Steam in the background.
  Linux — Steam → launcher (Proton, Darktide's compatdata) → Darktide, one
  prefix/context. (See the root `README.md` getting-started for a `launch.bat`
  + Steam non-Steam-game setup.)

### Internal

- **discovery ↔ shell:** the C-ABI seam (`relay_discover` /
  `relay_discover_detail`); the panic boundary (`catch_unwind` at every
  `extern "C"` entry, `panic = "abort"` fail-safe).
- **launcher ↔ shell:** the `relay_hook_ready` named-event handshake (hook
  armed before `main`).

### Env-var contract (shell ↔ launcher)

The source of truth for the values the launcher publishes into the child env
and the injected shell reads. (The launcher's own config-override env vars are
in the CLI table above; these are the *contract* the shell depends on.) The
loader root is **not** here — the shell self-locates it from its own DLL path
(`<dll-dir>\mod_loader\`) and publishes it to Lua as the internal `MOD_LOADER_DIR`
global, so no loader-path env var exists.

| Env var | Set by | Read by | Meaning |
| --- | --- | --- | --- |
| `RELAY_MOD_PATH` | launcher (only when `--mod-path`/env configured) | shell trampoline + mod loader | the **mod-path boundary** — a directory that *contains* a `mods/` subdirectory where DMF + user mods + `mods.lst` live. The trampoline sets `RELAY_MOD_PATH` from it; the loader derives `Mods._mod_root` as `<mod_path>/mods` (`Mods.file.*` roots here) and `Mods._mod_path` as the containment boundary for the `Mods.lua.io` wrapper. Unset ⇒ empty `RELAY_MOD_PATH` (mods won't load; graceful). |
| `RELAY_LOG_FILE` | launcher | shell | shell log file path |
| `RELAY_LOG_LEVEL` | launcher | shell | shell log level (`error`/`warn`/`info`/`debug`/`trace`) |
| `RELAY_LUA_LOGS` | launcher (canonicalized) | shell worker | the **Lua print tee** switch: only the exact value `1` enables. The launcher sets `RELAY_LUA_LOGS=1` when the resolved config enables it (`--lua-logs` or the env `1` itself), and **removes** it when disabled (never `0`/`true`/etc.). The shell snapshots it once at worker startup (`env_is_exact_one`); any other value (unset/empty/`0`/`true`/oversized) is off. Direct shell injectors may set `RELAY_LUA_LOGS=1` themselves — that is the external non-launcher contract. |
| `SteamAppId` / `SteamGameId` | launcher | Steam | the real Darktide app id (`1361210`); without it `SteamAPI_Init` is denied under a non-Steam shortcut |

### Logging

> The normative, operator-visible logging contract — destinations,
> configuration, the `relay.log` line/lifecycle, and the Lua print tee — lives
> in [`docs/reference/relay/logging.md`](../reference/relay/logging.md). This
> section keeps the implementation architecture (the structured logger, the
> native sanitizer, the private C callback, the no-new-hook invariant).

The shell's C-side log is **`relay.log`**. Each line is structured
`<local ts+UTC offset> <LEVEL> <component>: <msg>` (e.g.
`2026-07-16T12:34:56-04:00 INFO  trampoline: @ pcall#1: OK`) and goes to both
`OutputDebugString` and the log file. The timestamp is **local time with an
ISO-8601 UTC offset** that follows the system time zone (UTC itself shows
`+00:00`; no `Z` special case). Level-filtered via
`RELAY_LOG_LEVEL` (default `info`; crank to `debug`/`trace` for
verbose detail). Default location is next to the launcher exe (resolved by the
launcher from `--log-file`/`RELAY_LOG_FILE`); the shell itself opens
`RELAY_LOG_FILE` if set, otherwise falls back to beside the game exe. The
shell opens the file with truncate once per game process — **a fresh
`relay.log` every launch** (no append, no rotation across runs).

Right after the startup banner, the worker logs a `launching <cmdline>` INFO
line — the host process command line as the game sees it (the quoted exe + the
forwarded game args, e.g. `"…\Darktide.exe" --lua-heap-mb-size 2048`), so the
exact arguments that reached the game are captured.

**Log split to be aware of:** the mod loader's Lua-side `print`/`__print` output
(the `[mod_loader] …` lines), DMF, and mods all go to the **engine's** print
destination — Darktide's **console log** (`console-*.log`, at
`%APPDATA%\Fatshark\Darktide\console_logs\` on Windows, or
`<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`
under Proton) — **not** to the Proton `steam-$APPID.log` (which captures
Wine/Proton diagnostics only). `relay.log` carries the C-side shell + trampoline
lines (including the trampoline's pcall#1 status/failure diagnostics, which are
the reliable bootstrap validation).

**Optional Lua print tee (`--lua-logs` / `RELAY_LUA_LOGS=1`, default off).**
When enabled, Relay additionally copies Lua `print` / `__print` output into
`relay.log` as structured `INFO  lua-print:` lines. It is a **tee, never a
redirect**: the engine's console `print` still runs first and authoritatively,
and the tee only adds `relay.log` copies of what traverses those wrapped
surfaces. Coverage is honest and narrower than "all Lua logs":

- **Captured:** `print` / `__print` calls made after the wrapper installs at
  pcall#1 — Relay loader output, and any DMF/mod path routed through those
  globals.
- **Not captured:** a `print` reference captured before Relay wraps the
  globals, DMF/mod APIs that bypass those globals, native/engine/Wine/Proton
  output, or every `console-*.log` line. DMF `mod:info`/`warning`/`error`
  coverage depends on whether their runtime path ultimately calls the wrapped
  globals (observed, not guaranteed).

Captured lines are emitted at `INFO` with component `lua-print`. `print` /
`__print` carry no severity metadata, and Relay does **not** infer severity
from text prefixes — a line whose text says `warning` / `error` is still
copied at `INFO`. Relay does not identify which game script, Relay module, DMF
module, or user mod called `print`; it adds no source file, line number, or mod
name (although the printed text can identify itself). As a consequence,
`RELAY_LOG_LEVEL=warn`/`error` filters the copied lines out of `relay.log`
while the console log is unaffected. The wrapper is process-lifetime and
non-stacking; see `docs/architecture/MOD_LOADER-DMF.md` for the `print` /
`__print` surface contract, and `docs/reference/relay/logging.md` for the
observable tee boundary and argument-rendering reference.

**Native sink (no new hook).** The tee adds **no new MinHook detour** — the
production hook count stays exactly two (`lua_newstate` + `lua_pcall`). The
sink is a private C callback registered directly in `trampoline_run`, before
the staged chunk loads/runs, using RVAs already in the discovered address
table:

- `lua_pushcclosure(L, &cb, 0)` pushes one zero-upvalue closure;
- `lua_setfield(L, LUA_GLOBALSINDEX, "__mod_relay_lua_log_sink")` sets it as a
  **temporary private global** (`LUA_GLOBALSINDEX = -10002`, grounded against
  `/usr/include/luajit-2.1/lua.h` for LuaJIT 2.1 / Lua 5.1; `lua_setglobal` is
  a macro over this `setfield`). Zero net stack effect (`+1` push, `−1` setfield
  pop), so the chunk still loads at the same base.

The closure (`lua_log_sink_cb`) expects exactly one Lua string (`lua_type`
guards; non-string/wrong-arity calls are ignored, never errored), reads it with
`lua_tolstring` + explicit length, and never calls back into Lua or retains the
pointer. `init.lua` snapshots the closure into a **private local** and clears
the global **before its idempotency guard**, so community code never sees it. It
is runtime-private logging plumbing — **not** a mod API (`Mods.log`,
`Mods.message`, etc. are deliberately absent).

The line-sanitization policy lives in the pure, I/O-free helper `log_sink.c`
(declared `log_sink.h`; unit-tested directly by `tests/test_log_sink.c`, the
same compile-the-impl pattern as `trampoline.c`):

- **4096-byte input budget** per sink call (`LOG_SINK_INPUT_BUDGET`); input
  past that is dropped after exactly **one** trailing truncation-marker line.
- **768-byte output chunks** (`LOG_SINK_LINE_BUDGET`); a longer physical line
  is emitted as consecutive width-bounded lines, each with its own prefix.
- **CR/LF/CRLF splitting** (CRLF is one break); empty lines are emitted
  faithfully.
- **`\xNN` escaping** for control bytes `0x00-0x1f` (except the terminators)
  and `0x7f` (DEL) — so embedded NUL cannot terminate a buffer and no control
  byte can forge line structure. `%` and UTF-8 bytes (`0x80-0xff`) pass through
  unchanged as data.
- **No format-string exposure:** the emit bridge uses a literal `"%.*s\n"`
  with the sanitized line as the data argument, so a `%` in the data is
  literal.
- **Fixed buffers, no heap** proportional to the input string; bounded stack.
- **Logger-wide SRW lock** (`g_log_lock`) serializes the `OutputDebugStringA` +
  file-write pair so worker-thread and Lua-thread (sink) lines never interleave
  mid-line. The sink does not take the lock itself (it reaches `relay_log` via
  the emit bridge, and the lock is non-reentrant).

Failure behavior is graded, not uniformly silent. If the tee is enabled but
a required C-API registration pointer is unavailable, the shell records exactly
**one `WARN` event** through the level-filtered logger and continues
console-only for that run (mod loading is not blocked). A malformed callback
invocation (wrong argument count or a non-string argument at the native
callback) is ignored for that invocation.
After a successful original `print`, a render or sink failure drops only that
relay copy; the wrapper remains installed for later calls. None of these
failures changes the original call's results or blocks the original call, the
loader, or the game.

## Runtime patch compatibility

The entire point of Mod Relay is to eliminate the fragility of the
bundle-db / `patch_999` toolchain — not to relocate that fragility upstream
into a reimplementation of Darktide's Lua runtime.

Mod Relay replaces the current toolchain's bundle-database entry point:

```text
current:    dtkit-patch → patch_999 → mod_loader → DMF → mods
Relay:      DLL injection → runtime patch → staged mod_loader/DMF entry point → mods
```

The runtime patch is an entry-point replacement, not a replacement Lua runtime.
It may use native code and narrow C helpers to cross from DLL injection into the
game's Lua lifecycle, but once staged loader/DMF/mod Lua is running it must see the
same relevant globals, loader behavior, and file/runtime semantics it receives
when loaded by the engine today.

Runtime-owned replacement behavior stays at the bootstrap boundary or in
runtime-private plumbing such as status/logging. Mod Relay does not reimplement
Darktide's Lua runtime or patch individual mods.

### Bootstrap boundary

The shell's C bootstrap is responsible for:

- finding/capturing the live Lua state at the correct lifecycle point;
- getting the staged runtime patch into that state without the bundle database;
- handing off to staged loader/DMF Lua in an engine-equivalent environment.

After that handoff, loader/DMF-visible surfaces such as `require`, `io`,
`loadstring`, globals, and loader hooks come from the engine path or a
behaviorally equivalent wrapper around it — not from independent C
reimplementations.

### Engine-equivalent loader path

In the current community toolchain, `patch_999` is file-based only for the
initial bootstrap: its trampoline reads `./mod_loader` from disk and executes it
with `loadstring`. After that, `mod_loader` runs inside the game's normal Lua
startup path and captures the engine-visible Lua facilities that loader/DMF expect.

**This mechanism is proven.** A chunk injected at `lua_pcall` #1 (the first
script execution after `luaL_openlibs`, while `io`/`loadstring` are still in
the globals) sees the engine's real facilities and can `io.open` + `loadstring`
staged Lua — validated end-to-end in the live game (the production trampoline
loads + runs staged Lua successfully). The engine removes `io`/`loadstring` by
~pcall#10, so the trampoline runs in the pcall#1 → pcall#10 window and captures
them first. There is no `setfenv` sandbox at pcall#1 (chunk env = globals
table). The mod loader then runs in engine-context, captures
`io`/`loadstring`/`require` into the `Mods` table, and defers `CLASS`/`Managers`
work (same model as the existing community `mod_loader`).

### `Mods.original_require`

The runtime must provide DMF with a `Mods.original_require` function compatible
with the loader DMF expects. In the current toolchain, `mod_loader` preserves the
engine's real `require` as `Mods.original_require`; DMF's require module builds
tracking (`Mods.require_store`, `hook_require`) on top of that original function.

Mod Relay preserves this behavior. `Mods.original_require` is the engine's
original `require` or a behaviorally equivalent wrapper around it. It is not a
staging-only file loader. Runtime-owned file loading may exist for bootstrap or
private helper paths, but not as the production implementation of
`Mods.original_require` observed by loader/DMF/mod code.

### `Mods.lua.io`

The runtime must provide the `Mods.lua.io` surface that DMF uses for file access.
DMF's `core/io.lua` deep-copies `Mods.lua.io` at init and uses the familiar Lua
file API (`io.open`, file `:read("*all")`, `:lines()`, `:close()`, `io.close`)
for its debug modules. Mod Relay therefore captures the engine-visible
Lua `io` table into `Mods.lua.io` before it is stripped.

Mod Relay preserves this behavior. `Mods.lua.io` is the engine-visible Lua
`io` table or a behaviorally equivalent engine wrapper. A C/Win32 file API may
exist for the bootstrap or runtime-private helpers, but not as the
loader/DMF-visible production replacement for Lua `io`.

## Out of scope for the Relay runtime

- **Dependency resolution / load-order computation** — not the runtime's job
  (you, or the app driving the launcher, author `mods.lst`); the Relay runtime
  bootstraps the staged mod loader entry point, and the mod loader reads the
  load order authoritatively (DMF does not).
- **Profile / staging-dir management** — not the runtime's concern; handle it
  in whatever wraps the launcher (a mod manager like Mod Curator, a script,
  or by hand).

## Build + test

See `AGENTS.md` (agent ops) and `docs/architecture/README.md` (test strategy):
MinGW + MSVC; the `test-hooks` feature; `make build/check/test` + the clippy
gate.

## References

- `docs/architecture/MOD_LOADER-DMF.md` — the mod_loader↔DMF integration + IO
  adaptation (the loader, the loader surfaces, the `Managers.mod` shape contract,
  the load timing).
- `docs/architecture/README.md` — project architecture.
- `docs/reference/darktide/darktide-binary.md` — the validated game-binary constraints.
- `docs/reference/community-tools/darktide-framework-analysis.md` — the
  community loader/DMF surfaces that the runtime preserves for mods.
