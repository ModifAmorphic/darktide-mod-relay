# Live diagnostic probes

Manual diagnostic mods for observing the loader's behavior in the real game.
These are **not** part of the offline LuaJIT test harness and are **not** staged
into the shipped runtime:

- The offline runner uses an explicit test list (`../runner.lua`), not a glob,
  so nothing here runs under `make mod-loader-test`.
- The runtime staging globs only top-level `mod_loader/*.lua` (non-recursive),
  so nothing here is copied into `bin/mod_loader/`.

## Using a probe

1. Copy the probe's `<probe>/` folder (containing `<probe>.mod`) into
   `<mod_path>/mods/` in your staging mod directory — i.e. the standard mod
   layout `<mod_path>/mods/<probe>/<probe>.mod`.
2. Add a line `<probe>` to `<mod_path>/mods/mods.lst`.
3. Launch the game under Relay, exercise the scenario, then exit.
4. Read the probe's log (location per probe below) and/or grep the Darktide
   console log for the probe's prefix.
5. Remove the line from `mods.lst` when done.

## Probes

### `shutdown_probe.mod`

Records the loader's public lifecycle-callback sequence — `on_game_state_changed`
(status, state name, state object), `on_reload`, `on_unload`, plus `init` and a
per-session `SESSION_START` marker — to verify state-exit / reload / unload
ordering (e.g. that a final state-exit dispatches before `on_unload` on
shutdown). Append-mode; a monotonic `#n` preserves exact ordering.

- **Log:** `shutdown_probe/shutdown_probe.log` in the mods directory (written
  via the rooted `Mods.lua.io.open`), flushed each line so evidence survives
  console-log truncation at process exit.
- **Console prefix:** `[SHUTDOWN_PROBE]`.

### `reload_seam_probe.mod`

Overrides `CLASS.ModManager._check_reload` to return `false`, demonstrating the
reload trigger-detection seam is hookable by a mod (the built-in LEFT Ctrl +
LEFT Shift + R gesture is suppressed while this is loaded; `request_reload`
remains the supported trigger-neutral operation).

- No file output; observe by confirming the built-in gesture no longer fires in
  developer mode while the probe is loaded.
