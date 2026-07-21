# Verification of DARKTIDE_FRAMEWORK_ANALYSIS.md

> **Status:** Complete. Verification audit of `darktide-framework-analysis.md`.
>
> Independent audit confirming the framework analysis doc's accuracy
> against the live game install and upstream source repos. All specific
> claims (byte counts, line counts, code snippets, API signatures) were
> checked and found correct, with minor discrepancies noted.

---

## Verdict

**The analysis is highly accurate.** The overwhelming majority of specific,
checkable claims — byte counts, line counts, code snippets, API signatures,
file paths, and structural relationships — are correct, often exactly. A
handful of minor inaccuracies are documented below; none are misleading
enough to undermine the document's value as a design reference.

**Verification coverage:**

| Category | Claims checked | Result |
|----------|----------------|--------|
| File existence / paths | ~20 | All correct |
| Byte/line counts | ~20 | All correct except one sum |
| Verbatim code excerpts | 4 | All correct |
| API signatures / globals | ~25 | All correct |
| Behavioral claims | ~15 | All correct |
| External/repo metadata | ~6 | All correct |

---

## What was verified (with evidence)

### dtkit-patch — every specific claim holds

| Doc claim | Verified against | Result |
|-----------|------------------|--------|
| App ID `1361210` | `src/main.rs:46` `steam_find::get_steam_app(1361210)` | exact |
| Magic `0xA33A4AA4AF26A69B` | `src/main.rs:14` | exact |
| Replaces 84 bytes with 184-byte record | `OLD_SIZE = 84`; `patch.bin` = **184 bytes** on disk | exact |
| Backup as `bundle_database.data.bak` | `BUNDLE_DATABASE_BACKUP` const + `fs::write` | exact |
| CLI flags `--patch/--unpatch/--toggle/--meta` | `main.rs` match arms | exact |
| `include_bytes!("./patch.bin")` | `src/main.rs:17` | exact |
| `User32.MessageBoxA` FFI | `src/main.rs:271-279` | exact |
| Edition 2021, MIT OR Apache-2.0 | `Cargo.toml` | exact |
| `opt-level = "s"`, `lto = "thin"`, `panic = "abort"` | `Cargo.toml [profile.release]` | exact |
| `steam_find` custom fork, `winreg` Windows-only | `Cargo.toml` deps | exact |
| Artifact attestation since v0.1.8 | `.github/workflows/release.yml` uses `actions/attest-build-provenance@v2` with `id-token: write`, `attestations: write` | exact |

**Independent physical confirmation of the byte math:** the live install
has both `bundle_database.data` (14,993,004 bytes, patched) and
`bundle_database.data.bak` (14,992,904 bytes, unpatched). The difference
is **exactly 100 bytes** = 184 − 84, which independently confirms the
doc's "replaces 84 bytes with 184-byte record" claim.

### Darktide-Mod-Loader — structure and internals confirmed

- `binaries/mod_loader` = **14,542 bytes / 549 lines** (exact match to doc).
- `mods/base/{mod_manager.lua, function/{class,hook,require}.lua}` — present exactly as diagrammed.
- `tools/dtkit-patch.exe` + `toggle_darktide_mods.bat` present; the `.bat` is verbatim a `dtkit-patch --toggle .\bundle` wrapper.
- `table.insert(mod_load_order, 1, "dmf")` — exists at **line 202** of `mod_manager.lua` (exact line cited in spirit).
- `.mod` execution via `_io.exec_with_return` — confirmed at `mod_manager.lua:242`.
- Hot-reload "Shift+Ctrl+R in developer mode" — confirmed precisely:
  ```lua
  ModManager._check_reload = function (self)
      return Keyboard.pressed(BUTTON_INDEX_R) and
          Keyboard.button(BUTTON_INDEX_LEFT_SHIFT) + Keyboard.button(BUTTON_INDEX_LEFT_CTRL) == 2
  end
  ```
  Gated by `self._settings.developer_mode` at line 107.

**`function/hook.lua`** — every named API and global exists:
- `MODS_HOOKS`, `MODS_HOOKS_BY_FILE` globals (lines 7-8)
- `Mods.hook.set`, `.enable`, `.remove` (the last as `["remove"] =` because `remove` is a Lua reserved word — a nice touch the doc could have mentioned), plus undocumented `.set_on_file`, `.enable_by_file`, `.front`
- Dynamic hook-chain generation via `loadstring` in `Mods.hook._patch()` — exactly as described, including the `return hook_name.func(before_hook_name.exec, ...)` chaining pattern.

**`function/require.lua`** — `Mods.require_store[filepath]` table stores every instance; monkey-patches global `require`. The doc's claim that "multiple instances of the same file are tracked separately" is exactly right (a list of instances is kept, not a single value).

**`function/class.lua`** — `_G.CLASS` lookup table populated via `rawset(_G.CLASS, class_name, result)` and also exposed via `_G`. Confirmed.

### Darktide-Mod-Framework — line counts match exactly

Every line count in the doc's "Module Size Breakdown" table is **exact**:

| Module | Doc | Actual |
|--------|-----|--------|
| core/options.lua | 601 | 601 |
| core/hooks.lua | 581 | 581 |
| core/keybindings.lua | 466 | 466 |
| core/events.lua | 160 | 160 |
| core/io.lua | 201 | 201 |
| dmf_options.lua | 280 | 280 |
| dmf_package_manager.lua | 218 | 218 |
| core/logging.lua | 236 | 236 |
| core/commands.lua | 161 | 161 |
| core/settings.lua | 90 | 90 |
| core/require.lua | 87 | 87 |
| core/safe_calls.lua | 107 | 107 |
| core/toggling.lua | 64 | 64 |
| core/persistent_tables.lua | 40 | 40 |
| core/network.lua | 37 | 37 |
| core/misc.lua | 36 | 36 |
| core/chat.lua | 19 | 19 |

**DMF hook system** (`core/hooks.lua`) — all three types and APIs verified:
- `hook_safe = 2`, `hook_origin = 3` enum values (lines 10-11); normal implied
- `DMFMod:hook`, `:hook_safe`, `:hook_origin`, `:hook_require`, `:hook_enable`, `:hook_disable` all present (plus bonus `:enable_all_hooks`, `:disable_all_hooks`)
- `DMFMod:{info,warning,error}` extended into the class via `core/logging.lua` (lines 152, 159, 166) — confirms the "later extended" claim

**DMFMod class fields** — `is_enabled`, `is_togglable`, `is_mutator` all present as documented; `get_name`, `get_readable_name`, `get_description`, `get_internal_data`, `is_enabled` methods all confirmed.

**DMF Mod Manager** — `new_mod(mod_name, mod_resources)` at line 95, `get_mod(mod_name)` at line 135, and the "too_late_for_mod_creation" error string confirms the "mods can only be created during the loading phase" claim.

**Two-phase bootstrap** — verified exactly. `dmf_loader.lua` uses raw `io_dofile` (Phase 1) for `dmf_mod_data`, `dmf_mod_manager`, `dmf_package_manager`, and core basics, then switches to `dmf:io_dofile` (Phase 2) after the literal comment `-- DMF's internal io module is now loaded:`. Module load order matches the doc's listing.

**Network module** — characterized as "Network RPC stubs." This is generous but accurate: `dmf.create_network_dictionary` and `dmf.ping_dmf_users` both contain `-- @TODO: Not implemented`. The subsystem is scaffolding.

### The critical "trampoline" claim — verified

This was the most unusual claim and the most important to check: the doc
asserts that the 524KB `9ba626afa44a3aa3.patch_999` bundle contains
**only a tiny trampoline script** that reads `./mod_loader` from disk and
`loadstring`s it, and quotes specific Lua code for it.

Verification:
- Bundle size on disk: **524,608 bytes ≈ 524 KB** (exact match).
- Running `strings` on the binary bundle surfaces every distinctive string from the doc's quoted snippet, verbatim:
  - `local file_name = "mod_loader"`
  - `local ff, err_io = io.open(file_path, "r")`
  - `local f = io.open(file_path, "r")`
  - `local func = loadstring(data, file_path)`
  - `[Mod Patch Bundle]: Error opening file '...`
  - `[Mod Patch Bundle]: Error executing file '...`

The doc's quoted trampoline code is real. (The bundle itself is Oodle-compressed and I did not fully decompress it, so I cannot swear the *control flow* between those strings is byte-identical to the doc's rendering — but the strings matching this closely is not a coincidence.)

### mod_loader / main.lua origin

- The comment `-- chunkname: @scripts/main.lua` exists at **line 305** of `binaries/mod_loader`, verbatim, confirming the "modified copy of Darktide's `scripts/main.lua`" claim.
- `local init_mod_framework = function()` at line 231; called at line 395 inside `Main.init`.
- The three hook targets named in the doc are all present inside `init_mod_framework`:
  - `_G.CLASS.StateRequireScripts._require_scripts` (line 240)
  - `_G.CLASS.StateGame.update` (line 246)
  - `_G.CLASS.GameStateMachine._change_state` (line 263)
  - (Plus `_G.CLASS.GameStateMachine.destroy` at line 284, which the doc doesn't mention.)

### Bundle count

The doc's parenthetical "14,678 binary bundle files" is **exact** — `ls bundle/ | wc -l` returns 14678.

---

## Discrepancies (minor)

These are the only factual issues found. None are material; I list them
for completeness.

1. **"Total: ~3,526 lines" is wrong.** The doc's own module table sums to **3,384** (and `wc -l` on the same files gives 3,385, the 1-line difference being a trailing-newline convention). The doc overshoots its own listed numbers by ~140 lines. The individual line counts are all correct; only the stated total isn't. The `~` hedge softens this but it's still off.

2. **The `patch_001` sanity check is omitted.** `main.rs` defines `BOOT_BUNDLE_NEXT_PATCH = "9ba626afa44a3aa3.patch_001"` and refuses to patch if that string is already present in the database. The doc describes only the `patch_999` write path and the magic-signature search. This is an omission rather than an error — the doc's description of *what the tool does* is accurate — but a reader implementing a rewrite from this doc alone would miss the "refuse if already touched" guard.

3. **`dmf_package_manager.lua` path is slightly off in one section.** The architecture diagram and the bootstrap section correctly locate it under `modules/`, but a reader cross-referencing might briefly wonder. (In practice the doc is consistent — `dmf_loader.lua` loads it from `dmf/scripts/mods/dmf/modules/dmf_package_manager`.)

4. **`mutators_manager` path imprecision.** The doc's bootstrap section writes `mutators_manager` as if it's a top-level module; the actual file is `modules/core/mutators/mutators_manager.lua` (a subdirectory). Cosmetic.

5. **The doc says mod loaders' hooks are stored "in global `MODS_HOOKS` and `MODS_HOOKS_BY_FILE`"** — correct. It does not mention `Mods.require_store` (where required-file instances live) is the *third* global that makes `set_on_file` work. Not wrong, just incomplete.

---

## What I could not independently verify

- **The exact trampoline control flow.** The bundle is Oodle-compressed (`oo2core_9_win64.dll`). I confirmed via `strings` that all distinctive literals from the doc's quoted code are present in the binary, but did not fully decompress and disassemble it. Confidence that the quoted snippet is real: very high. Confidence that it is byte-for-byte exactly as rendered: medium-high.

- **"Darktide Mod Builder is a separate toolchain" (pain point #10) and "Distributed across 3+ repos" (#12).** These are ecosystem characterizations rather than checkable facts about the install. The three core repos (dtkit-patch, Mod-Loader, Mod-Framework) are indeed separate; I did not investigate Mod-Builder specifically.

- **Game-update behavior ("reverts the patch").** Plausibly true and widely documented, but not something I tested.

---

## Notes for a rewrite (the doc's stated purpose)

If this analysis is being used to inform a modern rewrite, a few things
are worth adding that the current doc understates:

- The loader's `hook.lua` exposes **more API than the doc lists** (`set_on_file`, `enable_by_file`, `front`). A rewrite should decide explicitly whether to preserve, simplify, or drop these.
- `network.lua` is effectively dead code (`@TODO: Not implemented`). A rewrite should treat "networking" as an unimplemented aspiration in the current system, not a feature.
- The `["remove"]` reserved-word workaround and the heavy use of runtime `loadstring` for hook chaining are load-bearing design choices that any rewrite should consciously revisit — they exist because hook targets are addressed by *global string name*, which is what makes the system work without holding references to original functions.

---

## Methodology

All evidence gathered by direct inspection of:
- `/games/steamapps/common/Warhammer 40,000 DARKTIDE/` (live modded install)
- The game install and upstream source repos (dtkit-patch, Darktide-Mod-Loader, Darktide-Mod-Framework)

Tools: `ls`, `wc`, `strings`, `grep`, direct file reads. No game was
launched; all verification was static.
