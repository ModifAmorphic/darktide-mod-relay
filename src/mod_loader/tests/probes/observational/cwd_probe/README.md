# Scenario: `observational/cwd_probe` — process CWD observational probe

A **non-shipped**, **read-only** observational probe that reads the live game
process's **current working directory (CWD)** three ways — primary via LuaJIT
FFI (`GetCurrentDirectoryW`), cross-checked via `io.popen("cd")` — plus the
host executable path (`GetModuleFileNameW`) and the mod-path context. It lets
an operator determine, in the real game, **whether the CWD is
`{GAME_DIR}\binaries`** before deciding whether Relay should `chdir` to
`<mod_path>\mods`. The probe **does NOT change the CWD** — it only reads it.

> This probe is **not executed** by the offline LuaJIT harness and is **not part
> of the shipped runtime**. `../../../test_probes.lua` structurally
> validates it (compile + markers) as part of `make mod-loader-test`. It runs only
> when staged into the real game.

## What it does

On each generation's `init`, it runs four cases, then a `SESSION_DONE`
trailer. Each case is `pcall`-contained; on failure it emits a
`status=unavailable` marker and continues. A process-lifetime `load=N` tag
distinguishes generations across hot reloads.

| Case | Marker payload | Reads |
| --- | --- | --- |
| `cwd_ffi` | `cwd_ffi=<path>` | primary CWD via LuaJIT FFI + Win32 `GetCurrentDirectoryW` (UTF-16 → UTF-8) |
| `exe_path` | `exe_path=<path>` | host exe full path via `GetModuleFileNameW(NULL,…)` (NULL module = current process exe) |
| `cwd_popen` | `cwd_popen=<path>` | cross-check via the engine's raw `io.popen("cd")` (the exact surface popen-using mods hit — Relay wraps `io.open`/`io.lines` but NOT `io.popen`) |
| `context` | `mod_path=<p> mod_root=<r>` | the eventual chdir targets — `Mods._mod_path` (the mod-path config) + `Mods._mod_root` (the mods dir) |

The probe is **read-only**: it installs no hooks, raises no errors (every case
is `pcall`-contained), and **never** calls `SetCurrentDirectory`,
`os.execute`, or any chdir — it only reads. Each line is emitted to **both**
the console (via the captured `print`) and the scenario log (via rooted
`Mods.lua.io.open`, close-always-runs).

> **LuaJIT FFI cdef note:** per LuaJIT FFI semantics, `ffi.cdef` silently
> ignores identical re-declarations but throws "attempt to redeclare symbol"
> on a conflicting (different-signature) one. The probe pcalls the cdef,
> covering both cases (the symbols are already declared from whoever ran
> first; the probe proceeds either way). This is the key robustness
> requirement — another mod or engine path may have declared the same Win32
> symbols first.

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Authoritative order: exactly `cwd_probe` |
| `mods/cwd_probe/cwd_probe.mod` | Outer object that reads the CWD three ways + the exe path + the mod-path context, one case per `init` |

## Staging

This scenario is a **complete bundle**: its root directory *is* the
`<mod_path>` (the directory that *contains* a `mods/` subdir). Launch it
directly — no copying a leaf folder, no merging a `mods.lst` line, no Lua
editing. The prior multi-step copy+merge staging — which left room for operator
error (a forgotten `mods.lst` line, a mis-named leaf folder, a stray merge into
a profile you cared about) — no longer applies: the bundle's own
`mods/mods.lst` already lists exactly `cwd_probe`.

Either point `--mod-path` straight at this scenario root, or copy the scenario
root (as a unit) into your own staging directory and point `--mod-path` at the
copy. Use an **isolated** staging root (never overlay a probe onto a profile
you care about).

## Launch variants

Point `--mod-path` at this scenario root (`<path-to-observational/cwd_probe>`):

| Variant | Invocation |
| --- | --- |
| Default off | `mod_relay.exe --game-binary <exe> --mod-path <path-to-observational/cwd_probe>` |
| `--log-lua` on | add `--log-lua` (so the probe lines also reach `relay.log`) |
| Env on | `RELAY_LOG_LUA=1` (and no `--log-lua`) |
| Vanilla | launch the game from Steam (without Relay) — unaffected |

## Expected evidence

- **Darktide console log** (`console-*.log`): every `[CWD_PROBE]` line the
  probe printed, regardless of the tee (console remains authoritative and
  unchanged; the tee only adds `relay.log` copies).
- **`relay.log`** (next to the launcher): when the tee is on (`--log-lua` /
  `RELAY_LOG_LUA=1`), one structured `INFO  lua:` line per probe line.
  A captured probe line looks like:
  `2026-07-25T12:34:56-04:00 INFO  lua: [CWD_PROBE] case=cwd_ffi load=1 cwd_ffi=C:\Program Files (x86)\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\binaries`
- **Scenario log** (`<mod_path>/mods/cwd_probe/cwd_probe.log`): every probe
  line (same content as the console) — operator convenience, a persistent
  record that survives console-log truncation at process exit.

## How to read the result

- If `cwd_ffi` equals the **parent directory** of `exe_path`, then the CWD
  **is** `{GAME_DIR}\binaries` (the exe lives in `binaries`, so its parent dir
  is `binaries` itself — compare the two strings directly).
- If `cwd_ffi` and `cwd_popen` **agree** (same path string), the answer is
  high-confidence: two independent surfaces (Win32 FFI + `io.popen("cd")`)
  returned the same value.
- `mod_path` / `mod_root` show the eventual chdir targets so the operator can
  eyeball whether CWD already matches `<mod_path>\mods` or would need to
  change.

## Acceptance matrix

| # | Check | Expected result |
| --- | --- | --- |
| 1 | **Default off** (no flag/env) | console log + scenario log have the probe markers; `relay.log` has **no** `lua:` probe lines (and no `[CWD_PROBE]`). |
| 2 | **`--log-lua` on** (or `RELAY_LOG_LUA=1`) | every probe marker appears once in console **and** once as a `lua:` line in `relay.log`. |
| 3 | **`cwd_ffi == cwd_popen`** | the FFI CWD and the popen CWD agree (same path string). |
| 4 | **`exe_path` present** | `exe_path` is non-empty (a real path to the host exe). |
| 5 | **No duplication across reloads** | perform at least **three** clean hot reloads (LEFT Ctrl + LEFT Shift + R). Per generation, each case produces **exactly one** `load=N` set — never duplicates. |
| 6 | **Vanilla unaffected** | a normal Steam launch (without Relay) runs the game unmodified; nothing of Relay's exists. |

## Cleanup

1. Point `--mod-path` elsewhere (or relaunch from Steam for vanilla play). The
   whole scenario is one bundle, so there is no `mods.lst` line to edit.
2. Delete the scenario log (`<mod_path>/mods/cwd_probe/cwd_probe.log`) if it
   accrued.
3. Leave `relay.log` / `console-*.log` as-is, or clear them per your usual
   workflow.

Re-launch to confirm the probe is gone (no `[CWD_PROBE]` markers).
