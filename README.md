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
> your mods + a load-order file (see [Where mods go](#4-where-mods-go)). The
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

### 2. Run it

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
```

> On Linux/Proton, use Windows-style `Z:\` paths (the Proton `Z:` drive maps to
> your Linux filesystem).

> **Forwarding arguments to the game.** To pass command-line arguments to
> Darktide, put a bare `--` on the launcher's command line followed by the
> arguments to forward — e.g. `--game-binary "...\Darktide.exe" --mod-path "...\RelayMods" -- --lua-heap-mb-size 2048`.
> Everything after `--` is forwarded verbatim, in order, after the exe (no
> `--` is the normal, exe-only launch). There is no env-var form for these.
> See [`src/README.md`](src/README.md#launcher-cli) for the full details.

### 3. Configure Steam (Linux/Proton)

The cleanest way to launch modded is as a **Steam non-Steam game**, so Steam's
Proton layer handles the Windows runtime:

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

`PROTON_LOG=1` is handy while verifying setup. Note the **log split**: the
launcher's C-side shell/trampoline log lands in `relay.log` next to the launcher
(its one-line `OK`/`FAIL` is the reliable bootstrap check); Darktide's **own**
engine Lua output — the mod loader's `[mod_loader] …` lines, DMF, and mods —
lands in Darktide's **console log**, not the Proton log. On Linux/Proton that is
`<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/console-*.log`
(the Windows equivalent is `%APPDATA%\Fatshark\Darktide\console_logs\console-*.log`).
The Proton log (`steam-$APPID.log`) captures Wine/Proton diagnostics only, not
Darktide Lua output.

### 4. Where mods go

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
  injects nothing. You author this file by hand, or have your app generate it.

### 5. Reloading mods in-game (developer mode)

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
You can confirm each reload in Darktide's console log (see
[Configure Steam](#3-configure-steam-linuxproton) for the location): look for
the `[mod_loader] hot reload generation N …` lines — `completed cleanly` on
success.

> **If a reload reports errors:** Relay reloads best-effort and is not
> transactional — once teardown starts, the old generation is gone. If the
> reload completes *with errors* (a mod's `run`/`init` failed, `mods.lst` was
> unreadable, or `on_reload`/`on_unload` raised), the log line recommends
> **restarting the game**. A clean reload just reports completion.

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
