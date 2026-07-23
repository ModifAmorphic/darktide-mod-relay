# Scenario: `observational/shutdown_probe`

**Category:** observational · **Safety:** read-only, isolated staging · **Not shipped, not executed by the offline harness (structurally validated by `test_probes.lua`)**

Records Relay's public lifecycle-callback sequence (`init` / `on_game_state_changed`
/ `on_reload` / `on_unload`) to verify state-exit / reload / unload ordering in
the real game — in particular that a final state-exit dispatches before
`on_unload` on shutdown (the community-contract gap Relay closes).

This is an **observational** probe: it is **read-only** (installs no hooks,
raises no errors, touches no engine state). The probe is **not executed** by the
offline LuaJIT harness and is **not part of the shipped runtime**; it runs only
when staged into the real game.

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Authoritative order: exactly `shutdown_probe` |
| `mods/shutdown_probe/shutdown_probe.mod` | Outer object that records each public lifecycle callback with a monotonic `#n` |

## Stage the scenario

This scenario is a **complete bundle**: its root directory *is* the
`<mod_path>` (the directory that *contains* a `mods/` subdir). Launch it
directly — no copying a leaf folder, no merging a list, no Lua editing.

1. Either point `--mod-path` straight at this scenario root:
   ```
   mod_relay.exe --game-binary <exe> --mod-path <path-to-observational/shutdown_probe>
   ```
   …or copy this scenario root (as a unit) into your own staging directory and
   point `--mod-path` at the copy.
2. Reach the main menu, exercise the scenario (enter/exit a state, optionally
   hot reload in developer mode), then exit the game.

## Where to read evidence

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Grep for `[SHUTDOWN_PROBE]`.
- **Scenario log:** `<mod_path>/mods/shutdown_probe/shutdown_probe.log`
  (append+flush per line; survives console-log truncation at process exit).

> Relay's shell log is `relay.log`; the probe's `[SHUTDOWN_PROBE]` lines are
> **not** there unless you also enable `--lua-logs` (see
  [`observational/lua_logs_probe/README.md`](../lua_logs_probe/README.md)) — they
  go to the Darktide console log and the scenario log above.

## Expected sequence (initial load + clean exit)

Expect (roughly, in order):

1. `[SHUTDOWN_PROBE] SESSION_START ...` (its `.mod` executes, then `run` is called)
2. `[SHUTDOWN_PROBE] init` — outer `init` for this generation
3. `[SHUTDOWN_PROBE] on_game_state_changed status=enter ...` for each state
   entered
4. (optional) `[SHUTDOWN_PROBE] on_game_state_changed status=exit ...` then
   `[SHUTDOWN_PROBE] on_reload` per developer-mode hot reload
   (Left Ctrl + Left Shift + R)
5. On clean process exit: a final
   `[SHUTDOWN_PROBE] on_game_state_changed status=exit ...` for the active
   state, followed by `[SHUTDOWN_PROBE] on_unload`.

### Marker-count expectations

- The monotonic `#n` on each line is strictly increasing — duplicates or gaps
  indicate a dropped or doubled callback.
- On a clean shutdown, the active state's **exit** line precedes the single
  `on_unload` line. A missing exit (or an `on_unload` before any exit) is the
  contract gap Relay is meant to close.

## Removing the scenario

Point `--mod-path` elsewhere (or relaunch from Steam for vanilla play). The
scenario writes only the single `shutdown_probe.log` under its own probe folder;
delete that file if you want a clean slate.
