# Darktide Modding Framework Analysis

> **Status:** Complete reference. Describes the existing community modding
> toolchain — not Mod Relay's own work.
>
> Documents the three components of the current Darktide modding
> ecosystem: **dtkit-patch** (bundle database patcher),
> **Darktide-Mod-Loader** (Lua runtime bridge), and
> **Darktide-Mod-Framework / DMF** (modding API). This is background
> context for understanding what Mod Relay replaces and what it
> preserves.
>
> Loader facts are pinned to Darktide-Mod-Loader release
> [`26.06.24`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader/releases/tag/26.06.24)
> (`4bd075a`). DMF consumer facts are pinned to
> [`b9cc65f`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework/tree/b9cc65f773cd8aaa974bf5b9312a79f5c5785f90).
> Verification details are recorded in
> [`analysis-verification.md`](analysis-verification.md).

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Component: dtkit-patch](#component-dtkit-patch)
3. [Component: Darktide-Mod-Loader](#component-darktide-mod-loader)
4. [Component: Darktide-Mod-Framework (DMF)](#component-darktide-mod-framework-dmf)
5. [Mod Loading Flow (End-to-End)](#mod-loading-flow-end-to-end)
6. [Current User Experience Pain Points](#current-user-experience-pain-points)
7. [Technology Summary](#technology-summary)

---

## Architecture Overview

The Darktide modding ecosystem is a **three-layer system** that hooks into Warhammer 40,000: Darktide's native mod support (Fatshark's built-in `ModManager`):

```
┌─────────────────────────────────────────────────────┐
│                  Darktide Game Engine                │
│         (Fatshark's built-in ModManager)             │
│                                                      │
│  Loads bundles listed in bundle_database.data        │
│  Executes .mod entry points for each "mod"           │
└──────────────────────┬──────────────────────────────┘
                       │ patch_999 bundle entry
                       ▼
┌─────────────────────────────────────────────────────┐
│           Darktide-Mod-Loader (DML)                  │
│                                                      │
│  binaries/mod_loader  → modified game main.lua       │
│  mods/base/           → Lua runtime (mod_manager,   │
│                          hook, require, class)        │
│  mods/mod_load_order.txt                             │
│  toggle_darktide_mods.bat → dtkit-patch wrapper      │
│  tools/dtkit-patch.exe                               │
└──────────────────────┬──────────────────────────────┘
                       │ loads as first mod
                       ▼
┌─────────────────────────────────────────────────────┐
│        Darktide-Mod-Framework (DMF)                  │
│                                                      │
│  dmf/dmf.mod              → entry point              │
│  dmf/scripts/mods/dmf/    → framework modules:       │
│    dmf_loader.lua          (bootstrap)               │
│    dmf_mod_data.lua        (DMFMod class)            │
│    dmf_mod_manager.lua     (mod registry)            │
│    dmf_package_manager.lua (resource loading)        │
│    modules/core/           (hooks, events, options,  │
│                              keybinds, chat, etc.)   │
│    modules/ui/             (in-game options GUI)     │
│    modules/debug/          (dev console)             │
│    modules/gui/            (custom HUD/textures)     │
└─────────────────────────────────────────────────────┘
```

---

## Component: dtkit-patch

### Purpose

A Rust CLI tool that **patches Darktide's `bundle_database.data`** to register a custom bundle entry (`9ba626afa44a3aa3.patch_999`). Without this patch, the game engine has no knowledge of the mod loader and does not load its mod code.

### How It Works

1. **Locates the game** via Steam (app ID `1361210`) or Xbox Game Pass (Windows registry via `winreg` crate)
2. **Searches** `bundle_database.data` for the 8-byte magic signature `0xA33A4AA4AF26A69B`
3. **Creates a backup** as `bundle_database.data.bak`
4. **Replaces** 84 bytes at the found offset with a 184-byte pre-built record (`patch.bin`) that registers:
   - Bundle ID: `9ba626afa44a3aa3`
   - Stream file: `9ba626afa44a3aa3.stream`
   - **Patch entry**: `9ba626afa44a3aa3.patch_999` (the mod loader bundle)
   - Stream patch: `9ba626afa44a3aa3.stream.patch_999`
5. The `.patch_999` suffix ensures it loads **last** in the engine's bundle load order

### CLI Interface

| Flag | Description |
|------|-------------|
| (none) | Interactive patch (Windows shows dialog) |
| `--patch [DIR]` | Force patch |
| `--unpatch [DIR]` | Restore from backup |
| `--toggle [DIR]` | Toggle patch/unpatch |
| `--meta` | Print detected paths as JSON |

### Technology

- **Language**: Rust (Edition 2021)
- **Dependencies**: `steam_find` (custom fork), `winreg` (Windows-only)
- **Embedded asset**: `patch.bin` via `include_bytes!()`
- **Windows FFI**: Direct `User32.MessageBoxA` for GUI prompts
- **Release profile**: Size-optimized (`opt-level = "s"`, thin LTO, `panic = "abort"`)
- **License**: Dual MIT / Apache-2.0
- **CI**: GitHub Actions with artifact attestation since v0.1.8

### Key Limitation

Game updates or Steam file verification **revert the patch**, requiring users to re-run the tool every time Darktide updates.

---

## Component: Darktide-Mod-Loader

### Purpose

The **bridge layer** between Darktide's native `ModManager` and user mods. It provides the foundational Lua runtime that replaces/augments game engine functions, and manages mod discovery and load ordering.

Repo: [/Darktide-Mod-Framework/Darktide-Mod-Loader](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader)

### File Structure & Purpose

```
Darktide-Mod-Loader/
├── README.md                          # Installation instructions
├── toggle_darktide_mods.bat           # One-click wrapper around dtkit-patch --toggle
├── binaries/
│   └── mod_loader                     # Modified copy of Darktide's main.lua (game entry point)
├── mods/
│   ├── mod_load_order.txt             # User-edited text file listing mods by load order
│   └── base/
│       ├── mod_manager.lua            # Core ModManager class (Fatshark-style)
│       └── function/
│           ├── class.lua              # Monkey-patches global `class()` to register in CLASS table
│           ├── hook.lua               # Mods.hook API (function hooking chain system)
│           └── require.lua            # Monkey-patches `require()` to store file instances
└── tools/
    ├── dtkit-patch.exe                # Pre-built patcher binary
    └── README.md
```

### Key: `mod_manager.lua`

This is the **heart of the loader**. It implements a `ModManager` class that:

1. **Scanning phase**: Reads `mod_load_order.txt`, prepends `dmf` to the list, builds an internal mod table
2. **Loading phase**: Advances one listed mod per loading update, executes its
   `.mod` descriptor, calls `run()`, then initializes the returned outer object
3. **Running phase**: Calls `update(dt)` on each loaded mod every frame
4. **Failure state**: Stops routine callbacks for an outer entry after its first
   protected callback error; teardown callbacks remain available
5. **Supports**: Hot reload (left Ctrl + left Shift + R in developer mode),
   unload, game-state exit/enter dispatch, and final state exit during
   `GameStateMachine.destroy`

Notable: It **always** inserts DMF as the first mod in the load order (line: `table.insert(mod_load_order, 1, "dmf")`).

### Key: `function/hook.lua`

Implements `Mods.hook` — a **function hook chain system**:

- `Mods.hook.set(mod_name, func_name, hook_func)` — Replace a function with a chained hook
- Each hook receives the previous function as its first argument, forming a call chain
- `Mods.hook.enable()` / `Mods.hook.remove()` — Toggle or remove hooks
- Uses `loadstring` to dynamically generate hook chain functions at runtime
- Stores hooks in global `MODS_HOOKS` and `MODS_HOOKS_BY_FILE` tables

### Key: `function/require.lua`

**Monkey-patches Lua's global `require()`** to intercept module loading:

- Every `require()` call stores the returned table in `Mods.require_store[filepath]`
- Multiple instances of the same file are tracked separately
- Enables hooking into specific file instances after they're loaded
- This is how DMF's `hook_require()` works — it can inspect and modify any required module

### Key: `function/class.lua`

**Monkey-patches the global `class()` function** to:

- Register all created classes in a global `CLASS` lookup table
- Ensures classes are available in `_G` (global table)
- This enables hooking into class methods by name rather than by reference

### Loader surfaces consumed by DMF and community mods

The loader establishes these Lua-visible surfaces before DMF and user mods run:

| Surface | Observable contract |
| --- | --- |
| `Mods.original_require` / `Mods.require_store` | Preserve the engine module loader and retain required table instances for `hook_require`. |
| `Mods.lua.io`, `.loadstring`, `.os`, `.ffi` | Preserve engine facilities used by DMF. FFI is the table returned by `require("ffi")`; LuaJIT does not create `_G.ffi`. |
| `__print` | Retains the engine print function for loader/framework diagnostics. |
| `CLASS` and class globals | Register class results, return the unresolved class name as a string sentinel, and expose registered classes in `_G`. |
| `Managers.mod._mods`, `_mod_load_index`, `_state`, `_settings.developer_mode` | Supply the load-entry, completion, and developer-mode state read by DMF. |
| `ModManager:_check_reload()` | Detects the built-in left Ctrl + left Shift + R gesture. Community reload-control code can replace/hook this method to suppress the built-in trigger. |
| `_reload_requested` | A direct true value requests reload; current community reload-control code uses this field. |
| Game-state wrappers | Dispatch exit before `_change_state`, enter after it, and a final exit before `GameStateMachine.destroy`. |
| Crashify metadata | Publishes a property for accepted mod entries so loaded-mod identity reaches crash reporting. |

Observed direct community use includes
[`Alfs_DMF_Extensions`](https://github.com/deathbeam/darktide-mods-mine/blob/9e59327fb16297f6d70f014a2577965428ef7cff/mods/Alfs_DMF_Extensions/scripts/mods/Alfs_DMF_Extensions/modules/mod_reload_keybind.lua)
for `_check_reload` / `_reload_requested`,
[`PlayerOutlines`](https://github.com/qvex123321/DTModVersionControlRepository/blob/8b7481cd774610669d7a54e16c8d920d91fa46ae/mods/PlayerOutlines/main.lua)
for `Mods.file.dofile`, and guarded optional `Mods.message` use in
[`IconBrowser`](https://github.com/deathbeam/darktide-mods-mine/blob/9e59327fb16297f6d70f014a2577965428ef7cff/mods/IconBrowser/scripts/mods/IconBrowser/IconBrowser.lua).

### Installation Files

When installed into a game directory, the file layout is:

```
<game_dir>/
├── binaries/mod_loader              # Modified main.lua (replaces game entry point)
├── bundle/9ba626afa44a3aa3.patch_999 # Patch bundle (loaded by engine)
├── tools/dtkit-patch.exe            # Patch tool
├── toggle_darktide_mods.bat         # Toggle script
└── mods/
    ├── mod_load_order.txt           # User's mod list
    ├── base/                        # Loader Lua runtime
    └── dmf/                         # DMF framework
```

---

## Component: Darktide-Mod-Framework (DMF)

### Purpose

A comprehensive **Lua modding framework** that sits on top of the Mod Loader and provides a rich API for mod authors. It is itself loaded as the first mod. It provides hook management, events, keybindings, options UI, chat commands, localization, package management, and network scaffolding.

Repo: [Darktide-Mod-Framework](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework)

### Entry Point: `dmf.mod`

```lua
return {
  run = function()
    return Mods.file.dofile("dmf/scripts/mods/dmf/dmf_loader")
  end
}
```

This is called by the Mod Loader's `ModManager` during the loading phase. It returns a `dmf_mod_object` table with lifecycle callbacks: `init()`, `update(dt)`, `on_unload()`, `on_reload()`, `on_game_state_changed(status, state)`.

### Bootstrap: `dmf_loader.lua`

Loads modules in a specific order (not all can be loaded at once due to dependencies):

**Phase 1** (using raw `io_dofile` before DMF's IO module exists):
- `dmf_mod_data` — Defines the `DMFMod` class (base class for all mod objects)
- `dmf_mod_manager` — Creates the DMF mod itself and provides `new_mod()` / `get_mod()`
- `dmf_package_manager` — Resource/package loading
- Core basics: `safe_calls`, `events`, `settings`, `logging`, `misc`, `persistent_tables`, `io`

**Phase 2** (using DMF's own `io_dofile` now that IO module is ready):
- Debug tools: `dev_console`, `table_dump`
- Core features: `hooks`, `require`, `toggling`, `keybindings`, `chat`, `localization`, `options`, `network`, `commands`
- GUI: `custom_hud_elements`, `custom_textures`, `custom_views`
- UI: `chat_actions`, `mod_options`
- Framework: `dmf_options`, `mutators_manager`

### DMFMod Class (`dmf_mod_data.lua`)

Every mod gets a `DMFMod` object that provides:

- `get_name()`, `get_readable_name()`, `get_description()`
- `is_enabled()`, `get_internal_data(key)`
- Internal state: `name`, `readable_name`, `is_togglable`, `is_mutator`, `is_enabled`
- Hook/logging methods: `:hook()`, `:hook_safe()`, `:hook_origin()`, `:hook_require()`, `:hook_enable()`, `:hook_disable()`, `:info()`, `:warning()`, `:error()`

### DMF Mod Manager (`dmf_mod_manager.lua`)

- `new_mod(mod_name, mod_resources)` — Called by each mod's `.mod` file to register itself
- `get_mod(mod_name)` — Retrieve a registered mod object
- Handles mod resource loading: `mod_localization`, `mod_data`, `mod_script`
- Enforces that mods can only be created during the loading phase

### Hook System (`core/hooks.lua`) — 581 lines

DMF's hook system is **far more sophisticated** than the loader's basic `Mods.hook`:

Three hook types:
| Type | Method | Behavior |
|------|--------|----------|
| Normal | `mod:hook(obj, method, handler)` | Chains handlers; handler receives `original_func` as first arg |
| Safe | `mod:hook_safe(obj, method, handler)` | Observer pattern; runs after original, cannot modify return values |
| Origin | `mod:hook_origin(obj, method, handler)` | Replaces original function entirely; only one per function |

Advanced features:
- **Delayed hooks**: If the target object doesn't exist yet (not loaded), the hook is queued and applied when the object becomes available
- **hook_require**: `mod:hook_require(filepath, callback)` — Execute a callback
  on already-loaded and subsequently loaded instances of a required file
- **Enable/Disable**: Individual hooks or all hooks for a mod can be toggled at runtime
- **Rehooking**: Mods can opt-in to allow replacing their own hooks (for development)

### Module Size Breakdown

| Module | Lines | Purpose |
|--------|-------|---------|
| `core/options.lua` | 601 | Mod options widget definitions and settings |
| `core/hooks.lua` | 581 | Function hook chain management |
| `core/keybindings.lua` | 466 | Custom keybind registration and handling |
| `core/events.lua` | 160 | Event subscription and dispatch system |
| `core/io.lua` | 201 | File I/O (dofile, save/load settings) |
| `dmf_options.lua` | 280 | In-game options menu view |
| `dmf_package_manager.lua` | 218 | Resource package loading |
| `core/logging.lua` | 236 | Logging with levels (spew/info/warning/error) |
| `core/commands.lua` | 161 | Chat command registration |
| `core/settings.lua` | 90 | Persistent settings storage |
| `core/require.lua` | 87 | Extended require tracking |
| `core/safe_calls.lua` | 107 | pcall wrappers with error reporting |
| `core/toggling.lua` | 64 | Mod enable/disable toggling |
| `core/persistent_tables.lua` | 40 | Tables that persist across reloads |
| `core/network.lua` | 37 | Network RPC stubs |
| `core/misc.lua` | 36 | Utility functions |
| `core/chat.lua` | 19 | Chat message helpers |

**Total:** about 3,384 lines across the modules listed above.

### Developer console under Proton

DMF's developer console uses the published LuaJIT FFI module for its native
window-close path. Under Proton, the console is hosted by `wineconsole`; the
stock close action targets the native Windows `ConsoleWindowClass` and can leave
the OS window open even though DMF reports it closed. This stock DMF/Proton
behavior occurs even when `Mods.lua.ffi` is present.

---

## Mod Loading Flow (End-to-End)

```
1. User runs toggle_darktide_mods.bat
       │
       ▼
2. dtkit-patch patches bundle_database.data
       │
       ▼
3. User launches Darktide
       │
       ▼
4. Engine reads bundle_database.data, finds patch_999 entry
       │
       ▼
5. Engine loads 9ba626afa44a3aa3.patch_999 bundle
       │
       ▼
6. Bundle executes its trampoline script:
   → io.open("./mod_loader") → reads plain text from disk
   → loadstring(data)() → executes mod_loader (modified main.lua)
       │
       ▼
6b. mod_loader's init_mod_framework() runs:
   → Loads require(), class(), hook() monkey-patches
   → Loads custom ModManager from mods/base/mod_manager.lua
   → Hooks StateRequireScripts, StateGame.update, GameStateMachine
       │
       ▼
7. Loader's ModManager (mods/base/mod_manager.lua) takes over:
   a. Reads mod_load_order.txt
   b. Prepends "dmf" to load order
   c. For each mod: executes .mod file → runs init()
       │
       ▼
8. DMF loads first (dmf.mod → dmf_loader.lua):
   a. Bootstraps DMFMod class
   b. Loads all framework modules
   c. Patches global require(), class(), hook system
       │
       ▼
9. User mods load via new_mod("mod_name", { ... }):
   a. DMF creates DMFMod object
   b. Loads mod resources (localization, data, script)
   c. Mod registers hooks, options, keybinds, etc.
       │
       ▼
10. Game runs — DMF update loop:
    a. Package manager ticks
    b. Mod update(dt) callbacks fire
    c. Keybind checks execute
    d. Queued chat commands process
    e. Once all mods loaded: generate keybinds, init options GUI
```

---

## Current User Experience Pain Points

### Installation Friction
1. **Manual file copying** — Users must copy multiple directories into the game folder
2. **Batch file execution** — Must run `toggle_darktide_mods.bat` and understand console output
3. **Game updates break mods** — Every Darktide update reverts the bundle patch; users must re-patch
4. **No auto-detection** — Users must know their game installation path

### Mod Management Friction
5. **Text-file load order** — `mod_load_order.txt` must be manually edited with a text editor
6. **No dependency resolution** — Users must manually order mods and know dependencies
7. **No mod versioning** — No way to know if a mod is outdated
8. **No mod browser** — Mods must be found on Nexus Mods manually, downloaded, and extracted by hand
9. **No conflict detection** — If two mods hook the same function, there's no visibility into conflicts

### Developer Friction
10. **Separate toolchain** — Darktide Mod Builder is a separate tool for creating mods
11. **Developer-mode gate** — Hot reload is available only while DMF developer mode is enabled
12. **Distributed across 3+ repos** — dtkit-patch, Mod-Loader, Mod-Framework, Mod-Builder are separate

---

## Technology Summary

| Component | Language | Runtime | Key Dependencies |
|-----------|----------|---------|------------------|
| dtkit-patch | Rust | Native binary | `steam_find`, `winreg` |
| Darktide-Mod-Loader | Lua | Darktide engine | None (runs inside game) |
| Darktide-Mod-Framework | Lua | Darktide engine | None (runs inside game) |
| toggle_darktide_mods.bat | Batch | Windows cmd | dtkit-patch |

The entire runtime mod system (Loader + Framework) is **pure Lua** executing inside Darktide's Lua VM. There is no native code at runtime — the only native component is `dtkit-patch` which runs as a standalone tool before the game launches.

### How `mod_loader` Works (Critical Detail)

The `binaries/mod_loader` file is a modified copy of Darktide's own
`scripts/main.lua` — the game's primary Lua entry point. The loader release is
updated alongside game-main changes and adds the community loader surfaces and
lifecycle integration described above.

**The `patch_999` bundle does NOT contain compiled mod loader code.** Instead, the 524KB bundle contains only a tiny **trampoline script** that:

```lua
local file_name = "mod_loader"
local file_path = "."
file_path = file_path .. "/" .. file_name
local ff, err_io = io.open(file_path, "r")
if ff ~= nil then
    ff:close()
    local status, err_pcall = pcall(function ()
        local f = io.open(file_path, "r")
        local data = f:read("*all")
        local func = loadstring(data, file_path)
        func()
        f:close()
    end)
    -- error handling...
    return true
else
    print("[Mod Patch Bundle]: Error opening file '" .. file_path .. "'.")
    return false
end
```

This trampoline:
1. **Opens `./mod_loader`** from the game's `binaries/` directory
2. **Reads the plain text Lua file** from disk
3. **Executes it via `loadstring()`**

This is why the plain text `mod_loader` file **must exist at runtime** in `<game>/binaries/mod_loader`. The bundle's only job is to bootstrap the loading of the actual mod infrastructure from a user-editable file on disk. This design choice makes the mod loader **updatable without rebuilding bundles** — you just replace the text file.

The modders obtained the original `main.lua` content from the game's compiled bundles (14,678 binary bundle files, Oodle-compressed with `oo2core_9_win64.dll`). The extracted source was then modified to inject the mod-loading infrastructure into `Main.init()`:
- Creates the global `Mods` table (file I/O, messaging, Lua utilities)
- Monkey-patches `require()` to intercept module loading
- Loads the hook chain system and custom `ModManager`
- Hooks into game state transitions (`GameStateMachine._change_state`), final
  state-machine destruction (`GameStateMachine.destroy`), and the update loop
  (`StateGame.update`)
- Calls `init_mod_framework()` inside `Main.init()` after the game state machine is set up
