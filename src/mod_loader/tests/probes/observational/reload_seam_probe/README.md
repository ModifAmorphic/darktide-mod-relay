# Scenario: `observational/reload_seam_probe`

**Category:** observational · **Safety:** behavioral, isolated staging · **Not shipped, not executed by the offline harness (structurally validated by `test_probes.lua`)**

Demonstrates that Relay's reload **trigger-detection seam**
(`CLASS.ModManager._check_reload`) is hookable by a mod: while this probe is
loaded, the built-in **Left Ctrl + Left Shift + R** reload gesture is
**suppressed**. This is the community reload-control contract surface — Relay's
built-in gesture is detection-only with dynamic dispatch, so a community
replacement can suppress or redirect it.

This is a **behavioral** probe: it overrides one loader seam (`_check_reload`
→ `return false`) to demonstrate hookability. It is **read-only** with respect
to engine/game state, installs no hooks, and raises no errors. The probe is
**not executed** by the offline LuaJIT harness and is **not part of the shipped
runtime**; it runs only when staged into the real game.

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Authoritative order: exactly `reload_seam_probe` |
| `mods/reload_seam_probe/reload_seam_probe.mod` | Outer object that replaces `_check_reload` with a no-op (`return false`) for as long as it is loaded |

## Stage the scenario

This scenario is a **complete bundle**: its root directory *is* the
`<mod_path>` (the directory that *contains* a `mods/` subdir). Launch it
directly — no copying a leaf folder, no merging a list, no Lua editing.

Hot reload requires **developer mode** already persisted true (Relay gates
reload on that setting). Launch in developer mode:

```
mod_relay.exe --game-binary <exe> --mod-path <path-to-observational/reload_seam_probe>
```

…or copy this scenario root (as a unit) into your own staging directory and point
`--mod-path` at the copy. Reach the main menu, then press
**Left Ctrl + Left Shift + R**.

## Where to read evidence

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Relay's `[mod_loader] ... generation ...` lines do **not** advance while the
  probe is loaded — that is the evidence the gesture was suppressed.

> Relay's shell log is `relay.log`; this probe emits **no** `[PREFIX]` lines of
> its own, so there is nothing to grep there (the evidence is the **absence** of
> a reload).

## Expected behavior

While `reload_seam_probe` is loaded:

- Pressing **Left Ctrl + Left Shift + R** produces **no** generation change
  (no new `[mod_loader] generation N ...` lines in the console log). The
  built-in reload gesture is suppressed because `_check_reload` returns `false`.
- Everything else (gameplay, other mods, Relay's own failure-driven reload
  paths) is unaffected.

## Recovery / removal

The override lives only for the lifetime of this loaded probe — there is **no
in-process recovery step**. To restore the built-in reload gesture:

1. Exit the game (or, if you staged into a profile alongside other mods, remove
   `reload_seam_probe` from `mods/mods.lst` and hot reload — but the direct
   staging pattern above means the cleanest path is simply to relaunch without
   this scenario).
2. Relaunch without `--mod-path` pointed at this scenario (or from Steam for
   vanilla play).

The probe writes no scenario log, so there is nothing else to clean up.

## Safety

The override targets exactly one well-defined, hookable loader seam and is
reversed by removing the probe. It does **not** alter engine state, does **not**
touch Relay's failure-driven reload paths, and does **not** raise errors. Keep
staging isolated so the suppressed gesture does not surprise a profile you use
for normal play.
