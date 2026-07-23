# Live diagnostic probes

Manual, **non-shipped** diagnostic mods for observing Relay's loader behavior
in the real game. They are **not executed** by the offline LuaJIT test harness
and **not** part of the shipped runtime:

- The live probes run only when staged into the real game. The offline runner
  never executes them — but `../test_probes.lua` does structurally validate
  every probe (compile-check via `loadstring` + key-marker assertions) as part
  of `make mod-loader-test`, so a broken rename or a drift from the documented
  contract is caught at harness time.
- The runtime staging globs only top-level `mod_loader/*.lua` (non-recursive),
  so nothing under `probes/` is copied into `bin/mod_loader/`.
- Nothing under `probes/` is included in any release bundle.

These probes are **newly authored Relay assets**. They use only stable Lua 5.1
syntax and the engine/Crashify identifiers frozen in the consolidated spec.
They do not reproduce or imitate any third-party loader, framework, or mod.

## Categories

| Category | Path | Shape | Safety |
| --- | --- | --- | --- |
| **observational** | `observational/` | single probe folder | read-only / behavioral |
| **metadata** | `metadata/crashify/` | complete scenario bundle | read-only |
| **failure_injection** | `failure_injection/standalone/`, `failure_injection/framework_boundary/` | complete scenario bundle | **injects one intended error** |

- **observational** — passive recorders that observe loader callback sequences
  and seams. No injected failures.
- **metadata** — verifies Relay's Crashify integration by reading back what
  Relay published. Read-only with respect to engine state.
- **failure_injection** — probes that **intentionally** raise one lifecycle
  error to exercise Relay's outer-entry failure containment. Stage only into
  isolated mod roots; never overlay onto a profile you care about.

## Two staging shapes

A probe is staged into `<mod_path>/mods/` (where `<mod_path>` is the value of
Relay's `--mod-path` flag — the directory that *contains* a `mods/` subdir).

### Shape A — single observational folder

Use for `observational/` probes. Each probe is one folder:

1. Copy the probe's leaf folder (e.g. `observational/shutdown_probe/`) into
   `<mod_path>/mods/shutdown_probe/` (i.e. the folder whose name matches the
   `.mod`/`mods.lst` entry).
2. Add (or merge) a line `<probe>` into `<mod_path>/mods/mods.lst`.
3. Launch, exercise, exit.
4. Read the probe's log and/or grep the console log for its prefix.
5. Remove the line from `mods.lst` when done.

### Shape B — complete scenario bundle

Use for `metadata/` and `failure_injection/` scenarios. The bundle ships a
ready-to-copy `mods/` subtree (the authoritative `mods.lst` + every probe
folder + any mode files + replacement `.lst` files). The operator copies the
whole subtree into an **isolated** `<mod_path>/mods/` with no merging and no
Lua editing:

1. Create an empty staging root containing a `mods/` subdir.
2. Copy the bundle's `mods/` contents into `<mod_path>/mods/`.
3. Launch with `--mod-path <mod_path>`.
4. Follow the scenario README for evidence, expected counts, and the
   file-copy-only recovery procedures.

For scenario bundles, **never hand-edit `mods.lst`** when the scenario ships a
ready replacement `.lst` (e.g. `mods-without-alpha.lst`) — copy the supplied
file over the staged one.

## Console + log locations

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Each probe prints lines tagged with a distinctive `[PREFIX]`. Relay's own
  loader diagnostics print as `[mod_loader]`.
- **Scenario logs** (per-probe or shared, depending on the probe). Written via
  the rooted `Mods.lua.io.open` (rooted at `<mod_path>/mods/`), append+flushed
  per line so evidence survives console-log truncation at process exit.
- **Relay shell log** is `relay.log`; **neither** the probes' `[PREFIX]` lines
  **nor** Relay's `[mod_loader]` lines go there — they go to the Darktide
  console log and the scenario logs above.

## Safety labels

- **read-only** — the probe touches no engine state, installs no hooks, and
  raises no errors. Safe next to other mods (still: isolated staging is the
  clean pattern).
- **behavioral** — the probe overrides a loader seam to demonstrate hookability
  (e.g. suppresses the built-in reload gesture while loaded). Reversible by
  removing the entry from `mods.lst`.
- **injects one intended error** — the probe **intentionally** raises one
  lifecycle error. This is the behavior under test. Stage only into an
  isolated mod root and follow the scenario README's recovery procedure. The
  synthetic `framework_boundary/mods/dmf/` probe additionally owns the name
  `dmf` — **never** overlay that scenario onto a normal stock-DMF profile.

## Probes

### observational/

| Probe | Prefix | Log | Purpose |
| --- | --- | --- | --- |
| [`shutdown_probe/`](observational/shutdown_probe/shutdown_probe.mod) | `[SHUTDOWN_PROBE]` | `shutdown_probe/shutdown_probe.log` | Records the public lifecycle-callback sequence (`on_game_state_changed` / `on_reload` / `on_unload`, plus `init`) to verify state-exit / reload / unload ordering (e.g. that a final state-exit dispatches before `on_unload` on shutdown). |
| [`reload_seam_probe/`](observational/reload_seam_probe/reload_seam_probe.mod) | (console only) | — | Overrides `CLASS.ModManager._check_reload` to return `false`, demonstrating the reload trigger-detection seam is hookable (the built-in LEFT Ctrl + LEFT Shift + R gesture is suppressed while this is loaded). |

### metadata/

| Scenario | Prefix(es) | Shared log | Purpose | README |
| --- | --- | --- | --- | --- |
| `crashify/` | `[CRASHIFY_PROBE]`, `[CRASHIFY_ALPHA]`, `[CRASHIFY_BETA]` | `crashify_probe/crashify_probe.log` | Feature-detects `Crashify.print_property` / `remove_print_property` / `get_print_property`, reads back `ModRelay:Version` + per-mod keys, verifies stale-key rotation on reload. | [`crashify/README.md`](metadata/crashify/README.md) |

### failure_injection/

| Scenario | Prefix(es) | Shared log | Purpose | README |
| --- | --- | --- | --- | --- |
| `standalone/` | `[STANDALONE_FAILURE]`, `[HEALTHY_SIBLING]` | per-probe logs | Injects one standalone `update` error; verifies entry-local disablement, exactly-once unload, healthy-sibling continuation, single diagnostic + alert, recovery via `mode-healthy.txt` + hot reload. | [`standalone/README.md`](failure_injection/standalone/README.md) |
| `framework_boundary/` | `[FB_PRIOR]`, `[FB_DMF]`, `[FB_LATER]` | `framework_boundary.log` | **Synthetic** `dmf` entry fails init; verifies generation-wide stop, skipped later entry, reverse-order unload, culprit-free alert, recovery via `mode-healthy.txt` + hot reload. **Never overlay onto a stock-DMF profile.** | [`framework_boundary/README.md`](failure_injection/framework_boundary/README.md) |

## Operator workflow at a glance

1. Pick a scenario from the table above.
2. Create an empty `<mod_path>/mods/` (or, for observational single-folder
   probes, use an existing staging profile and add one line to its `mods.lst`).
3. Copy the prepared assets. No prompt copy/paste, no Lua editing.
4. Launch with `--mod-path <mod_path>`; reach the main menu.
5. Read the scenario log (and/or grep the Darktide console log for the prefix).
6. For failure-injection recovery or stale-key reload, copy the supplied
   `.lst` / mode file over the staged one, then hot reload
   (Left Ctrl + Left Shift + R) — developer mode must already be persisted true
   for in-process recovery; otherwise restart is the expected path.
