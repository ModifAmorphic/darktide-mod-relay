# Mod Relay load phases (phase scheduling)

> **Status:** Design specification. This document defines the phase-scheduling
> contract for the mod loader's initial load: the anchor, phase semantics,
> the visibility guarantee and its limit, and the default tier assignments.
> The scheduler itself is **not yet implemented**; the tick/frame
> instrumentation and the observed timeline below reflect the current runtime.
> Once implemented, this is the normative contract for schedule authors
> (Mod Curator, other mod managers, hand-written sidecars).

---

## Context: the boot timeline

Two traced boots (2026-08-22 and 2026-08-23; same machine, same build family,
skip-splash on). Absolute frame numbers vary with hardware and build; the
structure from the load pass onward was identical.

| Event | Boot A | Boot B | Variable? |
| --- | --- | --- | --- |
| Injection (pcall#1; `init.lua` loads; tick 0) | frame −1 | frame −1 | — (pre-first-update) |
| Boot-state + foundation classes register | 28 | 30 | yes |
| Relay manager created + `mods.lst` scan | ~29¹ | ~31¹ | yes |
| **Load pass** (first `StateGame.update` manager tick) | **32** | **34** | start varies; defined by an engine event |
| All entries run/init in one tick (current atomic behavior) | 32 | 34 | — |
| `TitleView` registers + StateTitle entered | 33 | 35 | **pass + 1 engine update — both boots** |

¹ Approximate: the `manager created` landing line is DEBUG (unstamped); its
position is bounded by the stamped state-dispatch lines around it.

Two facts follow:

1. **The prelude varies.** Everything between injection and the load pass —
   boot states, the foundation class sweep, Relay's manager creation and scan
   (which loads no mods) — floats by a few frames. That variance is why
   absolute frames are diagnostic only, never scheduling inputs.
2. **The post-pass structure is stable.** In both traces the lazy title/view
   classes (`TitleView`) published exactly one engine update after the
   load-pass tick. The relationships that matter for scheduling are relative
   to the pass, and they held across boots with different absolute frames.

## The anchor: phase 0 is the load pass

There is one counter and one anchor:

- **tick** — the loader's counter (epoch: injection at pcall#1, +1 per engine
  update). Used for diagnostics; correlates trace lines across a boot.
- **Phase 0** — the initial load pass: the first `StateGame.update` manager
  tick. In a trace, the tick carrying the `load pass begin (initial)` line.

A phase number is an offset from that anchor:

> **A mod scheduled at phase P loads on the manager tick exactly P engine
> updates after phase 0.**

Phase 1 is one engine update after the pass. Phase 3 is three engine updates
after the pass. The anchor is an engine event, observable in every trace,
independent of machine speed and boot length.

`Relay manager created` is deliberately **not** the anchor: it floats with
boot noise and performs no mod loading (scan only).

## Phase semantics

Within each tick, the lifecycle wrap fixes the ordering:

```
tick (phase 0):    [manager: phase 0 entries load]   →  [engine update]
tick (phase 1):    [manager: phase 1 entries load]   →  [engine update]
tick (phase 2):    [manager: phase 2 entries load]   →  [engine update]
```

The manager slot runs **before** the engine's update within each tick.
Therefore:

> **A mod scheduled at phase P has its entry code (`.mod` execution,
> `run()`, `init()`) executed after exactly P engine updates have completed
> following the initial load pass.**

- A mod scheduled at phase 1 always loads exactly one engine update after
  the initial load pass — regardless of when the pass itself started, the
  boot length, or the machine.
- **Empty phases burn their tick.** Phase numbers count engine updates, not
  non-empty phases. If phases 1 and 3 have entries but phase 2 is empty,
  phase 3 still means three engine updates after the pass. Collapsing empty
  phases would make the phase number's meaning depend on schedule contents
  and break the guarantee.
- **Within a phase, entries load atomically in `mods.lst` order.** The
  current per-pass determinism — order preservation, sequential init,
  per-entry fault isolation — holds inside each phase boundary.

## Visibility guarantee and its limit

**Published-by edge (the guarantee):** any engine state, class registration,
or object that exists during boot, or is published during the engine update
of an earlier phase, is fully available to code running in a later phase.
This is why `TitleView` — published during phase 0's engine update — is
guaranteed to exist for phase 1 and later.

**Fired-before edge (the limit):** load-time hooks can only observe events
that have not yet fired. A one-shot event (e.g. `TitleView:on_enter`) that
fires during an earlier phase's engine update cannot be caught by a mod
loading in a later phase — the hook installs cleanly and never fires. Every
phase assignment therefore has a window, not just an earliest edge:

```
earliest safe phase : target class registered      (published-by edge)
latest useful phase : target one-shot not yet fired (fired-before edge)
```

Schedule a mod at the earliest phase that satisfies its requirements; later
is not safer.

## Default tiers

| Phase | Occupants | Rationale |
| --- | --- | --- |
| 0 | Relay-owned init (the scan is already complete by this tick), probes, future Relay framework material | The anchor |
| 1 | DMF | One engine update of publication before the framework loads; everything downstream depends on it |
| 2 | Mods other mods depend on that hook engine classes published during phase 0's engine update (the LogMeIn class: unsafe hook on `TitleView`, which exists by phase 1's manager slot) | Depended-on early |
| 3 | Everything else | Default bulk |
| 4+ | Derived: a mod that depends on a mod assigned to phase 3 goes to phase 4, and so on | Computed by the schedule author (e.g. Mod Curator) |

The only hardcoded occupants are Relay's own (phase 0). Every other
assignment is schedule data; the loader interprets phase numbers, it does
not know mod names.

## Scheduling carrier

- **`modsScheduling.json`** — a sidecar at the mod root, beside `mods.lst`,
  mapping mod names to phase numbers. Authored by Mod Curator, another mod
  manager, or by hand.
- **`mods.lst` stays untouched** — byte-compatible with the community's
  `mod_load_order.txt` semantics. A manager that knows nothing about phases
  hands Relay a plain `mods.lst` and gets legacy single-pass behavior; Relay
  remains drop-in for tooling built around the community toolchain.

## Open design decisions (recorded, not settled)

- **Absence of a schedule file:** proposed — today's single-pass behavior,
  byte-for-byte. Opt-in feature; rollback is deleting the sidecar.
- **Per-phase failure semantics:** proposed — current per-entry isolation
  within a phase; a framework (`dmf`) failure at phase 1 stops later phases
  (phase-aware generation stop).
- **Hot reload:** proposed — teardown frame, then the phase sequence replays
  (phase 0 through the highest assigned phase) instead of a single
  replacement frame.
