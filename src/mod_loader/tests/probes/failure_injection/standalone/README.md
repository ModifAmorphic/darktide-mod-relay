# Scenario: `failure_injection/standalone`

**Category:** failure injection · **Safety:** injects one intended lifecycle error; isolated staging only · **Not shipped, not executed by the offline harness (structurally validated by `test_probes.lua`)**

Verifies Relay's **standalone** outer-entry failure containment: one injected
`update` error must disable exactly that entry for the rest of the generation,
call its `on_unload` exactly once, emit one full console diagnostic + one
immediate engine alert, and repeat the alert on a controlled cadence — all
without affecting a healthy sibling entry later in the same list.

This is an explicit **failure-injection** scenario. The standalone probe
**intentionally raises one error** in `fail` mode (that is the behavior under
test). Stage it only into an isolated `<mod_path>`; do not overlay it onto a
profile you care about.

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Order: `standalone_failure_probe`, then `healthy_sibling_probe` |
| `mods/standalone_failure_probe/standalone_failure_probe.mod` | Outer entry that fails one update in `fail` mode |
| `mods/standalone_failure_probe/mode.txt` | Initially `fail` |
| `mods/standalone_failure_probe/mode-healthy.txt` | Drop-in recovery file (contents `healthy`) |
| `mods/healthy_sibling_probe/healthy_sibling_probe.mod` | Healthy outer entry that must keep running |

## Stage the scenario

Use an **isolated** `<mod_path>` (an empty directory containing a `mods/`
subdir). Do not overlay onto an existing profile.

1. Create an empty staging root, e.g. `relay-standalone-fail-probe/`.
2. Copy this bundle's `mods/` subtree into it so you have:
   - `<mod_path>/mods/mods.lst`
   - `<mod_path>/mods/standalone_failure_probe/standalone_failure_probe.mod`
   - `<mod_path>/mods/standalone_failure_probe/mode.txt` (= `fail`)
   - `<mod_path>/mods/standalone_failure_probe/mode-healthy.txt`
   - `<mod_path>/mods/healthy_sibling_probe/healthy_sibling_probe.mod`
3. Launch the game under Relay with `--mod-path <mod_path>`. Reach the main
   menu (a few frames is enough). Do not hot reload yet.

No Lua editing is required. The failure is selected by `mode.txt`.

## Where to read evidence

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Grep for `[STANDALONE_FAILURE]`, `[HEALTHY_SIBLING]`, and Relay's
  `[mod_loader]` lines.
- **Scenario logs:**
  - `<mod_path>/mods/standalone_failure_probe/standalone_failure_probe.log`
  - `<mod_path>/mods/healthy_sibling_probe/healthy_sibling_probe.log`
  - Both append+flush per line and survive console-log truncation.

> Relay's shell log is `relay.log`; the probe's lines are **not** there — they
> go to the Darktide console log and the scenario logs above.

## Expected sequence (initial `fail` mode)

Relay scans `mods.lst` into an entry list **without** executing any `.mod`;
`.mod` execution happens during the load pass, in listed order — one entry
per manager update (list position = load update offset from the pass
anchor). The
standalone entry is listed first, so its load + init + first update all land
on its own update; the healthy sibling loads on the next update, after the
standalone has already failed and been cleaned up.

On reaching the main menu, expect (roughly, in order):

**Load update 1 — the standalone's load update** (load, then the update
drive for everything loaded so far — only the standalone):

1. `[STANDALONE_FAILURE] scenario-loaded mode=fail ...` (its `.mod` executes)
2. `[STANDALONE_FAILURE] run mode=fail`
3. `[STANDALONE_FAILURE] init mode=fail`
4. `[STANDALONE_FAILURE] update mode=fail counter=updates:1 ...` — the first
   and only fail-mode update (an outer mod's first `update` lands on its own
   load update).
5. `[STANDALONE_FAILURE] update raising injected scratch error ...`
6. Relay's single full diagnostic:
   ```
   ERROR [mod_loader] mod 'standalone_failure_probe' update failed in generation 1;
   Relay disabled this entry:
   <full traceback>
   ```
7. One **engine alert** in the notification feed (Relay uses the engine's
   `event_add_notification_message` / `alert` path — **not** a DMF method):
   > Mod Relay disabled mod 'standalone_failure_probe' after a lifecycle error.
   > Restart the game or hot reload in developer mode. See the Darktide console
   > log for details.
8. `[STANDALONE_FAILURE] on_unload mode=fail counter=updates:1 unloads:1` —
   exactly one cleanup unload. Detachment and the failure latch are immediate
   (inside the failing update call), but the queued `on_unload` drains here at
   the end of this update's fan-out — the sibling has not loaded yet —
   not deferred to reload or shutdown.

**Load update 2 — the sibling's load update** (the pass continues; only the
standalone entry was disabled):

9. `[HEALTHY_SIBLING] scenario-loaded ...` → `[HEALTHY_SIBLING] run` →
   `[HEALTHY_SIBLING] init ...`
10. `[HEALTHY_SIBLING] update bounded-first-update ...` — its first update,
    on its own load update; the update loop is unaffected by the sibling
    failure latched one update earlier.

### Marker-count expectations (initial fail mode)

- **Exactly one** `[STANDALONE_FAILURE] update mode=fail` line (counter
  `updates:1`). If you see `updates:2` or more, Relay retried a disabled
  callback — a containment bug.
- **Exactly one** `[STANDALONE_FAILURE] on_unload` line in this stage
  (`unloads:1`). Detachment is immediate, but the queued `on_unload` drains at
  the end of the failing update's fan-out (the sibling has not loaded
  yet at that point); a second unload line before any reload/shutdown
  is a double-unload bug.
- **Exactly one** full `[mod_loader] ... update failed ...` diagnostic with a
  traceback. The traceback must not repeat every frame.
- **One** immediate alert, then reminders at the controlled cadence.
- The healthy sibling's `init` and a bounded first `update` must both appear —
  both on the sibling's own load update (one update after the standalone's,
  following the failure); the sibling must not spam per-frame
  `update` lines.

### Alert cadence and dev-mode text

- An **immediate** alert fires when the failure is latched.
- **~15 seconds** of manager time later, one consolidated reminder fires (the
  same alert text). It does not fire every frame.
- A later game-state **enter** can also make a reminder eligible, deduped
  against a prior attempt inside a ~2-second window.
- If **developer mode is off**, the alert text ends `Restart the game. See the
  Darktide console log for details.` (no hot-reload alternative). With
  developer mode on, it offers both restart and hot reload.
- The alert **does not** include raw error text and **does not** name any
  inner culprit (there is none — this is a standalone failure).

## Recovery (no code editing)

Hot reload requires **developer mode** already persisted true. If it is not
enabled, restart is the only recovery.

To recover in-process:

1. Copy the supplied healthy mode over the staged `mode.txt`:
   ```
   cp mode-healthy.txt mode.txt
   ```
2. Trigger a developer-mode hot reload: **Left Ctrl + Left Shift + R**.
3. Wait one generation. The new `standalone_failure_probe` object reads
   `mode=healthy` and emits a bounded first update (no error); the alert
   reminders stop once the replacement generation completes.

### Expected counts after recovery

- `_RELAY_STANDALONE_FAIL_UPDATES` (the fail-mode counter) **stays at 1** — the
  healthy mode does not increment it. Confirms no retry of the disabled
  callback.
- `_RELAY_STANDALONE_FAIL_UNLOADS` becomes **2** across the full
  fail → recover → shutdown cycle: unload #1 is the failed object's queued
  `on_unload`, drained at the end of the failing update's fan-out
  (step 8 above — detachment itself is immediate; the sibling loads one
  update later), and unload #2 is the recovered
  healthy replacement being unloaded at process shutdown. The failed object is
  **not** unloaded a second time during hot-reload teardown — its cleanup was
  already claimed and drained in the failing generation, so a second unload of
  that same object during reload is exactly the bug to look for. Both
  legitimate unloads are different objects, each unloaded exactly once.
- After recovery, no further `[mod_loader] ... update failed ...` diagnostics
  and no further alerts/reminders should appear for this entry.

## Removing the scenario

Delete the staged `<mod_path>/mods/` entries (or point `--mod-path` elsewhere
and relaunch). The scenario writes only the two `.log` files under its own
probe folders; remove those if you want a clean slate.
