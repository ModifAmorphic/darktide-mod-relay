# Community-tool reference verification

> **Status:** Complete verification record for
> [`darktide-framework-analysis.md`](darktide-framework-analysis.md).
>
> The reference is checked against a live installed toolchain, current upstream
> loader/framework revisions, the game install, and the game binary plus
> extracted script history. Version-specific facts are
> pinned below rather than presented as timeless API guarantees.

## Evidence baselines

| Component | Verified baseline |
| --- | --- |
| dtkit-patch | Installed patcher plus upstream Rust source used by the live toolchain audit |
| Darktide-Mod-Loader | Release [`26.06.24`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader/releases/tag/26.06.24), commit [`4bd075a`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Loader/tree/4bd075adf47aedaabacd114a668d45789ecd9f85) |
| Darktide-Mod-Framework | Commit [`b9cc65f`](https://github.com/Darktide-Mod-Framework/Darktide-Mod-Framework/tree/b9cc65f773cd8aaa974bf5b9312a79f5c5785f90) |
| Installed legacy loader snapshot | `binaries/mod_loader` at 14,542 bytes / 549 lines, used to verify the original physical-install and trampoline claims |
| Game install | Darktide app ID `1361210`, patched and backup bundle databases, installed patch bundle |
| Darktide native binary | Current installed `Darktide.exe`; static string/binding-name inspection |
| Darktide extracted scripts | [`Aussiemon/Darktide-Source-Code`](https://github.com/Aussiemon/Darktide-Source-Code) mirror at 1.12.5 commit [`0f0cb459`](https://github.com/Aussiemon/Darktide-Source-Code/tree/0f0cb45991e9305ef4a7b925370792d7d6035f95); early External-Test commit `d5b66e94` and 1.0.40 removal commit `4cd2fae4` |

## dtkit-patch

The patcher facts in the reference are verified:

- Steam app ID `1361210`;
- bundle-database magic `0xA33A4AA4AF26A69B`;
- replacement of an 84-byte record with a 184-byte embedded `patch.bin`;
- backup at `bundle_database.data.bak`;
- `--patch`, `--unpatch`, `--toggle`, and `--meta` commands;
- Rust 2021, `steam_find`, Windows-only `winreg`, and native message-box use;
- size-oriented release profile with thin LTO and aborting panics.

The installed patched database is exactly 100 bytes larger than its backup,
matching the 184 − 84 replacement. The patcher also checks for the next
`patch_001` marker and refuses an already-touched database.

## Darktide-Mod-Loader

The release preserves the established file layout:

- `binaries/mod_loader` is a modified game `scripts/main.lua` entry;
- `mods/base/mod_manager.lua` owns scanning, loading, lifecycle drive, and hot
  reload;
- `mods/base/function/{class,hook,require}.lua` establish the loader-visible
  class, hook, and require surfaces;
- `mods/mod_load_order.txt` is the user-edited order file;
- `toggle_darktide_mods.bat` invokes the bundled patcher.

The current loader behavior directly relevant to DMF/community compatibility is
also verified:

- `dmf` is prepended to the load order;
- the manager builds its mod table before loading and advances one mod per
  loading update;
- `.mod` descriptors execute through the loader file service, followed by
  `run()` and outer-object initialization;
- `Mods.original_require`, `Mods.require_store`, `Mods.lua.io`,
  `Mods.lua.loadstring`, `Mods.lua.os`, `Mods.lua.ffi`, and `__print` are
  established before DMF loads;
- FFI is retained from the return value of `require("ffi")`; LuaJIT does not
  create a global `ffi`;
- global `require` records returned table instances for file-based hooks;
- global `class` records classes in `CLASS` and publishes registered classes in
  `_G`;
- `Mods.hook` provides dynamic named hook chains, including file-instance hook
  support;
- `ModManager:_check_reload()` detects left Ctrl + left Shift + R and is
  replaceable by community hook code;
- direct `_reload_requested = true` initiates the manager reload path;
- state changes dispatch exit/enter callbacks, and
  `GameStateMachine.destroy` dispatches the final state exit;
- accepted mod entries publish per-mod Crashify metadata;
- a protected outer callback failure disables routine callbacks for that loader
  entry while retaining teardown behavior.

The generic loader surfaces are broader than DMF's own required subset.
`Mods.message`, exact legacy `Mods.file` signatures, network-shaped manager
methods, and splash control are loader facilities or conveniences rather than
DMF bootstrap requirements.

## Darktide-Mod-Framework

The DMF contracts recorded in the reference are verified:

- `dmf.mod` returns a top-level object with init, update, state-change, reload,
  and unload callbacks;
- bootstrap is split into Phase 1 through the loader-rooted file function and
  Phase 2 through `DMFMod:io_*` methods;
- `new_mod` and `get_mod` own registered user-mod creation and lookup;
- `DMFMod` exposes normal, safe, origin, and require-based hooks plus hook
  enable/disable operations;
- logging extends `DMFMod` with `info`, `warning`, and `error`;
- DMF reads `Managers.mod._mods[_mod_load_index]`, `_state == "done"`, and
  `_settings.developer_mode` from the loader;
- DMF's network module is scaffolding: its dictionary/ping operations remain
  unimplemented;
- the developer console uses the loader-supplied FFI module for its native
  close path.

Under Proton the developer console is hosted by `wineconsole`; the stock native
class lookup can leave that OS window open even when DMF reports it closed.
This behavior occurs with `Mods.lua.ffi` present and the native close path
active.

## Patch-bundle trampoline

The installed `9ba626afa44a3aa3.patch_999` bundle contains the distinctive
trampoline strings that open `./mod_loader`, read it, compile it with
`loadstring`, and report open/execution failures. The plain-text
`binaries/mod_loader` file is therefore required at runtime; the patch bundle
provides the entry into that file.

The bundle remains Oodle-compressed. The string evidence establishes the file
path, loadstring handoff, and diagnostics; it does not establish a byte-for-byte
rendering of the compressed script's complete control flow.

## Native mod substrate versus current stock activation

The reference's capability-versus-activation distinction is verified against
the game binary and the extracted script mirror:

- The current installed `Darktide.exe` contains Stingray mod
  machinery/binding-name strings — `stingray::steam::SteamUgcModManager`,
  `Mod`, `start_scan`, `is_scanning`, `mods`, `.mod`, `.mod_bundle`,
  `resource_package`, `release_resource_package`, and UGC-mod diagnostics.
  This establishes compiled native capability (the substrate the engine
  carries); it does not establish that current stock Lua drives it.
- The Darktide 1.12.5 extracted scripts
  (`0f0cb45991e9305ef4a7b925370792d7d6035f95`) contain no
  `scripts/managers/mod/mod_manager.lua`, no `Managers.mod`, and no call to
  `Mod.start_scan`; stock `scripts/main.lua` does not bootstrap mods.
- The earliest External-Test source commit `d5b66e94` includes
  `scripts/game_states/boot/state_load_mods.lua`, which would require
  `scripts/managers/mod/mod_manager` and assign `Managers.mod`. The
  referenced manager is absent from the extracted history and
  `StateBootLoadMods` is not present in the explicit `Main` boot-state list,
  so the stub is recorded as vestigial/inactive scaffolding — not proof of
  an active retail pipeline. The stub and its `main.lua` require were
  deleted in 1.0.40 commit `4cd2fae4`.

Community `.mod` discovery/execution is therefore attributed to DML's own
manager, on DML's own evidence:

- DML `binaries/mod_loader` (`4bd075adf47aedaabacd114a668d45789ecd9f85`)
  states, in its own comments, `The mod manager isn't in the bundles, so
  load our version from the mods folder`, then executes `base/mod_manager`.
- `mods/base/mod_manager.lua` reads `mod_load_order.txt` and executes each
  `<mod>/<mod>.mod` through DML's filesystem `Mods.file` host.
- The entry path needs no native UGC scan: the dtkit-patch source
  identifies `9ba626afa44a3aa3` as the boot bundle and splices
  `9ba626afa44a3aa3.patch_999` (plus the stream patch) into
  `bundle_database.data` as a patch layer; the installed patch bundle
  carries the trampoline that opens `./mod_loader` (see
  [Patch-bundle trampoline](#patch-bundle-trampoline)); and
  `binaries/mod_loader` is a complete modified `scripts/main.lua`.

## Direct community-use references

- [`Alfs_DMF_Extensions` reload integration](https://github.com/deathbeam/darktide-mods-mine/blob/9e59327fb16297f6d70f014a2577965428ef7cff/mods/Alfs_DMF_Extensions/scripts/mods/Alfs_DMF_Extensions/modules/mod_reload_keybind.lua)
  uses `_check_reload` and `_reload_requested`.
- [`PlayerOutlines`](https://github.com/qvex123321/DTModVersionControlRepository/blob/8b7481cd774610669d7a54e16c8d920d91fa46ae/mods/PlayerOutlines/main.lua)
  calls `Mods.file.dofile` directly.
- [`IconBrowser`](https://github.com/deathbeam/darktide-mods-mine/blob/9e59327fb16297f6d70f014a2577965428ef7cff/mods/IconBrowser/scripts/mods/IconBrowser/IconBrowser.lua)
  uses `Mods.message` only behind a capability check.

## Verification limits

- The exact compressed trampoline body is not decompressed and no
  byte-for-byte bundle-resource mapping was verified; its distinctive
  strings and the runtime file handoff are verified.
- Static binary string/binding-name evidence is not a live Lua availability
  probe: no live `type(Mod)` probe was run, so whether the native global
  `Mod` remains callable in the current live Lua VM is unverified.
- The Aussiemon repository is an extracted/decompiled script mirror, not
  Fatshark's official complete native source; absences in it evidence the
  shipped/extracted script set, not Fatshark's internal tree.
- The initial game-update patch-reversion observation is ecosystem behavior,
  not a mutation test performed during this audit.
- Public source snapshots demonstrate specific consumers, not every mod in the
  ecosystem.

## Method

Evidence comes from direct file reads, repository history/source inspection,
the installed game/toolchain layout, file-size and line-count checks, string
inspection of the patch bundle, static string inspection of the installed game
executable, and inspection of the extracted Darktide script mirror and its
history. No game process was launched for the static verification pass.
