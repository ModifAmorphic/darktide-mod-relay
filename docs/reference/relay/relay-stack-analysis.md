# Mod Relay Stack Analysis

> **Status:** Descriptive reference. Describes the Mod Relay (runtime)
> stack — this repository's own work, not third-party background.
>
> This is the Relay-side mirror of
> [`darktide-framework-analysis.md`](../community-tools/darktide-framework-analysis.md):
> the same stack shape with Mod Relay in place of dtkit-patch and
> Darktide-Mod-Loader, and with the same stock, unmodified DMF loaded as the
> first entry. The document is descriptive — the normative contracts live in
> [`shell.md`](shell.md), [`logging.md`](logging.md), and
> [`manager-slot.md`](manager-slot.md), and the implementation architecture in
> [`MOD-RELAY.md`](../../architecture/MOD-RELAY.md) and
> [`MOD_LOADER-DMF.md`](../../architecture/MOD_LOADER-DMF.md).
>
> Relay facts are pinned to Mod Relay **1.1.0** (the release-please manifest,
> `.release-please-manifest.json`). DMF consumer facts are pinned to
> [`b9cc65f`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework/tree/b9cc65f773cd8aaa974bf5b9312a79f5c5785f90)
> — the same pin as the community-chain doc. Community-chain comparisons
> reference Darktide-Mod-Loader release
> [`26.06.24`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader/releases/tag/26.06.24)
> (`4bd075a`). Discovery is engine-build-agnostic: Tier-2 self-validation
> passes on any Darktide build, and Tier-1 exact-match checks skip when the
> game binary's SHA differs from the pinned one.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Component: Mod Relay — Launcher](#component-mod-relay--launcher)
3. [Component: Mod Relay — Injected runtime (shell + mod loader)](#component-mod-relay--injected-runtime-shell--mod-loader)
4. [Component: Darktide-Mod-Framework (DMF)](#component-darktide-mod-framework-dmf)
5. [Mod Loading Flow (End-to-End)](#mod-loading-flow-end-to-end)
6. [Technology Summary](#technology-summary)

---

## Architecture Overview

Like the community chain, this is a layered system that supplies its own
loading path: current stock Darktide does not drive a game-level mod manager
(the native Steam/UGC substrate is compiled into the binary but not driven by
current stock Lua startup — see the
[community-chain analysis](../community-tools/darktide-framework-analysis.md#native-mod-substrate-versus-the-active-community-path)).
Mod Relay replaces the community chain's **entry mechanism** (DLL injection
instead of the dtkit-patch boot-bundle patch + DML's modified `main.lua`) and
its **Lua loader** (Relay's own mod loader instead of DML's), and keeps DMF in
exactly the same role — the first mod loaded, nothing more:

```
┌──────────────────────────────────────────────────────────┐
│                   Caller (out of game)                   │
│                                                          │
│  Any app or a direct shell — e.g. Mod Curator or a       │
│  launch.bat — invokes the launcher CLI (flag > env >     │
│  default; --game-binary required)                        │
└──────────────────────────┬───────────────────────────────┘
                           │ spawns mod_relay.exe <flags>
                           ▼
┌──────────────────────────────────────────────────────────┐
│            Mod Relay launcher (mod_relay.exe, C)         │
│                                                          │
│  Resolves config, pre-flights the alternate manager,     │
│  publishes the child env, creates Darktide.exe           │
│  SUSPENDED, injects relay_shell.dll (CreateRemoteThread),│
│  waits for relay_hook_ready, resumes the main thread     │
└──────────────────────────┬───────────────────────────────┘
                           │ relay_shell.dll, in-process
                           │ exactly two production hooks:
                           │ lua_newstate + lua_pcall
                           ▼
┌──────────────────────────────────────────────────────────┐
│         Relay mod loader (Lua, staged on disk)           │
│                                                          │
│  <dll-dir>\mod_loader\ → init.lua + modules (path, file, │
│  class_registry, require_bridge, lifecycle, mod_manager, │
│  dmf_adapter). One-shot trampoline @ pcall#1 runs the    │
│  entry; deferred bootstrap bridges to late boot;         │
│  Managers.mod (Relay's ModManager) reads mods.lst        │
└──────────────────────────┬───────────────────────────────┘
                           │ mods.lst order; dmf listed first
                           ▼
┌──────────────────────────────────────────────────────────┐
│      Darktide-Mod-Framework (DMF) — stock, unmodified    │
│                                                          │
│  First entry: dmf/dmf.mod → run() → dmf_mod_object →     │
│  init() loads the framework modules                      │
└──────────────────────────┬───────────────────────────────┘
                           │ new_mod() / get_mod()
                           ▼
┌──────────────────────────────────────────────────────────┐
│                       User mods                          │
│                                                          │
│  <mod_path>/mods/<mod>/<mod>.mod descriptors, loaded     │
│  in mods.lst order after DMF                             │
└──────────────────────────────────────────────────────────┘
```

The contrast with the community chain's entry: vanilla play is untouched —
launching Darktide from Steam (or any launch that does not go through the
Relay launcher) runs the unmodified game. Relay leaves no footprint in the
game directory: no bundle-database patching, no replaced `main.lua`, no game
files written or modified. The only inputs to the game process are the
injected DLL, the staged mod loader it runs, and the caller's configuration.

---

## Component: Mod Relay — Launcher

### Purpose

The out-of-game entry tool — the role dtkit-patch plays in the community
chain, but it **patches nothing**. `mod_relay.exe` is the C injector
(`src/launcher/`): the process that creates the game suspended, injects the
shell DLL, and resumes it. It is a standalone CLI — run it from a shell, or
invoke it from an app (it's the runtime that powers Mod Curator, but any
caller works).

### How It Works

1. **Resolves config** — every setting follows **flag > env var > default**;
   `--game-binary` is the only required flag. The shell DLL is hardcoded next
   to the launcher, and the shell self-locates the mod loader from its own
   DLL path — neither is configurable.
2. **Pre-flights the alternate mod manager** when `--mod-manager` /
   `RELAY_MOD_MANAGER` is configured: the target must exist as a regular
   file. A missing target, a directory, or an env value too long for the
   launcher's buffer produces a stderr diagnostic naming the path and its
   source (flag or env) and the launcher exits with status 2 — the game
   process is never created, and the configured manager is never silently
   degraded to the built-in.
3. **Validates the game command line** — tokens after the `--` separator are
   ANSI only and the full command line is capped at 32,767 chars; oversize is
   rejected before any process is created.
4. **Publishes the child env** — `SteamAppId`/`SteamGameId` (so
   `SteamAPI_Init` is not denied under a non-Steam shortcut), `RELAY_MOD_PATH`,
   `RELAY_MOD_MANAGER`, `RELAY_LOG_FILE`, `RELAY_LOG_LEVEL`, and the
   canonicalized switches (`RELAY_LOG_LUA`, `RELAY_LOG_APPEND`,
   `RELAY_SKIP_SPLASH` — each set to exactly `1` when enabled and **removed**
   when disabled, so a stale parent value cannot leak into the child). It also
   derives `RELAY_MODS_IN_GAME_TREE=1` when the resolved `--mod-path` IS the
   game directory — decided by handle identity (volume serial + file index,
   never path-text comparison). Game arguments are not env-published; they go
   on the child command line.
5. **`CreateProcess(Darktide.exe, SUSPENDED)`** — the quoted exe as argv[0],
   followed by every token after `--`, in order, each rendered with the MSVC
   CRT quoting algorithm.
6. **Injects `relay_shell.dll`** via `CreateRemoteThread`.
7. **Waits for the `relay_hook_ready` named event** — the handshake that the
   hooks are armed before the main thread runs. On timeout (60 s) the
   launcher terminates the game; it is never resumed half-modded.
8. **`ResumeThread`** — the game boots — and the launcher exits.

### CLI Interface

| Flag | Env var | Default |
|------|---------|---------|
| `--game-binary <path>` | `RELAY_GAME_BINARY` | — **(required)** |
| `--mod-path <path>` | `RELAY_MOD_PATH` | unset (mods won't load) |
| `--mod-manager <file>` | `RELAY_MOD_MANAGER` | unset (no alternate manager; launch refuses if the configured file is missing, a directory, or — env-sourced — oversized) |
| `--log-file <path>` | `RELAY_LOG_FILE` | `<launcher-dir>\relay.log` |
| `--log-level <level>` | `RELAY_LOG_LEVEL` | `info` (`error`/`warn`/`info`/`debug`/`trace`) |
| `--steam-app-id <id>` | `RELAY_STEAM_APP_ID` | `1361210` |
| `--log-lua` | `RELAY_LOG_LUA=1` | off (value-less; only the exact env value `1` enables) |
| `--log-append` | `RELAY_LOG_APPEND=1` | off (value-less; only the exact env value `1` enables; appends instead of truncating) |
| `--skip-splash` | `RELAY_SKIP_SPLASH=1` | off (value-less; only the exact env value `1` enables; skips the intro splash state) |
| `--` (separator) | — (none) | unset (rest-of-line forwarded to the game, in order) |
| `--version` | — (none) | — (value-less; prints the build-injected version and exits 0) |

Notes on the surface:

- `--mod-path` points at the directory that **contains** a `mods/`
  subdirectory (DMF + user mods + `mods.lst` live at `<mod_path>/mods/`); it
  is the user-controlled half of the two-roots split (the loader root is
  Relay-controlled and self-located by the shell).
- `--` is the end-of-options separator: every token after it is forwarded to
  the game verbatim, in order, as separate argv entries. Relay's own flags
  must precede it; a flag-looking token after `--` is a raw game arg. No `--`
  is the legacy exe-only launch.
- `--version` prints the build-injected product version (read from
  `.release-please-manifest.json` at build time) — callers such as Curator
  use it for version comparison.

### Technology

- **Language**: C (Win32; Windows x64)
- **Delivery**: a standalone native process; the runtime ships as the
  launcher exe + the shell DLL + the staged `mod_loader/` (plus the staged
  legal notices — see [Technology Summary](#technology-summary))

### Key Difference vs dtkit-patch

Nothing is patched. The community chain's entry mechanism writes a patched
record into `bundle_database.data` (and ships a replaced `main.lua`), so every
game update or Steam file verification reverts it and the user must re-run the
patcher. Relay's entry is process-level injection: there is no game file to
revert, so game updates do not break the entry mechanism (discovery
self-validates against any build — Tier-2 passes everywhere, Tier-1
exact-match skips on SHA mismatch). Disabling mods means launching the game
without Relay — a normal Steam launch — with no unpatch step and nothing left
behind in the game directory.

---

## Component: Mod Relay — Injected runtime (shell + mod loader)

Relay replaces DML's role — the game-level Lua mod-loading and lifecycle
layer — with two cooperating pieces: an injected C shell that captures the
engine's Lua VM, and a staged Lua mod loader that runs in engine context.

### Shell (`relay_shell.dll`)

**DllMain worker.** The injected DLL's `DllMain` spawns a worker thread that:
runs discovery → installs the two production hooks → stages the trampoline →
signals hook-ready (the event the launcher is blocked on).

**Rust discovery engine.** Discovery is a Rust pure-library (no I/O, no
global state): a PE image (`&[u8]`) → the 16 LuaJIT/engine function
addresses, including `lua_newstate` and `lua_pcall`. It is compiled to a
C-ABI staticlib and linked into the DLL — the C shell calls it across a tiny
seam (`relay_discover` / `relay_discover_detail`).

**Exactly two production hooks (MinHook).** Both are required; a failure to
install either is fatal — the worker exits without signaling hook-ready, and
the launcher's wait times out and terminates the game rather than resuming it
half-modded:

- **`lua_newstate`** — captures the single Lua VM and emits a one-time
  structural sanity log.
- **`lua_pcall`** — counts calls and runs the staged trampoline exactly once
  at pcall#1, **before** the original pcall. This is the only engine entry
  the shell detours for execution control; other discovered anchors are
  resolved and retained in the address table but deliberately not hooked
  (normative detail in [`shell.md`](shell.md)).

**Production trampoline.** The one-shot chunk runs inside the `lua_pcall`
detour at pcall#1 — the first script execution after `luaL_openlibs`, while
`io`/`loadstring` are still in the globals (the engine removes them by
~pcall#10, so the trampoline captures them first). It bakes six globals —
three roots (`MOD_LOADER_DIR`, `RELAY_MOD_PATH`, `RELAY_MOD_MANAGER`) and
three one-shot handoffs (`MOD_RELAY_VERSION`, `RELAY_SKIP_SPLASH`,
`RELAY_MODS_IN_GAME_TREE`) — then `io.open`s the staged entry
(`<MOD_LOADER_DIR>/init.lua`) → read → `loadstring` → run. The chunk is
one-shot, synchronous on the engine's Lua thread, re-entrancy-guarded, and
stack-neutral (the game-safety invariants are normative in
[`shell.md`](shell.md)).

The loader root is self-located by the shell from its own DLL path as
`<dll-dir>\mod_loader\` and published as the internal `MOD_LOADER_DIR` global
(not an env var/flag). If it cannot be resolved, the trampoline is skipped
(logged) and the game runs vanilla — the only vanilla fallback, and it is
non-fatal. A set-but-unreadable, overlong, or control-bearing
`RELAY_MOD_MANAGER` value is the opposite: fatal (`ExitProcess(1)` during
staging, before the game resumes) so a configured manager is never silently
dropped.

**Logging (`relay.log`).** The shell writes structured, level-filtered lines
to `relay.log` — form `<local ts + UTC offset> <LEVEL> <component>: <msg>`
(timestamped in local time with an ISO-8601 UTC offset), mirrored to
`OutputDebugString`, level-filtered by `RELAY_LOG_LEVEL` (default `info`). A
fresh file per launch by default; `--log-append` switches to append mode.
Right after the startup banner the worker logs a `launching <cmdline>` INFO
line capturing the exact arguments that reached the game. Loader/DMF/mod Lua
`print` output goes to Darktide's console log, not `relay.log`; the optional
`--log-lua` tee copies it in as `INFO lua:` lines. The destinations, the
line/lifecycle, and the tee boundary are normative in
[`logging.md`](logging.md).

### Mod loader (`mod_loader/`, Lua)

The mod loader is runtime-staged Lua — Relay-controlled, shipped with the
build (`make build` stages it into `bin/mod_loader/`, deployed next to the
launcher/DLL). The entry `init.lua` runs at pcall#1 in engine context:

```
mod_loader/              (staged at <dll-dir>\mod_loader\)
├── init.lua             # pcall#1 entry: captures engine facilities, snapshots
│                        #   the trampoline globals, loads the modules below
├── path.lua             # pure-string path utility (normpath)
├── file.lua             # Mods.file.* (mod-root-rooted exec/read family) +
│                        #   the Mods.lua.io.open/io.lines/popen wrappers
├── class_registry.lua   # CLASS registry + unresolved-name string sentinel
├── require_bridge.lua   # preserves require as Mods.original_require, records
│                        #   Mods.require_store, advances the bootstrap
├── lifecycle.lua        # bootstrap coordinator + engine closure-wraps +
│                        #   manager slot (Steps 1a/1b) + chassis (Step 1c)
├── mod_manager.lua      # the built-in ModManager: generic scan/load/lifecycle
│                        #   driver + the hot-reload state machine
└── dmf_adapter.lua      # the stock-DMF compatibility boundary
```

- **Engine-facility capture.** Before the engine strips `io`/`loadstring`
  (~pcall#6), the entry captures the engine's real
  `io`/`loadstring`/`require`/`print`/`os` into the `Mods` table and publishes
  the LuaJIT FFI module via the pre-wrap module loader
  (`Mods.original_require("ffi")` — `require("ffi")` creates no global in
  LuaJIT 2.1; it degrades to nil with one diagnostic if unavailable).
- **Require bridge.** Preserves the engine's real `require` as
  `Mods.original_require`, wraps the global `require` to record each distinct
  table result in `Mods.require_store` (identity-deduped — what DMF's
  `hook_require` builds on), and calls the lifecycle coordinator after every
  successful `require`.
- **Class registry.** Installed once the moment the engine's global `class`
  appears: wraps `class()` so every result is recorded in `CLASS`. Missing
  keys return the unresolved name as a **string sentinel**
  (`CLASS.InputService == "InputService"` before registration) so DMF's
  string/table hook validator accepts early `hook_safe` calls and queues them
  as delayed hooks; `rawget(CLASS, name)` still returns nil so readiness
  checks treat unresolved classes as absent. Registered classes are mirrored
  to `_G[name]` (rawget-guarded).
- **Deferred bootstrap.** At pcall#1 the engine classes the loader needs and
  `Managers` do not exist yet. The lifecycle coordinator closure-wraps
  `BootStateRequireGameScripts._state_update` exactly once (original first,
  then a protected, idempotent `advance_bootstrap` that retries only the
  missing steps): load the manager class (Step 1a) → instantiate
  `Managers.mod = <class>:new()` (Step 1b) → chassis duties (Step 1c:
  `establish()` publishing `Managers.mod` + restoring `_settings` when nil,
  the DMF io observer, the process-lifetime `ModRelay:Version` Crashify
  publication) → wrap `StateGame.update` (Step 2) → wrap
  `GameStateMachine._change_state` (Step 3) → wrap `GameStateMachine.destroy`
  (Step 4) → opt-in `--skip-splash`: wrap `CLASS.StateSplash.on_enter`
  (Step 5).
- **Lifecycle wraps.** `StateGame.update` drives `Managers.mod:update(dt)`
  *before* the engine's own update; `_change_state` dispatches
  `on_game_state_changed("exit", …)` before the transition and `("enter", …)`
  after (reading the engine-maintained state, never writing it); `destroy`
  dispatches one deduplicated final `"exit"` for the active state before
  destruction. There is deliberately **no** `Mods.hook` — no loadstring-driven
  hook chain, no global hook registries — the loader drives the engine solely
  through direct `(owner_table, method_key)` closure-wraps.

Two roots are in play, both set as globals by the C trampoline before the
entry opens: the **loader root** (`MOD_LOADER_DIR`, Relay-controlled — the
mod loader's own code) and the **mod root** (`RELAY_MOD_PATH` → derived
`Mods._mod_root` = `<mod_path>/mods`, user-controlled — DMF, user mods, and
`mods.lst`). The split keeps a DMF/mod update from requiring a Relay rebuild
and vice versa.

### Relay's ModManager (`mod_manager.lua`)

The built-in occupant of the manager slot. `Managers.mod` is a **slot**:
Relay's `ModManager` class occupies it by default, and
`--mod-manager`/`RELAY_MOD_MANAGER` can seat an alternate manager file
wholesale instead (the selection, failure policy, and occupant environment
are normative in [`manager-slot.md`](manager-slot.md); the loader chassis
calls exactly `update(dt)` and `on_game_state_changed(...)` on whoever
occupies the slot). The built-in manager is the generic scan/load/lifecycle
driver:

1. **Scanning** (`init()`, during boot): reads `mods.lst` (one mod
   folder name per line, in load order) and builds the entire `_mods` table
   up front. The order file is **authoritative and caller-authored** — the
   loader injects nothing. DMF is **not** auto-inserted (unlike DML, which
   unconditionally prepends `dmf` to its load order); DMF is first only
   because `mods.lst` lists it first. Missing/empty file → no mod loads
   (graceful, no crash).
2. **Loading** (begins on the **first `StateGame.update` manager update** —
   the load-pass anchor, pass bookkeeping only): a **staged load** that
   advances **exactly one entry per manager update**, in order — entry i
   (1-based list position) loads on the i-th update after the anchor, at
   stage i−1. Each load step: execute
   the `.mod` descriptor, publish the descriptor table on the entry as
   `entry.data`,
   call its `run()` (pcall-guarded), accept only **nil** (a DMF-driven
   side-effect registration) or a **table** (an outer object — stored, and
   its `init()` called synchronously, before any later entry loads). The pass
   is deferred from boot to the first manager update because boot-complete
   globals (`Managers.input`, …) do not exist yet during the boot-state
   requires; the scan can run at boot because it reads no engine globals.
   This matches DML's pacing (one listed mod per loading update; the normative
   stage contract is in [`load-stages.md`](load-stages.md)).
3. **Running**: every update drives `update(dt)` for every outer
   object loaded so far, polls the developer-mode-gated hot-reload shortcut,
   and drives the reload state machine. Updates overlap the pass: an outer
   mod's first `update` lands on its own load update, and already-loaded mods
   keep updating while later entries still load.
4. **Failure state**: per-mod pcall fault isolation — missing/malformed
   descriptors, throwing `run()` calls, and invalid (non-nil/non-table)
   results fail only their entry and later entries continue. The first
   escaped outer `init`/`update`/state-change error disables that entry for
   the generation and queues one protected best-effort `on_unload`
   (one-strike outer containment). An escaped **`dmf`** outer boundary stops
   the current generation and reverse-cleans all outer objects without
   inspecting or blaming DMF-managed inner mods. Guarded engine-event alerts
   repeat at a controlled cadence until a restart or a completed
   developer-mode hot reload. `_state` still finalizes to `"done"`.
5. **Supports**: hot reload, unload (reverse load order), game-state
   exit/enter dispatch, and final state exit during `GameStateMachine.destroy`
   — the same lifecycle surface the DML lineage provides.

Loading contracts worth naming:

- **`_state` nil-before-done.** `_state` is DMF's contract field: it stays
  `nil` until the manager decides the pass is complete, then is published as
  `"done"` exactly once — including the empty, all-failed, and framework-
  stopped cases. DMF polls `_state == "done"` from its own update (driven
  every update; no earlier than the finalize update's update drive) and fires its
  `all_mods_loaded` event. The loader's own anchor flag (`_mods_loaded` — set
  on the first manager update, at pass begin) is a
  separate, loader-internal field DMF never reads.
- **`_mod_load_index`** is set to the entry's index at its load update (so
  DMF's `new_mod` → `DMFMod:init()` reads the right `_mods` entry), persists
  between entry loads — visible across engine updates mid-pass, community
  parity — and is cleared once, at pass finalize. The descriptor table is
  published as `entry.data` before `run()` because `DMFMod:init()` reads
  `.data.packages` during construction.
- **Crashify metadata.** Accepted descriptors publish guarded per-generation
  `Mod:<name> = true` properties (at most once per key per generation, names
  validated; published immediately before `run()` is invoked). The
  process-lifetime `ModRelay:Version` property is chassis-owned (attempted at
  manager creation, retried on the update wrap until success) and is never
  removed. Hot reload removes every tracked old-generation `Mod:*` key before
  publishing the replacement generation's — generation-aware stale-key
  removal — while `ModRelay:Version` always survives.
- **Hot reload (teardown frame + replacement replay).** Trigger: **LEFT Ctrl
  + LEFT Shift + R**, developer-mode gated (DMF's persisted
  `_settings.developer_mode` via the adapter). `Managers.mod:request_reload(source)`
   is the trigger-neutral request seam (validates developer mode, load done,
   and no request/in-progress reload — no stacking). `ModManager:_check_reload()`
   is the detection-only seam, called by dynamic dispatch so a community
   replacement can suppress or redirect the built-in gesture; the legacy
   direct `_reload_requested = true` field-set path is preserved for
   compatibility — together these match the community reload-control contract
   the [community-chain doc](../community-tools/darktide-framework-analysis.md#loader-surfaces-consumed-by-dmf-and-community-mods)
   records. An accepted request spans a **teardown frame**
   (`_state` → nil; `on_reload` on outer objects in forward order, results
   stored keyed by stable mod **name**; `on_unload` in reverse order; retire
   the stale DMF generation globals; remove old `Mod:*` keys; reread the
   authoritative `mods.lst`) and then a **replacement replay** — an anchor
   update, then one entry per update (the stage counter reset so the
   replay's first entry is stage 0), with `init(reload_data_for_same_name)`
   delivered at each entry's load update; `mark_load_done`, the generation
   increment, and the completion INFO/WARN land on the final replay update.
   Reload is best-effort and non-transactional — no shadow load, no rollback;
   a completion with errors recommends a game restart.

### Loader surfaces consumed by DMF and mods

The loader establishes these Lua-visible surfaces before DMF and user mods
run. Each is the Relay counterpart of a DML-lineage surface (left column of
the [community-chain surfaces
table](../community-tools/darktide-framework-analysis.md#loader-surfaces-consumed-by-dmf-and-community-mods)):

| Surface | Observable contract | DML-lineage relationship |
| --- | --- | --- |
| `Mods.original_require` / `Mods.require_store` | The engine's real `require` preserved; the wrapped global `require` records each distinct table result identity-deduped, enabling `hook_require`. | Matches DML's `function/require.lua` contract. |
| `Mods.lua.io`, `.loadstring`, `.os`, `.ffi` | The engine's real facilities captured before globals are stripped. `io.open`/`io.lines` root relative paths at the mod root (absolute paths pass through verbatim); `ffi` is obtained via the pre-wrap module loader. | Matches; Relay additionally roots the stock-DMF `./../mods/<rest>` relative-path convention at `<mod_path>/mods`. |
| `__print` | The engine's print function retained as the global `__print` for loader/framework diagnostics. | Matches; with `--log-lua`, `print`/`__print` are additionally wrapped by the process-lifetime tee. |
| `CLASS` and class globals | `class()` wrapped; every result recorded in `CLASS` and mirrored to `_G[name]` (rawget-guarded); unresolved names return a string sentinel so pre-registration `hook_safe` calls queue as delayed hooks. | Matches DML's `function/class.lua` contract; the string sentinel is Relay's addition. |
| `Managers.mod._mods`, `_mod_load_index`, `_state`, `_settings.developer_mode` | The load-entry, completion, and developer-mode state read by DMF; `_state` follows the nil-before-done contract. | Same DMF-visible fields the DML lineage publishes; here written by Relay's ModManager through the DMF adapter's transition methods. |
| `Managers.mod:request_reload(source)` | The supported reload request seam: validates developer mode + load done + no stacking; returns `(true)` or `(false, reason)`. | Relay's supported seam for new callers (new relative to the DML lineage). |
| `ModManager:_check_reload()` | Detection-only dynamic-dispatch seam for the built-in LEFT Ctrl + LEFT Shift + R gesture; a community replacement can return `false` to suppress or `true` to redirect; a throwing replacement degrades to `false`. | Same community reload-control contract DML exposes. |
| `_reload_requested` | A direct `true` value requests reload; the legacy field-set path current community reload-control code uses. | Same legacy field, preserved for compatibility. |
| Game-state wrappers | Dispatch `exit` before `_change_state`, `enter` after it, and one deduplicated final `exit` for the active state before `GameStateMachine.destroy`. | Same dispatch ordering the DML lineage provides, including the final state exit. |
| Crashify metadata | `Mod:<name>` per accepted entry (generation-aware) + the process-lifetime `ModRelay:Version`. | Same loaded-mod-identity purpose; Relay adds the version property and generation-aware key rotation. |

### DMF integration boundary (`dmf_adapter.lua`)

Stock DMF is kept **unmodified** — no vendored edits — and every
stock-DMF-specific integration point is centralized in the DMF adapter (a
plain Lua module + factory; `mod_manager.lua` stays generic and drives the
contract fields through the adapter's transition methods, so the adapter is
the single place to audit when stock DMF's contract changes):

- **The eight `DMFMod:io_*` overrides.** DMF's `core/io.lua` hardcodes
  `./../mods` as its mod directory (the old community loader staged mods next
  to the game); under Relay, mods live under the caller's mod path. The
  adapter overrides the mod-facing IO methods to delegate to the
  mod-root-rooted `Mods.file.*` operations:
  `io_dofile`/`io_dofile_unsafe` → `dofile`, `io_exec`/`io_exec_unsafe` →
  `exec`/`exec_unsafe`, `io_exec_with_return`/`io_exec_unsafe_with_return` →
  the matching `exec_with_return` variants, `io_read_content`/
  `io_read_content_to_table` → the matching reads. The adaptation lands
  **mid-DMF-init** via a file observer registered once per process: after
  `core/io.lua` defines the methods (Phase 1), before Phase 2 uses them. It
  is installation-aware across hot reload (it tracks both the `DMFMod` table
  identity and the exact Relay-installed `io_dofile` wrapper, so both a fresh
  table and a reused table whose methods were overwritten are re-adapted).
- **`_settings` restoration.** The persisted developer-mode setting is
  restored from `Application.user_setting("mod_manager_settings")` at startup
  only when the manager left `_settings` nil (identity preserved; the adapter
  never writes persistence — official DMF owns that when its option
  changes). The adapter's `developer_mode_enabled()` is the reload gate.
- **Entry-shape validation.** The DMF-required entry shape (`id`, `name`,
  `handle`) is validated at the load boundary; the executed `.mod` descriptor
  is published as `entry.data` before `run()` (DMF reads `.data.packages`
  during `DMFMod:init()`).
- **The mods-in-game-tree gate.** When the resolved mod path IS the game
  directory itself (launcher-derived `RELAY_MODS_IN_GAME_TREE`, decided by
  handle identity; snapshotted by `init.lua` as
  `Mods._relay.mods_in_game_tree`), **all** io-retargeting layers stay off —
  the `Mods.lua.io.open`/`io.lines` wrapper, the `io.popen` cd-prepend
  (`file.lua`), and the eight `DMFMod:io_*` overrides — so stock DMF
  relative-path conventions resolve naturally from the game's `binaries\`
  CWD.

---

## Component: Darktide-Mod-Framework (DMF)

### Purpose

The same stock component the community stack uses — pinned to
[`b9cc65f`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework/tree/b9cc65f773cd8aaa974bf5b9312a79f5c5785f90)
— a comprehensive Lua modding API (hook management, events, keybindings,
options UI, chat commands, localization, package management). Under Relay it
is loaded as the **first `mods.lst` entry**, nothing more: DMF does not load
mods — the mod loader does. Mod authors see the same DMF API as under the
community chain: `new_mod()`/`get_mod()`, the `mod:hook*` family
(`mod:hook`, `mod:hook_safe`, `mod:hook_origin`, `mod:hook_require`)
including delayed hooks, options, keybinds, and events. DMF's internals
(module breakdown, hook-system detail, bootstrap phases) are documented in
the [community-chain
analysis](../community-tools/darktide-framework-analysis.md#component-darktide-mod-framework-dmf)
and are not re-copied here; Relay does not modify or re-host any of them.
Relay does not bundle DMF — the operator or calling application stages stock
DMF under the configured mod root.

### What the loader boundary means for DMF

- **Entry via `dmf.mod` `run()`.** DMF loads like any entry: the loader
  executes `dmf/dmf.mod`, calls its `run()`, which returns the
  `dmf_mod_object` — a plain singleton table with
  `init`/`update`/`on_game_state_changed`/`on_unload`/`on_reload`, not a
  class instance. The loader stores it and calls `init()` synchronously,
  before the next entry loads; that `init()` loads all of DMF's framework
  modules (two phases), with the io observer adapting `DMFMod:io_*`
  mid-init.
- **DMF-driven inner loop.** A user mod whose `.mod` `run()` returns **nil**
  (the typical authoring pattern) registered itself via `new_mod(...)` for
  its side effect; the loader treats that as success and leaves the mod to
  DMF's inner update loop. An outer-driven object (a `run()` that returned a
  table — DMF itself is the canonical example) is driven directly by Relay's
  manager. Two driving loops, one owner each: the manager drives outer
  objects; DMF drives its registered mods.
- **DMF reads only the loader contract.** DMF's reads off the loader are
  exactly the three surfaces pinned in the `Managers.mod` shape contract —
  `_mods[_mod_load_index].{id,name,handle,data}` during `DMFMod:init()`,
  `_state == "done"` for `all_mods_loaded`, and
  `_settings.developer_mode` for option registration. Everything else DMF
  provides from its own modules, unmodified.

---

## Mod Loading Flow (End-to-End)

```
1. Caller invokes the launcher
   (a shell, a launch.bat, or an app such as Mod Curator)
        │
        ▼
2. Launcher resolves config (flag > env var > default) and pre-flights:
   → --game-binary required
   → --mod-manager target must exist as a regular file
     (a missing/directory/oversized-env target refuses the launch —
      exit 2, the game process is never created)
   → command line validated (ANSI; ≤ 32,767 chars incl. NUL)
        │
        ▼
3. Launcher publishes the child env (SteamAppId/SteamGameId,
   RELAY_MOD_PATH, RELAY_MOD_MANAGER, RELAY_LOG_FILE, RELAY_LOG_LEVEL,
   canonicalized RELAY_LOG_LUA / RELAY_LOG_APPEND / RELAY_SKIP_SPLASH,
   derived RELAY_MODS_IN_GAME_TREE) and CreateProcess(Darktide.exe,
   SUSPENDED) — game args after -- on the child command line
        │
        ▼
4. Launcher injects relay_shell.dll (CreateRemoteThread); the DllMain
   worker runs:
   → Rust discovery resolves lua_newstate + lua_pcall from the game image
   → MinHook installs exactly the two production hooks
   → trampoline chunk staged
        │
        ▼
5. Worker signals relay_hook_ready → launcher resumes the main thread
   and exits; the game boots
        │
        ▼
6. lua_newstate fires: the hook captures the single Lua VM
        │
        ▼
7. pcall#1: the one-shot trampoline runs BEFORE the original pcall:
   → bakes MOD_LOADER_DIR / RELAY_MOD_PATH / RELAY_MOD_MANAGER /
     MOD_RELAY_VERSION / RELAY_SKIP_SPLASH / RELAY_MODS_IN_GAME_TREE
   → io.open <MOD_LOADER_DIR>/init.lua → loadstring → run
   → the entry captures io/loadstring/require/print/os into Mods,
     publishes the FFI module, installs the require bridge + the
     lifecycle coordinator
        │
        ▼
8. Deferred bootstrap advances with the engine's boot requires
   (the BootStateRequireGameScripts._state_update wrap):
   → class registry installed once global class() appears
   → Step 1a/1b: manager class loaded; Managers.mod = <class>:new()
     → init() SCANs: reads mods.lst, builds _mods (no mod loaded)
   → Step 1c chassis duties: establish() (publish Managers.mod,
     restore _settings when nil), the DMF io observer, the
     ModRelay:Version attempt
   → Steps 2–4: StateGame.update / GameStateMachine._change_state /
     GameStateMachine.destroy wrapped (opt-in Step 5: StateSplash)
        │
        ▼
9. First StateGame.update (the load-pass anchor update):
   Managers.mod:update(dt)
   performs pass bookkeeping only — no entries load (the scan ran at manager
   creation). Each subsequent update loads at most the next entry, in
   mods.lst order, then drives update(dt) for every outer object loaded
   so far:
   a. DMF first (listed first), on the update after the anchor (stage 0):
      dmf.mod executed → entry.data
      published → run() returns the dmf_mod_object → init() loads
      the framework modules (the io observer adapts DMFMod:io_*
      mid-init, before Phase 2)
   b. each user mod in order, one per update: run() → nil (DMF-driven) or
      table (outer-driven → init() before any later entry loads)
   c. on the last entry's load update: _mod_load_index cleared once (at
      pass finalize); _state = "done" published
         │
         ▼
10. DMF's own update (driven every update from its own load update onward —
    updates overlap the pass) polls Managers.mod._state == "done" and,
    the first time it sees it — no earlier than the finalize update's own
    update drive — fires all_mods_loaded to its registered user mods
         │
         ▼
11. Per-frame driving: each StateGame.update wrap drives
    Managers.mod:update(dt) before the engine update — outer objects'
    update(dt) (DMF among them; DMF's inner loop drives its registered
    mods), the reload-shortcut poll, and the reload state machine
    (optional hot reload: LEFT Ctrl + Left Shift + R in developer mode
    → teardown frame → replacement replay: anchor update, then one entry
    per update)
        │
        ▼
12. Shutdown: the GameStateMachine.destroy wrap dispatches one final
    (deduplicated) on_game_state_changed("exit", …) for the active
    state; ModManager:destroy() calls on_unload on outer objects in
    reverse load order; DMF fires its own unload to its registered
    user mods through its inner loop
```

---

## Technology Summary

| Component | Language | Runtime | Key dependencies |
|-----------|----------|---------|------------------|
| Mod Relay launcher (`mod_relay.exe`) | C | Native Windows process (out of game) | Win32 (`CreateProcess`, `CreateRemoteThread`) |
| Injected shell (`relay_shell.dll`) | C | Inside `Darktide.exe` | MinHook (the two detours); the Rust discovery staticlib |
| Discovery engine | Rust | C-ABI staticlib linked into the shell DLL | Capstone + its Rust bindings (see `THIRD_PARTY_NOTICES.md`) |
| Mod loader (`mod_loader/`) | Lua | Darktide's LuaJIT VM (engine-hosted) | None — engine facilities captured at pcall#1 |
| Darktide-Mod-Framework (DMF) | Lua | Darktide engine | Unchanged from the community stack |

The Relay-added runtime is C + Rust + Lua with **zero game-file
modification**: the launcher is an ordinary native process, the shell is one
injected DLL that detours exactly two LuaJIT C-API functions, and the mod
loader is staged Lua running on the engine's own VM. DMF and user mods are
the same components the community stack uses, loaded rather than patched in.
Legal notices ship in every distributable bundle: `make build` stages the
root `LICENSE` (GPL-3.0) and `THIRD_PARTY_NOTICES.md` (the notices for the
statically-linked MinHook + Capstone dependencies) beside the executables,
and the release bundle zips that directory.

### How Relay's entry differs from the community chain

- **Injection, not bundle patching.** No `bundle_database.data` record is
  modified, no `patch_999` layer is registered, and no `main.lua` is
  replaced — the engine's own startup runs unmodified, and the loader enters
  through the pcall#1 trampoline the injected shell stages.
- **Vanilla by default.** A normal Steam launch does not involve Relay at
  all; there is nothing in the game directory to undo, and disabling mods
  means launching without the Relay launcher.
- **Game-update resilience.** The community entry is reverted by every game
  update or Steam file verification and must be re-applied; Relay's entry has
  no game file to revert, and discovery self-validates against any build
  (Tier-2 everywhere; Tier-1 exact-match skips on SHA mismatch).
