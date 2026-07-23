# Scenario: `failure_injection/framework_boundary`

**Category:** failure injection · **Safety:** injects one intended framework-boundary error; isolated staging only · **Not shipped, not executed by the offline harness (structurally validated by `test_probes.lua`)**

> ## ⚠ WARNING — read before staging
>
> This scenario intentionally owns the folder **and** mods.lst name **`dmf`**.
> The descriptor at `mods/dmf/dmf.mod` is a **SYNTHETIC Relay-owned probe** — it
> is **NOT stock DMF** and does not reproduce any DMF behavior.
>
> **Never overlay this scenario onto a normal stock-DMF profile.** If you point
> `--mod-path` at a profile whose `mods/` already contains a real `dmf/`, this
> probe would shadow or collide with it. Stage this scenario **only into an
> empty, isolated mod root** (an empty directory that *contains* a `mods/`
> subdir) created specifically for this test. The scenario ships its own
> authoritative `mods/` subtree precisely so you do not have to merge anything.

Verifies Relay's **framework-boundary** failure containment: when an outer
entry whose name is exactly `dmf` has a qualifying lifecycle failure, Relay
must stop all outer driving for the current generation, skip later order
entries, best-effort reverse-unload active outer objects, retire stale
generation globals, leave `_state == "done"`, and emit one consolidated alert
that does **not** name an inner culprit. A user-requested hot reload (with
developer mode on) must recover into a clean replacement generation.

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Authoritative order: `framework_prior_probe`, `dmf`, `framework_later_probe` |
| `mods/framework_prior_probe/framework_prior_probe.mod` | Outer entry loaded BEFORE `dmf`; observes init + reverse-order unload |
| `mods/dmf/dmf.mod` | **Synthetic** outer entry owning the name `dmf`; fails init in `fail` mode |
| `mods/dmf/mode.txt` | Initially `fail` |
| `mods/dmf/mode-healthy.txt` | Drop-in recovery file (contents `healthy`) |
| `mods/framework_later_probe/framework_later_probe.mod` | Outer entry loaded AFTER `dmf`; must be skipped in a failing generation |

## Stage the scenario

Use a fresh, **empty, isolated** `<mod_path>` (e.g. `relay-framework-fail-probe/`).
Do not reuse a profile that contains real DMF or other mods.

1. Create the empty staging root and a `mods/` subdir inside it.
2. Copy this bundle's `mods/` subtree into it so you have:
   - `<mod_path>/mods/mods.lst`
   - `<mod_path>/mods/framework_prior_probe/framework_prior_probe.mod`
   - `<mod_path>/mods/dmf/dmf.mod`
   - `<mod_path>/mods/dmf/mode.txt` (= `fail`)
   - `<mod_path>/mods/dmf/mode-healthy.txt`
   - `<mod_path>/mods/framework_later_probe/framework_later_probe.mod`
3. Launch the game under Relay with `--mod-path <mod_path>`. Reach the main
   menu (a few frames is enough). Do not hot reload yet.

No Lua editing is required. The failure is selected by `dmf/mode.txt`.

## Where to read evidence

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Grep for `[FB_PRIOR]`, `[FB_DMF]`, `[FB_LATER]`, and Relay's `[mod_loader]`
  lines.
- **Shared scenario log:** `<mod_path>/mods/framework_boundary.log`
  (sibling of the three probe folders; append+flush per line; all three
  probes write here so the full event ordering is in one place).

> Relay's shell log is `relay.log`; the probe's lines are **not** there — they
> go to the Darktide console log and the shared scenario log above.

## Expected sequence (initial `fail` mode)

Relay scans `mods.lst` into an entry list **without** executing any `.mod`;
`.mod` execution happens during the load pass, in listed order. The load pass
stops the moment the synthetic `dmf` entry fails init, so the later entry's
`.mod` is never executed at all in the failing generation.

On reaching the main menu, the shared `framework_boundary.log` must show
(roughly, in order):

1. Load-pass entry #1 (`framework_prior_probe`): its `.mod` executes →
   `[FB_PRIOR] scenario-loaded ...`, then `[FB_PRIOR] run ...`, then
   `[FB_PRIOR] init ...` (it initializes cleanly before `dmf` is reached).
2. Load-pass entry #2 (`dmf`): its `.mod` executes →
   `[FB_DMF] scenario-loaded mode=fail ... (SYNTHETIC probe; not stock DMF)`,
   then `[FB_DMF] run ...`, then `[FB_DMF] init ...`.
3. `[FB_DMF] init raising injected framework-boundary scratch error ...`.
4. Relay's single full diagnostic (the framework-boundary marker):
   ```
   [mod_loader] framework-boundary lifecycle failure at entry 'dmf' in
   generation 1 during init; Relay stopped the current generation:
   <full traceback>
   ```
5. One **consolidated engine alert** in the notification feed (Relay uses the
   engine's `event_add_notification_message` / `alert` path — **not** a DMF
   method):
   > Mod Relay stopped the current mod generation after a framework-boundary
   > error. Restart the game or hot reload in developer mode. See the Darktide
   > console log for details.
6. Cleanup drain, **reverse load order**: `[FB_DMF] on_unload ...` THEN
   `[FB_PRIOR] on_unload ...` (drained inside the load pass right after the
   failure, before the later entry is reached).
7. Load-pass entry #3 (`framework_later_probe`): the stop flag is set, so the
   entry is marked `skipped` and its `.mod` is **never executed**.

### What must NOT appear in the initial failing generation

- **No** `[FB_LATER]` line **at all** — not even `[FB_LATER] scenario-loaded`.
   Complete absence is the evidence that the entry was skipped: its `.mod`
   never runs, so it emits nothing and its process-global counters are never
   created (absent from `_G`, not zero).
- **No** `[FB_PRIOR] update` line in the failing generation. The generation is
  stopped, so no outer `update` callbacks run.
- **No** alert or diagnostic that names an inner culprit. The framework alert
  must say "framework-boundary error" and must **not** blame DMF, a user mod,
  or any inner callback.

### Marker-count expectations (initial fail mode)

- `[FB_LATER]` produces **no output** in the failing generation (no
  `scenario-loaded`, no counters). Its `_G._RELAY_FB_LATER_*` keys are never
  created. After healthy recovery its `scenario-loaded`/`run`/`init`/`update`
  lines appear normally (see Recovery below).
- `[FB_DMF]` run=1, init=1, update=0, unload=1.
- `[FB_PRIOR]` run=1, init=1, update=0, unload=1.
- Exactly one `[mod_loader] framework-boundary lifecycle failure ...` line
  with a traceback. The traceback must not repeat every frame.
- One immediate alert; reminders repeat on the controlled cadence (every ~15
  seconds of manager time, plus state-enter eligibility) until a completed hot
  reload or process exit.

### Alert cadence and dev-mode text

- The consolidated framework alert takes precedence over any standalone
  reminder text. If multiple failures were latched, only the framework
  message repeats.
- If **developer mode is off**, the alert text ends `Restart the game. See the
  Darktide console log for details.` (no hot-reload alternative). With
  developer mode on, it offers both restart and hot reload.
- The alert **does not** include raw error text.

## Recovery

Hot reload requires **developer mode** already persisted **true**. If it is
not enabled when the failure occurs, **restart is the expected recovery** —
Relay will not promise an in-process reload that the policy forbids.

To recover in-process (developer mode already on):

1. Copy the supplied healthy mode over the staged `dmf/mode.txt`:
   ```
   cp mode-healthy.txt mode.txt
   ```
2. Trigger a developer-mode hot reload: **Left Ctrl + Left Shift + R**.
3. Wait one generation. All three entries should now load and drive normally.

### Expected after recovery

- A new `[FB_DMF] scenario-loaded mode=healthy ...` line (run counter bumped).
- `[FB_PRIOR]`, `[FB_DMF]`, and `[FB_LATER]` each emit run/init, plus a bounded
  first update. No further framework failure is reported.
- Old alert reminders stop once the replacement generation completes.

## Removing the scenario

Delete the staged `<mod_path>/mods/` entries (or point `--mod-path` elsewhere
and relaunch). The scenario writes only the shared `framework_boundary.log`
at the mods root; remove that file if you want a clean slate. **Do not** leave
the synthetic `dmf/` folder in any profile you use for normal play.
