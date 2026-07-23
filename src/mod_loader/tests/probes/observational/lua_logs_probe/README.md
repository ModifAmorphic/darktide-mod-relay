# Scenario: `observational/lua_logs_probe` — Lua print tee observational probe

A **non-shipped**, **read-only** observational probe for Relay's
optional Lua print tee (`--lua-logs` / `RELAY_LUA_LOGS=1`). It emits unique
`[LUA_LOGS_PROBE]` markers through the engine's global `print` and `__print`
surfaces so an operator can confirm — in the real game — what the tee captures,
how it sanitizes, and that it does not stack.

> This probe is **not executed** by the offline LuaJIT harness and is **not part
> of the shipped runtime**. `../../../test_probes.lua` structurally
validates it (compile + markers) as part of `make mod-loader-test`. It runs only
when staged into the real game.

## What it does

On each generation's `init`, it runs seven cases, one per tee policy, then a
`SESSION_DONE` trailer. Each case calls a wrapped print surface (so console
output is preserved and, when the tee is on, `relay.log` receives the copy). A
process-lifetime `load=N` tag distinguishes generations across hot reloads.

| Case | Marker payload | Exercises |
| --- | --- | --- |
| `simple_print` | one string via `print` | basic global `print` tee |
| `simple_dprint` | one string via `__print` | global `__print` tee (records `status=unavailable` if `__print` is not a function) |
| `multi_args` | `print(..., 42, true, nil)` | multi-arg + trailing-nil rendering (count preserved) |
| `multiline_crlf` | `\n` + `\r\n` in one string | native line splitting into separately-prefixed `relay.log` lines |
| `percent_fmt` | literal `100% done %s %d %%` | `%` / format-looking text preserved as data |
| `control_bytes` | NUL/SOH/ESC/DEL via `string.char` | control-byte sanitization to `\xNN` (no NUL truncation, no forged lines) |
| `over_budget` | `>4096`-byte payload | exactly one native truncation marker |

The probe is **read-only**: it installs no hooks, raises no errors (every case is
`pcall`-contained), and **never** touches Relay's private sink/temporary global
directly. Coverage is **observed, not guaranteed**: DMF may replace global
`print` after this mod loads, so what this probe sees is the surface as it was at
mod-load time.

> **Expected console quirk (case `control_bytes`):** the engine's own console
> `print` may truncate that line at the first NUL byte — that is the engine's
> unchanged behavior (Relay does not touch the console path). The `relay.log`
> copy shows the full sanitized bytes (`nul\x00soh\x01esc\x1bdel\x7f`).

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Authoritative order: exactly `lua_logs_probe` |
| `mods/lua_logs_probe/lua_logs_probe.mod` | Outer object that emits one marker per tee policy, one case per `init` |

## Staging

This scenario is a **complete bundle**: its root directory *is* the
`<mod_path>` (the directory that *contains* a `mods/` subdir). Launch it
directly — no copying a leaf folder, no merging a `mods.lst` line, no Lua
editing. The prior multi-step copy+merge staging — which left room for operator
error (a forgotten `mods.lst` line, a mis-named leaf folder, a stray merge into
a profile you cared about) — no longer applies: the bundle's own
`mods/mods.lst` already lists exactly `lua_logs_probe`.

Either point `--mod-path` straight at this scenario root, or copy the scenario
root (as a unit) into your own staging directory and point `--mod-path` at the
copy. Use an **isolated** staging root when also exercising the
failure-injection probes (never overlay those onto a profile you care about).

## Launch variants

Point `--mod-path` at this scenario root (`<path-to-observational/lua_logs_probe>`):

| Variant | Invocation |
| --- | --- |
| Default off | `mod_relay.exe --game-binary <exe> --mod-path <path-to-observational/lua_logs_probe>` |
| CLI on | add `--lua-logs` |
| Env on | `RELAY_LUA_LOGS=1` (and no `--lua-logs`) |
| Log-level gate | add `--log-level warn` to the CLI-on variant |
| Vanilla | launch the game from Steam (without Relay) — unaffected |

## Expected evidence

- **Darktide console log** (`console-*.log`): every `[LUA_LOGS_PROBE]` line the
  probe printed, regardless of the tee (console remains authoritative and
  unchanged; the tee only adds `relay.log` copies).
- **`relay.log`** (next to the launcher): when the tee is on, one structured
  `INFO  lua-print:` line per physical line emitted through the wrapped surfaces.
  A captured probe line looks like:
  `2026-07-23T12:34:56-04:00 INFO  lua-print: [LUA_LOGS_PROBE] case=simple_print load=1 hello-from-print`
- **Scenario log** (`<mod_path>/mods/lua_logs_probe/lua_logs_probe.log`): one
  status line per case (`status=ok` / `status=unavailable`), plus the
  `SESSION_START` / `SESSION_DONE` markers — operator convenience for aligning
  cases to `relay.log` lines.

## Acceptance matrix

| # | Check | Expected result |
| --- | --- | --- |
| 1 | **Default off** (no flag/env) | console log has the probe markers; `relay.log` has **no** `lua-print:` probe lines (and no `[LUA_LOGS_PROBE]`). |
| 2 | **CLI on** (`--lua-logs`) | every bounded probe marker appears once in console **and** once as a `lua-print:` line in `relay.log`. |
| 3 | **Env on** (`RELAY_LUA_LOGS=1`) | behavior identical to CLI on. |
| 4 | **Formatting / sanitization / truncation** | `multiline_crlf` → multiple separately-prefixed `relay.log` lines; `percent_fmt` → `%`/`%s`/`%d` preserved literally; `control_bytes` → `\x00`/`\x01`/`\x1b`/`\x7f` (no raw control bytes, no malformed unprefixed lines); `over_budget` → exactly one `... truncated` marker after the budget bytes. |
| 5 | **`--log-level warn`** | with the tee on, `INFO  lua-print:` lines are **absent** from `relay.log` while console output remains. |
| 6 | **No stacking across reloads** | perform at least **three** clean hot reloads (LEFT Ctrl + LEFT Shift + R). Per generation, each probe marker produces **exactly one** `relay.log` copy (load=N distinguishes generations) — never duplicates. |
| 7 | **Vanilla unaffected** | a normal Steam launch (without Relay) runs the game unmodified; nothing of Relay's exists. |

## Stock-DMF black-box coverage (separate operator check)

This probe only exercises Relay's wrapped `print` / `__print` surfaces. Whether
stock-DMF `mod:info` / `mod:warning` / `mod:error` calls traverse those wrapped
surfaces (and therefore also reach `relay.log`) is a **separate, black-box
check**: invoke those paths from a disposable operator-owned test mod and record
which lines appear in `relay.log`. **Coverage is recorded, not guaranteed** —
document the observed result without changing DMF or wrapping its methods.

## Cleanup

1. Point `--mod-path` elsewhere (or relaunch from Steam for vanilla play). The
   whole scenario is one bundle, so there is no `mods.lst` line to edit.
2. Delete the scenario log (`<mod_path>/mods/lua_logs_probe/lua_logs_probe.log`)
   if it accrued.
3. Leave `relay.log` / `console-*.log` as-is, or clear them per your usual workflow.

Re-launch to confirm the probe is gone (no `[LUA_LOGS_PROBE]` markers).
