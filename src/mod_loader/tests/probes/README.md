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

| Category | Path | Safety |
| --- | --- | --- |
| **observational** | `observational/<scenario>/` | read-only / behavioral |
| **metadata** | `metadata/crashify/` | read-only |
| **failure_injection** | `failure_injection/standalone/`, `failure_injection/framework_boundary/` | **injects one intended error** |

- **observational** — passive recorders that observe loader callback sequences
  and seams. No injected failures.
- **metadata** — verifies Relay's Crashify integration by reading back what
  Relay published. Read-only with respect to engine state.
- **failure_injection** — probes that **intentionally** raise one lifecycle
  error to exercise Relay's outer-entry failure containment. Stage only into
  isolated mod roots; never overlay onto a profile you care about.

## One staging shape — the complete scenario bundle

Every probe under `probes/` ships as the **same self-contained scenario
bundle**. A scenario's root directory *is* the `<mod_path>` (the directory that
*contains* a `mods/` subdir). The layout is uniform:

```
<scenario>/
  README.md            scenario launch, evidence, cleanup, safety
  mods/
    mods.lst           authoritative order (one entry per probe folder)
    <probe>/
      <probe>.mod
```

To stage a scenario:

1. Either point `--mod-path` straight at the scenario root:
   ```
   mod_relay.exe --game-binary <exe> --mod-path <path-to-probes>/<category>/<scenario>
   ```
   …or copy the prepared **scenario root** (as a unit) into your own staging
   directory and point `--mod-path` at the copy.
2. Launch, exercise the scenario per its README, then exit.
3. Read the probe's scenario log and/or grep the Darktide console log for its
   `[PREFIX]`.

There is **no** per-probe folder copying, **no** manual `mods.lst` line
editing, and **no** list merging at staging time — each scenario ships its own
authoritative `mods.lst` so the order it was validated against is the order
that loads. For scenarios that ship a ready replacement `.lst` for a recovery
step (e.g. `mods-without-alpha.lst`), copy that supplied file over the staged
`mods.lst` rather than hand-editing it.

## Console + log locations

- **Darktide console log** (`console-*.log` under
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows; under Proton,
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`).
  Each probe prints lines tagged with a distinctive `[PREFIX]`. Relay's own
  loader diagnostics print as `[mod_loader]`.
- **Scenario logs** (per-probe or shared, depending on the probe). Written via
  the rooted `Mods.lua.io.open` (rooted at `<mod_path>/mods/`), append+flushed
  per line so evidence survives console-log truncation at process exit.
- **Relay shell log** is `relay.log`. By default (`--lua-logs` off) **neither**
  the probes' `[PREFIX]` lines **nor** Relay's `[mod_loader]` lines go there —
  they go to the Darktide console log and the scenario logs above. When the user
  opts in with `--lua-logs` (or `RELAY_LUA_LOGS=1`), Relay tees Lua `print` /
  `__print` output into `relay.log` as structured `INFO  lua-print:` lines too —
  so probe/loader lines that traverse those wrapped surfaces ALSO appear in
  `relay.log`. The Darktide console log remains authoritative and unchanged
  either way; the tee only adds `relay.log` copies. See
  [`observational/lua_logs_probe/README.md`](observational/lua_logs_probe/README.md).

## Safety labels

- **read-only** — the probe touches no engine state, installs no hooks, and
  raises no errors. Safe next to other mods (still: isolated staging is the
  clean pattern).
- **behavioral** — the probe overrides a loader seam to demonstrate hookability
  (e.g. suppresses the built-in reload gesture while loaded). Reversible by
  removing the scenario from `--mod-path`.
- **injects one intended error** — the probe **intentionally** raises one
  lifecycle error. This is the behavior under test. Stage only into an
  isolated mod root and follow the scenario README's recovery procedure. The
  synthetic `framework_boundary/mods/dmf/` probe additionally owns the name
  `dmf` — **never** overlay that scenario onto a normal stock-DMF profile.

## Probes

### observational/

| Scenario | Prefix | Log | Purpose | README |
| --- | --- | --- | --- | --- |
| `shutdown_probe/` | `[SHUTDOWN_PROBE]` | `shutdown_probe/shutdown_probe.log` | Records the public lifecycle-callback sequence (`on_game_state_changed` / `on_reload` / `on_unload`, plus `init`) to verify state-exit / reload / unload ordering (e.g. that a final state-exit dispatches before `on_unload` on shutdown). | [`shutdown_probe/README.md`](observational/shutdown_probe/README.md) |
| `reload_seam_probe/` | (console only) | — | Overrides `CLASS.ModManager._check_reload` to return `false`, demonstrating the reload trigger-detection seam is hookable (the built-in LEFT Ctrl + LEFT Shift + R gesture is suppressed while this is loaded). | [`reload_seam_probe/README.md`](observational/reload_seam_probe/README.md) |
| `lua_logs_probe/` | `[LUA_LOGS_PROBE]` | `lua_logs_probe/lua_logs_probe.log` | Observes Relay's optional Lua print tee (`--lua-logs` / `RELAY_LUA_LOGS=1`): emits unique markers through `print` and `__print` across one case per tee policy (simple, multi-arg, multiline+CRLF, `%` text, control bytes, over-budget truncation). Read-only. | [`lua_logs_probe/README.md`](observational/lua_logs_probe/README.md) |

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
2. Point `--mod-path` at the scenario root (or copy the scenario root as a unit
   into your own staging directory and point `--mod-path` at the copy). No
   prompt copy/paste, no Lua editing, no `mods.lst` line editing.
3. Launch with `--mod-path <mod_path>`; reach the main menu.
4. Read the scenario log (and/or grep the Darktide console log for the prefix).
5. For failure-injection recovery or stale-key reload, copy the supplied
   `.lst` / mode file over the staged one, then hot reload
   (Left Ctrl + Left Shift + R) — developer mode must already be persisted true
   for in-process recovery; otherwise restart is the expected path.
