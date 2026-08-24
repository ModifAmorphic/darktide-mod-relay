# Mod Relay load phases (phase scheduling)

> **Status:** The phase scheduler is **implemented** for the default
> schedule: a plain `mods.lst` is interpreted positionally — entry i
> (1-based list position) loads at phase i, exactly one entry per manager
> tick (the community loader's pacing; DMF lands at phase 1 whenever it is
> listed first). This document is the normative contract for that behavior
> and for the phase-number semantics any future schedule carrier builds on.
> **Authored schedules** — the future carrier that loads multiple mods per
> phase ("tier"), organized into stages by dependencies and/or load-order
> requirements — are **not implemented**, and their shape is TBD (see
> [Scheduling carrier](#scheduling-carrier)).

---

## Context: the boot timeline

Two traced boots (2026-08-22 and 2026-08-23; same machine, same build family,
skip-splash on). Absolute frame numbers vary with hardware and build; the
structure from the load pass onward was identical. Both traces predate phased
loading — the load rows below show the old single-tick pass, retained as
baseline evidence; the anchor definition and the post-anchor structure are
what the phased loader carries forward.

| Event | Boot A | Boot B | Variable? |
| --- | --- | --- | --- |
| Injection (pcall#1; `init.lua` loads; tick 0) | frame −1 | frame −1 | — (pre-first-update) |
| Boot-state + foundation classes register | 28 | 30 | yes |
| Relay manager created + `mods.lst` scan | ~29¹ | ~31¹ | yes |
| **Load pass begins** (phase 0 anchor — the first `StateGame.update` manager tick) | **32** | **34** | start varies; defined by an engine event |
| All entries run/init in one tick (pre-phasing behavior; the phased loader loads one entry per tick from the anchor) | 32 | 34 | — |
| `TitleView` registers + StateTitle entered | 33 | 35 | **anchor + 1 engine update — both boots** |

¹ Approximate: the `manager created` landing line is DEBUG (unstamped); its
position is bounded by the stamped state-dispatch lines around it.

Two facts follow:

1. **The prelude varies.** Everything between injection and the load pass —
   boot states, the foundation class sweep, Relay's manager creation and scan
   (which loads no mods) — floats by a few frames. That variance is why
   absolute frames are diagnostic only, never scheduling inputs.
2. **The post-anchor structure is stable.** In both traces the lazy title/view
   classes (`TitleView`) published exactly one engine update after the
   load-pass anchor tick. The relationships that matter for scheduling are
   relative to the anchor, and they held across boots with different absolute
   frames.

## The anchor: phase 0 is the load-pass begin tick

There is one counter and one anchor:

- **tick** — the loader's counter (epoch: injection at pcall#1, +1 per engine
  update). Used for diagnostics; correlates trace lines across a boot.
- **Phase 0** — the load-pass anchor: the first `StateGame.update` manager
  tick. In a trace, the tick carrying the `load pass begin (initial)` line.
  Phase 0 loads **no** entries — pass bookkeeping only (the pass bracket and
  the Crashify generation prep; the scan ran earlier, at manager creation).

A phase number is an offset from that anchor:

> **A mod scheduled at phase P loads on the manager tick exactly P engine
> updates after phase 0.**

Phase 1 is one engine update after the anchor. Phase 3 is three engine
updates after the anchor. The anchor is an engine event, observable in every
trace, independent of machine speed and boot length.

`Relay manager created` is deliberately **not** the anchor: it floats with
boot noise and performs no mod loading (scan only).

## Phase semantics

Within each tick, the lifecycle wrap fixes the ordering:

```
tick (phase 0):    [manager: pass bookkeeping — no entries load]  →  [engine update]
tick (phase 1):    [manager: entry 1 loads; updates driven]      →  [engine update]
tick (phase 2):    [manager: entry 2 loads; updates driven]      →  [engine update]
```

The manager slot runs **before** the engine's update within each tick, and
each tick does at most one load step:

> **At most one entry loads per tick; then `update(dt)` is driven for every
> outer object loaded so far.**

Therefore:

> **A mod scheduled at phase P has its entry code (`.mod` execution,
> `run()`, `init()`) executed after exactly P engine updates have completed
> following the phase-0 anchor.**

- A mod scheduled at phase 1 always loads exactly one engine update after
  the anchor — regardless of when the pass itself started, the boot length,
  or the machine.
- **An outer mod's first `update` lands on its own load tick**, and
  already-loaded mods keep updating while later entries still load — the
  community loader's pacing ("advances one listed mod per loading update …
  calls `update(dt)` on each loaded mod every frame"). Relay's pre-phasing
  loader completed every init inside the pass tick before any update ran.
- **Empty phases burn their tick.** Phase numbers count engine updates, not
  non-empty phases. If phases 1 and 3 have entries but phase 2 is empty,
  phase 3 still means three engine updates after the anchor. Collapsing
  empty phases would make the phase number's meaning depend on schedule
  contents and break the guarantee. (The positional default never produces
  an empty phase — entry i is at phase i, contiguous 1..K — but the rule is
  the foundation the future authored carrier builds on.)
- **Within a phase, entries load atomically in `mods.lst` order.** The
  per-pass determinism — order preservation, sequential init, per-entry
  fault isolation — holds inside each phase boundary. Under the positional
  default each phase has exactly one entry; this rule is what a future
  multi-entry (authored) phase inherits.

**`on_game_state_changed` during the pass.** State changes dispatch to
already-loaded entries while the initial pass runs — community parity with
the update interleaving. A mod scheduled at phase P sees the state changes
fired after its own load tick; changes fired before it are uncatchable by
its load-time code (the same
[fired-before edge](#visibility-guarantee-and-its-limit) as any load-time
hook). Three windows remain suppressed, each with a single debug log per
suppressed period: the **reload window** (the teardown frame plus the
replacement replay — never dispatch into half-torn-down objects) and the
**pre-anchor window** (manager created, pass not yet begun — nothing is
loaded, a natural no-op). **Post-destroy** a manager dispatches nothing
further — through the gate when the pass never finalized (suppressed, with
the same single debug log), or through the emptied entry table after a
completed pass (the gate is open; every `entry.object` is gone).

## Default scheduling (positional)

In scope today: **a plain `mods.lst`, interpreted positionally** — no
schedule sidecar exists.

- **Entry i (1-based `mods.lst` position) loads at phase i** — the manager
  tick exactly i engine updates after the anchor. A K-entry list whose
  anchor is tick N completes at tick N+K.
- **DMF-first lists put DMF at phase 1 naturally** — one engine update of
  engine publication before the framework loads; everything downstream
  depends on it. Relay injects nothing: DMF is at phase 1 because it is
  listed first (the community loader likewise always orders DMF first).
- **Failed or invalid entries burn their phase.** The cadence stays
  tick-aligned — a mod's phase is always its list position, regardless of
  sibling failures.
- **An empty or missing `mods.lst`** begins AND finalizes the pass on the
  anchor tick (a `0 entries` completion summary for the empty case; the
  missing-list warning is unchanged).
- **Pass finalize lands on the same tick as the last entry's load**:
  `end_load_pass` (clearing the DMF-visible `_mod_load_index`),
  `mark_load_done`, generation bookkeeping, and the DEBUG
  `initial load pass complete: N entries, M failed` summary — plus the
  TRACE `load pass end (initial, generation G)` / `load pass end (reload,
  generation G)` line, source-gated like the other trace lines.

**`_mod_load_index` mid-pass (DMF-visible).** The index is set to the
entry's index at its tick and **persists between entry ticks** — visible
across engine updates while the pass runs (community parity) — and is
cleared **once**, at pass finalize.

## Failure semantics during the pass

- **Entry-local failures stay isolated and tick-aligned.** A missing or
  malformed descriptor, a throwing `run()`, or an invalid result marks only
  that entry `failed`; the next entry still loads at its own tick (the
  failed entry burned its phase).
- **A framework-boundary failure finalizes the pass at the failure tick.**
  An escaped outer lifecycle error on the entry named `dmf` stops the
  generation on that tick: remaining entries are `skipped` (one trace line
  each — they never get their own load ticks), reverse-order exactly-once
  cleanup runs, the DMF generation globals are retired, and `_state` still
  reaches `done` (developer-mode hot reload remains the recovery path).
  Because updates overlap the pass, the escape can also fire during the
  update drive on a mid-pass tick; the pass then finalizes on the next
  tick's load step with the same semantics.
- **An escaped load-step error finalizes the pass with errors.** Something
  raising through the per-tick load containment ends the pass; remaining
  entries stay `not_loaded`.

## Hot reload (the replacement replay)

The teardown frame is unchanged: `on_reload` forward, `on_unload` reverse,
rescan, `_state` nil. The replacement is a **replay** of the phased pass: an
anchor tick (`load pass begin (reload, generation G)` — no entries) then one
entry per tick. `mark_load_done`, the generation increment, and the
completion INFO/WARN land on the final replay tick. Per-name reload data is
retained across the replay and delivered to each entry at its tick. Reload
requests are refused while the pass is active ("manager not done").

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

## Scheduling carrier

- **`mods.lst` — bytes untouched, interpreted positionally.** The same file
  the community toolchain authors; Relay derives each entry's phase from its
  list position (entry i → phase i). There is no phase-unaware mode — every
  plain `mods.lst` gets the phased default above.
- **The authored-schedule carrier — future work, shape TBD.** The operator
  will eventually add loading **multiple mods per phase** ("tier"), driven
  by a **differently-shaped mods file** that organizes mods into stages by
  dependencies and/or load-order requirements. This direction supersedes the
  previously-spec'd `modsScheduling.json` sidecar concept — no sidecar
  format is settled. The phase-number semantics above (offsets from the
  phase-0 anchor, empty phases burning their tick) remain the foundation
  whatever shape the carrier takes.

### Tier guidance for authored schedules (future work — unimplemented)

The tier table below is recorded intent for **schedule authors** (Mod
Curator, other mod managers) once the future carrier exists. It is guidance
for that authored carrier — **not** Relay's default (the default is
positional):

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

## Settled by the phased implementation

The three items this document previously recorded as open design decisions
are settled and implemented:

- **Absence of a schedule file** → the positional phased default above.
  Every plain `mods.lst` is scheduled positionally; there is no legacy
  single-pass mode.
- **Per-phase failure semantics** → implemented as specified in
  [Failure semantics during the pass](#failure-semantics-during-the-pass):
  per-entry isolation, failed entries burning their phase, and a framework
  (`dmf`) failure finalizing the pass at the failure tick.
- **Hot reload** → implemented as the replacement replay (teardown frame,
  then the anchor tick + one entry per tick) instead of a single replacement
  frame.

## Open design decisions (recorded, not settled)

- **The authored multi-mod-per-phase carrier.** Loading multiple mods per
  phase ("tier") from a differently-shaped mods file organized into stages by
  dependencies and/or load-order requirements. The carrier's SHAPE is
  TBD (the `modsScheduling.json` sidecar concept is superseded); the
  phase-number semantics above are the foundation.
