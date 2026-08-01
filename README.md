# Mod Relay

**Mod Relay** is the injected modding runtime + launcher for **Warhammer
40,000: Darktide**. It launches the game modded via DLL injection — no files in
the game directory, no bundle-database patching — and stays out of the way for
vanilla play: launch the game from Steam and it runs unmodified.

Mod Relay comprises the **mod loader** (the runtime-staged Lua that loads
DMF + user mods) plus the launcher that delivers it. The launcher is a
standalone CLI — run it directly, or drive it from an app (it's the runtime that
powers Mod Curator (Darktide Mod Manager), but it stands on its own). See
[`src/README.md`](src/README.md) for build + developer details.

> **Audience.** This README is the end-user entry point (what Mod Relay
> is and how to run it). Build internals, sub-component details, and testing
> live in [`src/README.md`](src/README.md); the production architecture lives
> in [`docs/architecture/`](docs/architecture/).

## Getting started

> **Run it.** Mod Relay is driven by its launcher CLI: point it at the
> game binary and a directory you assemble whose `mods/` subfolder holds DMF +
> your mods + a load-order file (see [Prepare mods](#2-prepare-mods)). The
> steps below cover a direct command-line setup; the same flags apply if
> you're invoking the launcher from an app.

### 1. Get the runtime

Mod Relay ships as a Windows x64 bundle on [GitHub Releases](https://github.com/ModifAmorphic/darktide-mod-relay/releases). Download the latest `*-windows-x64.zip` and unzip it anywhere you want the runtime to live. The bundle contains the complete Mod Relay runtime:

- `mod_relay.exe` — the launcher/injector.
- `relay_shell.dll` — the injected DLL.
- `mod_loader/` — the mod loader Lua (loaded by the shell at runtime).

When laid out, your runtime directory should look like:

```
<runtime-dir>/
  mod_relay.exe
  relay_shell.dll
  mod_loader/
    init.lua
    file.lua, class_registry.lua, lifecycle.lua, require_bridge.lua, mod_manager.lua, dmf_adapter.lua
```

### 2. Prepare mods

Mods live in the `mods/` subfolder of the directory you point `--mod-path` at
(`--mod-path` is the *parent* of `mods/`, not `mods/` itself). Lay it out as:

```
<mod-path>/
  mods/
    mods.lst           one mod name per line, in load order (list dmf first)
    dmf/               the Darktide Mod Framework (DMF) — the API mods are built against
    <your-mod>/        your mod(s)
```

- **DMF** (the Darktide Mod Framework) is the framework mods are built against;
  place it at `<mod-path>/mods/dmf/`.
- **`mods.lst`** lists the mods to load, one name per line, in the order they
  load (list `dmf` first). The loader loads exactly what's listed, in order — it
  injects nothing. You author this file by hand, or use a mod manager to
  generate it — e.g. [Modificus Curator](https://github.com/ModifAmorphic/darktide-modificus-curator)
  or the [Darktide Vortex Relay Extension](https://github.com/ModifAmorphic/darktide-vortex-relay-extension).

### 3. Locate the Darktide install

The launcher needs the path to `Darktide.exe` (you pass it to `--game-binary` in
[Run it](#4-run-it)). The quickest way to find it from Steam:

1. Open **Steam** → **Library**.
2. Right-click **Warhammer 40,000: DARKTIDE** → **Manage** →
   **Browse local files**.
3. Steam opens the game folder. Open `binaries\` — `Darktide.exe` is in there.

The path is typically:

```
C:\Program Files (x86)\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\binaries\Darktide.exe
```

If your Steam library lives on another drive, swap the drive letter
(`D:\Steam\steamapps\common\…`, etc.).

### 4. Run it

The launcher starts the game modded. The only required flag is the game binary;
the shell DLL and mod loader root default to next to the launcher exe (the shell
self-locates the mod loader from its own path), so you only point it at your
mods:

```bat
mod_relay.exe --game-binary "C:\Path\To\Darktide.exe" --mod-path "C:\Path\To\RelayMods"
```

A minimal `launch.bat` (next to the launcher) makes this easier:

```bat
mod_relay.exe ^
  --game-binary "C:\Games\Steam\steamapps\common\Warhammer 40,000 DARKTIDE\binaries\Darktide.exe" ^
  --mod-path "C:\Path\To\RelayMods"
rem   --log-lua
```

The `--log-lua` line (uncomment to enable) optionally copies Lua `print` output
into `relay.log` too — handy when collecting diagnostics in one place. See
[Additional options](#5-additional-options) and the
[logging reference](docs/reference/relay/logging.md) for what lands where.

> **Forwarding arguments to the game.** To pass command-line arguments to
> Darktide, put a bare `--` on the launcher's command line followed by the
> arguments to forward — e.g. `--game-binary "...\Darktide.exe" --mod-path "...\RelayMods" -- --lua-heap-mb-size 2048`.
> Everything after `--` is forwarded verbatim, in order, after the exe (no
> `--` is the normal, exe-only launch). There is no env-var form for these.
> See [`src/README.md`](src/README.md#launcher-cli) for the full details.

### 5. Additional options

Every launcher setting follows **flag > env var > default** (the env-var names
are listed in [`src/README.md`](src/README.md#launcher-cli)); `--game-binary` is
the only required flag. The shell DLL and mod loader root both default next to
the launcher exe.

| Flag | What it does | Default |
| --- | --- | --- |
| `--game-binary <path>` | Path to `Darktide.exe`. | — **(required)** |
| `--mod-path <path>` | Directory that *contains* your `mods/` folder (see [Prepare mods](#2-prepare-mods)). | unset (mods won't load) |
| `--log-file <path>` | Where the C-side shell/trampoline log is written. | `<launcher-dir>\relay.log` |
| `--log-level <level>` | Log level for `relay.log`: `error` / `warn` / `info` / `debug` / `trace`. | `info` |
| `--steam-app-id <id>` | Steam app id the launcher publishes. | `1361210` |
| `--log-lua` | Also copy Lua `print` output into `relay.log` (a tee — the console log stays authoritative). | off |
| `--log-append` | Append to `relay.log` instead of overwriting it. | off |
| `--skip-splash` | Skip the `StateSplash` intro splash state. | off |
| `--` | End-of-options separator: everything after it is forwarded to Darktide verbatim, in order. | unset |
| `--version` | Print the build-injected version and exit. | — |

By default Relay writes **two** logs: `relay.log` (the C-side shell/trampoline
log, next to the launcher) and Darktide's **console log** — the authoritative
home for the mod loader's, DMF's, and your mods' Lua output. On Windows that's
`%APPDATA%\Fatshark\Darktide\console_logs\console-*.log`. `--log-lua` adds a
copy of Lua `print` output into `relay.log`; `--log-level warn`/`error` filters
those copied lines out of `relay.log` (the console log is unaffected). See the
[logging reference](docs/reference/relay/logging.md) for the full contract.

### Reloading mods in-game (developer mode)

While developing a mod, you can reload all mods without restarting the game:

1. Enable **Developer Mode** in DMF's options (open the DMF options view — the
   default keybind is **F4** — and check the *Developer Mode* box). DMF persists
   this setting, so Relay picks it up on the next launch automatically.
2. With the game running and mods loaded, press **LEFT Ctrl + LEFT Shift + R**
   (all three keys at once). The mods tear down, `mods.lst` is re-read, and the
   new generation loads on the next frame.

Edit your mod files and/or `mods.lst`, then press the shortcut again to repeat.
Reload only fires when Developer Mode is on and the shortcut uses the **left**
Ctrl and **left** Shift keys specifically (right-side modifiers won't trigger it).
You can confirm each reload in Darktide's console log
(`%APPDATA%\Fatshark\Darktide\console_logs\console-*.log` on Windows; see
[Linux (Proton)](#linux-proton) for the Proton path): look for the
`INFO [mod_loader] hot reload generation N …` lines — `completed cleanly` on
success. If you launched with `--log-lua`, those same `[mod_loader]` lines are
**also** copied into `relay.log` (as `lua-print` lines); the console log always
has them regardless.

> **If a reload reports errors:** Relay reloads best-effort and is not
> transactional — once teardown starts, the old generation is gone. If the
> reload completes *with errors* (a mod's `run`/`init` failed, `mods.lst` was
> unreadable, or `on_reload`/`on_unload` raised), the log line recommends
> **restarting the game**. A clean reload just reports completion.

### Linux (Proton)

The cleanest way to launch modded on Linux is as a **Steam non-Steam game**, so
Steam's Proton layer handles the Windows runtime:

1. In Steam, **Add a non-Steam game** → browse to your `launch.bat`.
2. Open its **Properties**:
   - **Target:** the full path to `launch.bat`.
   - **Start In:** the runtime directory (where the launcher + DLL live).
   - **Launch options:**
     ```
     PROTON_LOG=1 STEAM_COMPAT_DATA_PATH=<path-to-compatdata-for-darktide> %command%
     ```
   - **Compatibility:** check **"Force the use of a specific Steam Play
     compatibility tool"** and pick a Proton version.
3. Launch it. The launcher creates the game suspended, injects the DLL, waits
   for the hook to arm, and resumes — Steam UX + zero game-directory footprint
   in one step.

> Use Windows-style paths for `--game-binary` and `--mod-path` even on
> Linux/Proton (the Proton `Z:\` drive maps to your Linux filesystem), e.g.
> `Z:\home\you\RelayMods`.

`PROTON_LOG=1` is handy while verifying setup. Note the **log split**: the
launcher's C-side shell/trampoline log lands in `relay.log` next to the launcher
(its pcall#1 status/failure diagnostic is the reliable bootstrap check);
Darktide's **own** engine Lua output — the mod loader's
`{LEVEL} [mod_loader] …` lines, DMF, and mods — lands in Darktide's **console
log**, not the Proton log. On Linux/Proton that is
`<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/console-*.log`.
The Proton log (`steam-$APPID.log`) captures Wine/Proton diagnostics only, not
Darktide Lua output.

> **Optional: also capture Lua `print` output in `relay.log`.** By default the
> Darktide console log is the only place Lua `print` / `__print` output (the
> mod loader, DMF, and mods) shows up — `relay.log` carries only the C-side
> shell/trampoline lines. Add `--log-lua` to also **copy** that Lua `print`
> output into `relay.log` as `lua-print` lines. It is a **tee, not a redirect**:
> Darktide's console log stays complete and authoritative. It is off by default,
> and `--log-level warn`/`error` filters the copied lines out of `relay.log`
> while the console log is unaffected. See the
> [logging reference](docs/reference/relay/logging.md) for the full logging
> reference.

## License

GNU General Public License v3 — see [`LICENSE`](LICENSE).

## Acknowledgements and third-party code

Darktide Mod Loader was used during early research to understand Darktide's
existing mod-loading environment. Mod Relay's loader is independently
implemented for Relay's injected runtime architecture.

The runtime statically links third-party components (the MinHook hooking
library and the Capstone disassembly engine + its Rust bindings). See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) for the component inventory
and their license terms.
