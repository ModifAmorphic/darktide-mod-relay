# Mod Relay injected shell

This document defines the normative contracts a maintainer of the injected shell
must honor. The implementation architecture lives in
`docs/architecture/MOD-RELAY.md` → shell.

## Scope

The injected C shell (`relay_shell.dll`) — the DLL linked with the Rust
`relay-discovery` staticlib (C-ABI) + MinHook, delivered by `CreateRemoteThread`.
This document covers the contracts and hazards a maintainer must preserve:
the two required hooks, the pcall#1 trampoline game-safety invariants, the two
trampoline-baked roots, the deliberately-not-hooked discovery anchor, and the
logging destinations. It is a spec, not a narrative.

## Two production hooks (both required)

The shell installs exactly two MinHook detours. Both are required; a failure to
install **either is FATAL**.

- **`lua_newstate`** — captures the single Lua VM into `g_L` (the trampoline and
  the lua-print sink both depend on this one state) and emits a one-time
  `lua_gettop(L)=0` structural sanity log.
- **`lua_pcall`** — counts calls and runs the staged trampoline exactly once at
  pcall#1, **before** the original pcall.

**Failure handling (must not be weakened).** On any hook-install failure
(`MH_Initialize`, `MH_CreateHook`/`MH_EnableHook` for either target) the worker
logs `FATAL` and exits its thread **without** signaling the `relay_hook_ready`
named event. The launcher — which created the game `SUSPENDED` and is blocked on
that event — then times out (60 s) and `TerminateProcess`es the game. The game
is **terminated, never resumed**; there is no best-effort continue past a hook
failure and no "run vanilla" fallback for a hook-install fault. (Vanilla is the
fallback only for an *unresolvable loader dir*, below — a different, non-fatal
path.)

## Trampoline game-safety invariants (pcall#1)

The staged chunk runs inside the `lua_pcall` detour at pcall#1. These invariants
must hold or the engine corrupts:

- **One-shot.** An `InterlockedCompareExchange` on `g_trampoline_done` (0→1)
  gates the run; only the call that observes count == 1 and wins the CAS fires
  it. It never re-runs.
- **Synchronous on the engine's Lua thread.** Lua is single-threaded (the engine
  drives it on its main thread); the trampoline runs inline in the detour, not
  on a spawned thread.
- **Re-entrancy is forward-only.** `g_in_trampoline` is set for the duration of
  the run and cleared on every exit path. The chunk's own internal Lua `pcall`
  re-enters the `lua_pcall` detour, but the guard makes it skip the trampoline
  block and forward straight to the original — no re-count, no re-run.
- **Stack-neutral.** `base = lua_gettop(L)` is saved on entry and
  `lua_settop(L, base)` is restored on every exit path (success, chunk-load
  failure, chunk-pcall failure, status read). Net stack effect is zero; the
  engine's pcall arguments below `base` are never touched.
- **No longjmp out.** The chunk is run under `lua_pcall`, which returns on error
  rather than longjmping; the detour logs the error string and restores the
  stack. The trampoline never escapes into the engine via an unprotected throw.
- **The staged file is the runtime-controlled loader entry.** The chunk
  `io.open`s exactly `<MOD_LOADER_DIR>/init.lua` (read → `loadstring` → run).
  No user-controlled path is executed here.

## Two roots (trampoline-baked globals)

The chunk sets four globals before `io.open`. Two are roots; two are one-shot
internal handoffs.

- **`MOD_LOADER_DIR`** — the runtime-controlled loader root. Self-located by the
  shell from its own DLL path as `<dll-dir>\mod_loader\`. **Required:** if it
  cannot be resolved (DLL self-path unreadable/too long, no separator, path join
  overflow, or chunk build failure), the chunk stays unstaged, the run step logs
  `SKIPPED`, and **the game runs vanilla** (the engine's first pcall still
  proceeds unmodified). This is the only vanilla fallback, and it is non-fatal.
  It is **not** a user env var or flag and is never read from the environment.
- **`RELAY_MOD_PATH`** — the user/mod-manager-controlled mod root (the launcher
  publishes it from `--mod-path`/`RELAY_MOD_PATH`). **Optional:** unset or
  overlong yields an empty-string global; the loader runs, finds no mod root, and
  degrades gracefully — mods do not load, but nothing crashes.
- **`MOD_RELAY_VERSION`** and **`RELAY_SKIP_SPLASH`** — one-shot internal
  handoffs. `MOD_RELAY_VERSION` carries the build-injected product version (nil
  when absent/overlong, so malformed metadata disables only version diagnostics);
  `RELAY_SKIP_SPLASH` carries the splash-skip opt-in (`"1"` only when
  `--skip-splash`/`RELAY_SKIP_SPLASH=1`, else `""`). Both are snapshotted into
  the chunk and retired by the loader before community code runs; they are
  **not** community APIs and must not gain a stable consumer.

## Discovered-but-not-hooked: `lua_resource::bytecode`

`lua_resource::bytecode` is a validated discovery output: its RVA is resolved,
logged, and retained in the address table, but it is **deliberately not hooked**.
It is an engine C++ function with an unknown signature and return convention; a
MinHook forwarding detour on it would risk stack and return-value corruption.
`lua_pcall` — a known LuaJIT C-API signature — is the safe injection point, and
it is the only engine entry the shell detours for execution control.

The other discovered anchors (e.g. `lua_getfield`/`getfenv`/`setfenv`,
`luaL_openlibs`, the engine bundle-script loader, `LuaEnvironment::init` bounds)
are likewise retained in the address table as ABI-stable validated outputs; the
shell dereferences only the C-API subset it needs and hooks none of them. **Do
not add a hook on a C++ engine function without a known, forwarding-compatible
signature.**

## Logging destinations

The shell writes structured, level-filtered lines to `relay.log` (opened with
truncate each launch; path from `RELAY_LOG_FILE`, defaulting beside the game exe)
and mirrors every emitted line to `OutputDebugString`. Level is `RELAY_LOG_LEVEL`
(default `info`). The trampoline's bootstrap status (`OK` / `FAIL` / `SKIPPED`,
or explicit `CHUNK LOAD FAILED` / `CHUNK PCALL FAILED`) is the reliable
bootstrap-validation signal in that log. The full destination, line-format,
tee, and failure contract is normative in
[`docs/reference/relay/logging.md`](logging.md) and is not duplicated here.

## Related docs

- `docs/architecture/MOD-RELAY.md` → `shell/` — the implementation narrative
  (discovery → hook install → trampoline → hook-ready handshake) and the
  engine-context mechanism.
- `docs/architecture/MOD_LOADER-DMF.md` — the mod loader contract (what the
  `<MOD_LOADER_DIR>/init.lua` entry does with the baked globals, the deferred
  bootstrap, and the DMF compatibility boundary).
