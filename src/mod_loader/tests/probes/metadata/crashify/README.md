# Scenario: `metadata/crashify`

**Category:** metadata / Crashify · **Safety:** read-only, isolated staging · **Not shipped, not executed by the offline harness (structurally validated by `test_probes.lua`)**

Verifies Relay's per-mod Crashify metadata + the process-lifetime
`ModRelay:Version` property against the live engine. The probe is read-only
with respect to Crashify and the engine: it feature-detects the three relevant
`Crashify` methods and reads back the keys Relay published, but it never
publishes or removes anything itself. Every Crashify lookup, call, and file
write is protected so the probe cannot trip Relay's outer-failure containment.

This scenario does **not** require stock DMF. It is self-contained and ships
its own `mods/` subtree so an operator can stage it without writing or editing
any Lua.

## Contents

| Path | Purpose |
| --- | --- |
| `mods/mods.lst` | Initial authoritative order: `crashify_alpha`, `crashify_beta`, `crashify_probe` |
| `mods/mods-without-alpha.lst` | Drop-in replacement order (alpha removed) for the stale-key reload |
| `mods/crashify_alpha/crashify_alpha.mod` | Nil-return descriptor that logs execution; earns `Mod:crashify_alpha` |
| `mods/crashify_beta/crashify_beta.mod` | Nil-return descriptor that logs execution; earns `Mod:crashify_beta` |
| `mods/crashify_probe/crashify_probe.mod` | Outer object that observes and records once per generation |

## Stage the scenario

Use an **isolated** `<mod_path>` — an empty directory that *contains* a `mods/`
subdir. Do not overlay this onto a profile that already has a real `mods.lst`,
because the scenario ships its own.

1. Create an empty staging root, e.g. `relay-crashify-probe/`.
2. Copy this bundle's `mods/` subtree into it so you have:
   - `<mod_path>/mods/mods.lst`
   - `<mod_path>/mods/crashify_alpha/crashify_alpha.mod`
   - `<mod_path>/mods/crashify_beta/crashify_beta.mod`
   - `<mod_path>/mods/crashify_probe/crashify_probe.mod`
3. Launch the game under Relay with `--mod-path <mod_path>` (the parent of
   `mods/`). Exercise the main menu briefly (a few seconds is enough for the
   probe's update delay to elapse), then either exit or hot reload.

No Lua editing, no prompt copy/paste — copying the prepared `mods/` folder is
the whole staging step.

## Where to read evidence

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Grep for `[CRASHIFY_PROBE]`, `[CRASHIFY_ALPHA]`, `[CRASHIFY_BETA]`.
- **Scenario log:** `<mod_path>/mods/crashify_probe/crashify_probe.log`
  (append+flush per line; survives console-log truncation at process exit).
  The log accumulates across sessions and reloads; the `generation-label=#N`
  field disambiguates each load/reload pass.

> Relay's own shell log is `relay.log`; the probe's lines are **not** there —
> they go to the Darktide console log and the scenario log above.

## Expected initial output

Relay scans `mods.lst` into an entry list **without** executing any `.mod`;
`.mod` execution happens during the load pass, in listed order. The probe is
listed last, so alpha and beta load (and publish their `Mod:` keys) before the
probe's `.mod` executes. On the first generation expect (roughly, one line per
event, in this order):

```
[CRASHIFY_ALPHA] run executed (nil-return descriptor)
[CRASHIFY_BETA] run executed (nil-return descriptor)
[CRASHIFY_PROBE] scenario-loaded generation-label=#1 ...
[CRASHIFY_PROBE] run generation-label=#1
[CRASHIFY_PROBE] init generation-label=#1
[CRASHIFY_PROBE] observe generation-label=#1 | print_property=function | remove_print_property=function | get_print_property=function | ModRelay:Version=<version> | Mod:crashify_alpha=true | Mod:crashify_beta=true | Mod:crashify_probe=true
```

The `[mod_loader]` lines also report each entry's load result (`mod
'crashify_alpha' DMF-driven (run returned no object)` etc.).

### `--version` comparison

`ModRelay:Version` carries the exact manifest-derived product version Relay
was built with. Compare it to the launcher:

```
mod_relay.exe --version
```

That prints `mod_relay <version>` (e.g. `mod_relay 0.2.0`). After stripping the
`mod_relay ` prefix, the remainder must equal the `ModRelay:Version` value read
back by the probe. For a prerelease build the suffix is included on both sides
(e.g. `0.3.0-beta.2`).

### Marker-count expectations (initial generation)

- Exactly **one** `[CRASHIFY_PROBE] observe ...` line per generation (the probe
  guards against per-frame repetition; subsequent updates are no-ops).
- Exactly **one** `[CRASHIFY_ALPHA] run executed` and **one** `[CRASHIFY_BETA]
  run executed` per generation.
- Each of the four read-back keys should be **present** (not `<absent>`) when
  `get_print_property=function`. If `get_print_property` is unavailable on the
  current engine build, the keys will read `<no-get_print_property>` — that is
  an engine-contract observation, not a Relay defect. The publication-side
  methods (`print_property`, `remove_print_property`) being `function`
  confirms Relay's integration surface is intact regardless.

## Developer-mode prerequisite (hot reload)

Hot reload requires **developer mode** already persisted true (Relay gates
reload on `Managers.mod._settings.developer_mode`). If it is not enabled,
restart is the only recovery; the probe scenarios do not change this setting.
The reload gesture is **Left Ctrl + Left Shift + R**.

## Stale-key reload procedure

This verifies that a removed entry's `Mod:<name>` key is cleaned up on reload
while `ModRelay:Version` and retained keys survive.

1. With the initial generation loaded and observed, copy the replacement order
   over the staged `mods.lst` (no hand-editing):
   ```
   cp mods-without-alpha.lst mods.lst
   ```
2. Trigger a developer-mode hot reload (Left Ctrl + Left Shift + R).
3. Wait one generation. The probe emits a new observe line labeled
   `generation-label=#2`.

### Expected absence / presence after the reload

- `Mod:crashify_alpha` → `<absent>` (entry is no longer listed; its key was
  removed during teardown before the replacement generation published).
- `Mod:crashify_beta` → `true` (retained; republished for the new generation).
- `Mod:crashify_probe` → `true` (retained; republished).
- `ModRelay:Version` → unchanged (process-lifetime; **never** removed across
  reload or shutdown).

If `remove_print_property` is unavailable on the engine build, the alpha key
may remain stale in the engine — that is an engine-contract limitation, not a
Relay bug, and the probe read-back honestly reports whatever it finds.

## Removing the scenario

Delete the staged `<mod_path>/mods/` entries (or point `--mod-path` elsewhere
and relaunch). The scenario writes only the single `crashify_probe.log` under
its own probe folder; remove that file if you want a clean slate.
