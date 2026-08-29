# Mod Relay load stages (stage scheduling)

> **Status:** Stage scheduling is **implemented** for the default schedule:
> a plain `mods.lst` is interpreted positionally — entry i (1-based list
> position) loads on the i-th update after the load-pass anchor, exactly one
> entry per update (the community loader's pacing; DMF lands at stage 0
> whenever it is listed first). This document is the normative contract for
> that behavior and for the stage/update/frame vocabulary any future
> schedule carrier builds on. **Authored schedules** — the future carrier
> that loads multiple mods per stage, organized into stages by dependencies
> and/or load-order requirements — are **not implemented**, and their shape
> is TBD (see [Scheduling carrier](#scheduling-carrier)).

---

## Context: the boot timeline

Two traced boots (2026-08-22 and 2026-08-23; same machine, same build family,
skip-splash on). Absolute frame numbers vary with hardware and build; the
structure from the load pass onward was identical. Both traces predate
staged loading — the load rows below show the old single-update pass,
retained as baseline evidence; the anchor definition and the post-anchor
structure are what the staged loader carries forward.

| Event | Boot A | Boot B | Variable? |
| --- | --- | --- | --- |
| Injection (pcall#1; `init.lua` loads; update 0) | frame −1 | frame −1 | — (pre-first-update) |
| Boot-state + foundation classes register | 28 | 30 | yes |
| Relay manager created + `mods.lst` scan | ~29¹ | ~31¹ | yes |
| **Load pass begins** (the load-pass anchor update — the first `StateGame.update` manager update) | **32** | **34** | start varies; defined by an engine event |
| All entries run/init in one update (pre-staging behavior; the staged loader loads one entry per update from the anchor) | 32 | 34 | — |
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
   load-pass anchor. The relationships that matter for scheduling are
   relative to the anchor, and they held across boots with different absolute
   frames.

## The counters: update, stage, frame

Three quantities, one vocabulary:

- **update** — the loader's master counter (epoch: injection at pcall#1, +1
  per engine update; "since we started" = since the loader began running at
  injection). Used for diagnostics and pacing; correlates trace lines across
  a boot.
- **stage** — the per-pass load counter: **0 on the update a pass's first
  entry begins loading**, +1 every update thereafter **until all entries of
  the pass have loaded**. It resets per pass — each hot-reload replay's
  first entry is stage 0 again — and appears on stamped lines only while a
  pass is between its first entry's load and its finalize (see
  [logging.md](logging.md) for the exact stamp contract).
- **frame** — the frame number reported by the game (the engine's
  `FRAME_INDEX`), unchanged.

And one anchor:

- **The load-pass anchor update** — the first `StateGame.update` manager
  update. In a trace, the update carrying the `load pass begin (initial)`
  line. The anchor update loads **no** entries — pass bookkeeping only (the
  pass bracket and the Crashify generation prep; the scan ran earlier, at
  manager creation), which is why the pass-begin line carries no stage.

`Relay manager created` is deliberately **not** the anchor: it floats with
boot noise and performs no mod loading (scan only).

## Stage and pacing semantics

Within each update, the lifecycle wrap fixes the ordering:

```
anchor update:    [manager: pass bookkeeping — no entries load]  →  [engine update]
anchor + 1:       [manager: entry 1 loads (stage 0); updates driven]  →  [engine update]
anchor + 2:       [manager: entry 2 loads (stage 1); updates driven]  →  [engine update]
```

The manager slot runs **before** the engine's update within each engine
update, and each update does at most one load step:

> **At most one entry loads per update; then `update(dt)` is driven for every
> outer object loaded so far.**

Therefore, for a `mods.lst` with entries in listed order:

> **Entry i (1-based) loads on the update exactly i engine updates after the
> anchor — at stage i−1 — with its entry code (`.mod` execution, `run()`,
> `init()`) running after exactly i engine updates have completed following
> the anchor update.**

- Entry 1 (typically DMF) always loads exactly one engine update after the
  anchor — regardless of when the pass itself started, the boot length, or
  the machine. A K-entry list finishes at **stage K−1**, and the pass-end
  line carries that stage.
- **An outer mod's first `update` lands on its own load update**, and
  already-loaded mods keep updating while later entries still load — the
  community loader's pacing ("advances one listed mod per loading update …
  calls `update(dt)` on each loaded mod every frame"). Relay's pre-staging
  loader completed every init inside the pass update before any update ran.
- **Empty stages burn their update.** Stage numbers count engine updates,
  not non-empty stages: stage S means S engine updates after the first
  entry's load update. If stages 0 and 2 have entries but stage 1 is empty,
  the stage-2 entry still loads two updates after the stage-0 entry.
  Collapsing empty stages would make the stage number's meaning depend on
  schedule contents and break the guarantee. (The positional default never
  produces an empty stage — entry i is at stage i−1, contiguous 0..K−1 —
  but the rule is the foundation the future authored carrier builds on.)
- **Within a stage, entries load atomically in `mods.lst` order.** The
  per-pass determinism — order preservation, sequential init, per-entry
  fault isolation — holds inside each stage boundary. Under the positional
  default each stage has exactly one entry; this rule is what a future
  multi-entry (authored) stage inherits.

**`on_game_state_changed` during the pass.** State changes dispatch to
already-loaded entries while the initial pass runs — community parity with
the update interleaving. A mod sees the state changes fired after its own
load update; changes fired before it are uncatchable by its load-time code
(the same
[fired-before edge](#visibility-guarantee-and-its-limit) as any load-time
hook). Three windows remain suppressed, each with a single debug log per
suppressed period: the **reload window** (the teardown frame plus the
replacement replay — never dispatch into half-torn-down objects),
**post-destroy** (a destroyed manager dispatches nothing further), and the
**pre-anchor window** (manager created, pass not yet begun — nothing is
loaded, a natural no-op).

## Default scheduling (positional)

In scope today: **a plain `mods.lst`, interpreted positionally** — no
schedule sidecar exists.

- **Entry i (1-based `mods.lst` position) loads on update i after the
  anchor, at stage i−1.** A K-entry list whose anchor is update N completes
  at update N+K, stage K−1.
- **DMF-first lists put DMF at stage 0 naturally.** Relay injects nothing:
  DMF is first because it is listed first (the community loader likewise
  always orders DMF first).
- **Failed or invalid entries burn their update.** The cadence stays
  update-aligned — a mod's stage is always its list position minus one,
  regardless of sibling failures; stage numbering never compresses (a gap
  in loaded entries still advances the stage).
- **An empty or missing `mods.lst`** begins AND finalizes the pass on the
  anchor update (a `0 entries` completion summary for the empty case; the
  missing-list warning is unchanged) — no entry ever loads, so no stage
  appears at all.
- **Pass finalize lands on the same update as the last entry's load**:
  `end_load_pass` (clearing the DMF-visible `_mod_load_index`),
  `mark_load_done`, generation bookkeeping, and the DEBUG
  `initial load pass complete: N entries, M failed` summary — plus the
  TRACE `load pass end (initial, generation G)` / `load pass end (reload,
  generation G)` line, source-gated like the other trace lines, stamped
  with the final stage.

**`_mod_load_index` mid-pass (DMF-visible).** The index is set to the
entry's index at its load update and **persists between entry loads** —
visible across engine updates while the pass runs (community parity) — and
is cleared **once**, at pass finalize.

## Failure semantics during the pass

- **Entry-local failures stay isolated and update-aligned.** A missing or
  malformed descriptor, a throwing `run()`, or an invalid result marks only
  that entry `failed`; the next entry still loads on its own update (the
  failed entry burned it — a failed first entry still sets stage 0; the
  next entry logs stage 1).
- **A framework-boundary failure finalizes the pass at the failure
  update.** An escaped outer lifecycle error on the entry named `dmf` stops
  the generation on that update: remaining entries are `skipped` (one trace
  line each — they never get their own load updates), reverse-order
  exactly-once cleanup runs, the DMF generation globals are retired, and
  `_state` still reaches `done` (developer-mode hot reload remains the
  recovery path). Because updates overlap the pass, the escape can also
  fire during the update drive of a mid-pass update; the pass then
  finalizes on the next update's load step with the same semantics.
- **An escaped load-step error finalizes the pass with errors.** Something
  raising through the per-update load containment ends the pass; remaining
  entries stay `not_loaded`.

## Hot reload (the replacement replay)

The teardown frame is unchanged: `on_reload` forward, `on_unload` reverse,
rescan, `_state` nil. The replacement is a **replay** of the staged pass:
an anchor update (`load pass begin (reload, generation G)` — no entries, no
stage) then one entry per update, the stage counter reset so the replay's
first entry is stage 0. `mark_load_done`, the generation increment, and the
completion INFO/WARN land on the final replay update. Per-name reload data
is retained across the replay and delivered to each entry at its load
update. Reload requests are refused while the pass is active ("manager not
done").

## Visibility guarantee and its limit

**Published-by edge (the guarantee):** any engine state, class registration,
or object that exists during boot, or is published during the engine half of
an earlier update, is fully available to code loading in a later update.
Concretely: everything published through the engine half of the update
before a mod's own load update is visible to it. `TitleView` — published
during the first loading update (the stage-0 update's engine half, exactly
one engine update after the anchor in the traced boots) — is guaranteed to
exist for stage 1 and later; stage 0 (DMF-first lists: DMF itself) sees
everything published through the anchor update's engine half.

**Fired-before edge (the limit):** load-time hooks can only observe events
that have not yet fired. A one-shot event (e.g. `TitleView:on_enter`) that
fires during an earlier update's engine half cannot be caught by a mod
loading in a later update — the hook installs cleanly and never fires.
Every stage assignment therefore has a window, not just an earliest edge:

```
earliest safe stage : target class registered      (published-by edge)
latest useful stage : target one-shot not yet fired (fired-before edge)
```

Schedule a mod at the earliest stage that satisfies its requirements; later
is not safer.

## Scheduling carrier

- **`mods.lst` — bytes untouched, interpreted positionally.** The same file
  the community toolchain authors; Relay derives each entry's stage from its
  list position (entry i → stage i−1). There is no stage-unaware mode —
  every plain `mods.lst` gets the positional default above.
- **The authored-schedule carrier — future work, shape TBD.** The operator
  will eventually add loading **multiple mods per stage**, driven by a
  **differently-shaped mods file** that organizes mods into stages by
  dependencies and/or load-order requirements. This direction supersedes the
  previously-spec'd `modsScheduling.json` sidecar concept — no sidecar
  format is settled. The stage/update semantics above (offsets from the
  anchor, empty stages burning their update) remain the foundation whatever
  shape the carrier takes.

### Stage guidance for authored schedules (future work — unimplemented)

The stage table below is recorded intent for **schedule authors** (Mod
Curator, other mod managers) once the future carrier exists. It is guidance
for that authored carrier — **not** Relay's default (the default is
positional):

| Stage | Occupants | Rationale |
| --- | --- | --- |
| 0 | DMF | First in every community order; everything downstream depends on it |
| 1 | Mods other mods depend on that hook engine classes published during the first loading update (the LogMeIn class: unsafe hook on `TitleView`, which exists by stage 1's load step) | Depended-on early |
| 2 | Everything else | Default bulk |
| 3+ | Derived: a mod that depends on a mod assigned to stage 2 goes to stage 3, and so on | Computed by the schedule author (e.g. Mod Curator) |

Every stage assignment is schedule data; the loader interprets stage
numbers, it does not know mod names.

## Settled by the staged implementation

The three items this document previously recorded as open design decisions
are settled and implemented:

- **Absence of a schedule file** → the positional staged default above.
  Every plain `mods.lst` is scheduled positionally; there is no legacy
  single-pass mode.
- **Per-stage failure semantics** → implemented as specified in
  [Failure semantics during the pass](#failure-semantics-during-the-pass):
  per-entry isolation, failed entries burning their update, and a framework
  (`dmf`) failure finalizing the pass at the failure update.
- **Hot reload** → implemented as the replacement replay (teardown frame,
  then the anchor update + one entry per update) instead of a single
  replacement frame.

## Open design decisions (recorded, not settled)

- **The authored multi-mod-per-stage carrier.** Loading multiple mods per
  stage from a differently-shaped mods file organized into stages by
  dependencies and/or load-order requirements. The carrier's SHAPE is
  TBD (the `modsScheduling.json` sidecar concept is superseded); the
  stage/update semantics above are the foundation.
