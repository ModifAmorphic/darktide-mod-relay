# Mod Relay (runtime)

**Mod Relay (runtime)** is the injected modding runtime + its launcher for
Darktide. It launches the game modded via DLL injection — no files in the game
directory, no bundle-database patching — and stays out of the way for vanilla
play (launch the game from Steam and it runs unmodified). The Relay runtime
comprises the **mod loader** (the runtime-staged Lua that loads DMF + user mods)
plus the launcher that delivers it.

- **Architecture:** [`docs/architecture/MOD-RELAY.md`](../docs/architecture/MOD-RELAY.md)
  — the subcomponents, the Rust↔C seam, the launcher flow, the env-var
  contract, logging.
- **DMF integration:** [`docs/architecture/MOD_LOADER-DMF.md`](../docs/architecture/MOD_LOADER-DMF.md)
  — how the mod loader loads DMF (the Darktide Mod Framework) + user mods, the
  IO adaptation, and the load timing.
- **Project overview:** [`../README.md`](../README.md) (end-user), and
  [`../AGENTS.md`](../AGENTS.md) (agent orientation + ops).

> **Audience:** developers / power users. This is the build + component detail;
> the root [`README.md`](../README.md) is the end-user entry point.

## Sub-components

| Dir | What it is |
| --- | --- |
| **`discovery/`** | Rust crate — the LuaJIT discovery engine. A pure library (no I/O, no global state): a PE image (`&[u8]`) → the 16 LuaJIT/engine function addresses. 100% safe Rust in core logic; offline-testable. Compiled to a C-ABI staticlib (`librelay_discovery.a`). |
| **`shell/`** | The injected C DLL — **`relay_shell.dll`**. Installs two production MinHook detours (`lua_newstate` → capture the Lua VM; `lua_pcall` → run the staged mod loader one-shot at pcall#1), discovers the LuaJIT function addresses in-process, and loads the staged mod loader in engine context. Linked with the Rust discovery staticlib + MinHook. Carries `VS_VERSION_INFO` PE version resources compiled from `shell/src/relay_shell.rc`. |
| **`launcher/`** | The C injector — **`mod_relay.exe`**. `CreateProcess(Darktide.exe, SUSPENDED)` → inject `relay_shell.dll` → wait for the hook-ready signal → `ResumeThread`. Resolves the flag/env config and publishes it into the child env. Carries `VS_VERSION_INFO` PE version resources compiled from `launcher/src/launcher.rc`. |
| **`mod_loader/`** | The Lua mod loader. Runs in engine context, bridges pcall#1 to the engine's late boot (deferred bootstrap), and loads DMF + user mods. Entry `init.lua` + modules (`path`, `file`, `class_registry`, `lifecycle`, `require_bridge`, `mod_manager`, `dmf_adapter`). `init.lua` publishes the engine LuaJIT FFI module via the pre-wrap module loader (`Mods.original_require("ffi")` — `require("ffi")` creates no global in LuaJIT 2.1). `lifecycle.lua` is the bootstrap coordinator + the direct closure-wraps (`BootStateRequireGameScripts._state_update`, `StateGame.update`, `GameStateMachine._change_state` exit/enter dispatch, and `GameStateMachine.destroy` — a final-exit wrapper that dispatches one deduplicated `on_game_state_changed("exit",…)` for the active state before destruction). `path.lua` is a pure-string path utility (`normpath` extracted from Penlight `pl.path` + `is_within` adapted from `pl.path.relpath`'s segment comparison) used by `file.lua`'s `Mods.lua.io.open`/`io.lines` wrapper to root DMF's `./../mods/<rest>` convention at the mod-path boundary. `mod_manager.lua` is the generic scan/load/lifecycle driver **and the hot-reload state machine** (request seam, `_check_reload` trigger-detection seam for the community reload-control contract, keyboard trigger, two-frame teardown/replacement sequencing, reload-data association, failure isolation); `dmf_adapter.lua` is the stock-DMF compatibility boundary (persisted developer-mode restoration, DMF-visible contract fields + transitions, entry-shape validation, the eight `DMFMod:io_*` overrides + the file observer that drives them, **installation-aware** re-adaptation across reload (tracks `DMFMod` table identity + the exact Relay `io_dofile` wrapper so a reused class table whose methods `core/io.lua` overwrites is re-adapted, not left on stock `./../mods`), and stale-generation-global retirement). Relay-controlled (ships with the build) and independently implemented for Relay's injected runtime architecture. |
| **`tests/`** | C unit tests (run via wine). |
| **`bin/`** | Build outputs (gitignored). Where `make build` lands everything. |

The workspace root (`Cargo.toml` / `Cargo.lock` / `Makefile`) lives here in
`src/`, not the repo root — **all build/test commands run from `src/`**.

## Build artifacts (`make build` → `bin/`)

- **`bin/mod_relay.exe`** — the C injector (from `launcher/`). The
  injector process that creates the game suspended, injects the shell DLL,
  waits for the hook-ready handshake, and resumes. Sets the Steam app id and
  publishes the runtime's env vars.
- **`bin/relay_shell.dll`** — the injected DLL (from `shell/`): the C shell
  linked with the Rust discovery staticlib (`librelay_discovery.a`) +
  MinHook, into one PE DLL. Hooks the Lua VM, runs discovery in-process, and
  stages the mod loader.
- Both production binaries carry a `VS_VERSION_INFO` PE resource
  (`ProductName`, `FileVersion`, `OriginalFilename`, `FileDescription`,
  `LegalCopyright`, `CompanyName`) populated at build time from
  `.release-please-manifest.json` via the same `RELAY_VERSION` source that
  drives `--version`. Numeric components (MAJOR/MINOR/PATCH) are split from
  `RELAY_VERSION` on `.` and `-` and passed to `rc.exe` (MSVC) / `windres`
  (MinGW) as preprocessor defines; the `.rc` composes both the binary
  `FILEVERSION` 4-tuple and the string fields from those same defines, so the
  two cannot drift.
- **`bin/mod_loader/`** — the mod loader Lua (from `mod_loader/`), staged next
  to the launcher/DLL. This is the **Relay-controlled** loader root the shell
  self-locates from its own DLL path (`<dll-dir>/mod_loader/`, set as the
  internal `MOD_LOADER_DIR` global — not an env var/flag); the trampoline loads
  `init.lua` from here. User mods live in a separate, user-controlled mod root
  (see [Two roots](#two-roots)).
- **`bin/LICENSE`** + **`bin/THIRD_PARTY_NOTICES.md`** — root legal notices
  staged beside the executables so every distributable runtime bundle carries
  the required license attribution (Relay's GPL LICENSE + the notices for the
  statically-linked MinHook + Capstone dependencies). `make build` copies them
  from the repo root.

## Build + test

Run from `src/`:

```sh
export PATH="$HOME/.cargo/bin:$PATH"   # system rust lacks the windows-gnu target
export DARKTIDE_GAME_DIR=/path/to/Darktide   # game install dir; needed for oracle tests (see below)

make build          # cross-compile DLL + launcher (x86_64-pc-windows-gnu)
make check          # verify valid PE DLL with DllMain
make test           # C tests (via wine) + Rust tests + mod loader Lua tests
make mod-loader-test # mod loader Lua tests (offline LuaJIT harness; no game/wine)
```

### Build + test (Windows native / MSVC)

On Windows, use `.\build.ps1` — a PowerShell 5.1 script (no PS 7 features,
no external modules) that mirrors the Makefile target-for-target. It
self-locates `src/` via `$PSScriptRoot`, so it runs identically invoked from
`src\` (`.\build.ps1 build`) or from the repo root (`.\src\build.ps1 build`).
The same target names + semantics as `make`. The script assumes the toolchain
is already on PATH (just like the Makefile); if you just installed a tool,
open a new shell (or reboot) so PATH is refreshed before running it.

Toolchain prerequisites:
- **Visual Studio 2022 Build Tools** with the VCTools workload
  (`Microsoft.VisualStudio.Workload.VCTools`) — provides `cl`, `link`,
  `dumpbin`, and `vswhere` (the script locates `vcvars64.bat` via vswhere and
  loads it per cl/link/dumpbin invocation).
- **Rust** (stable) via [rustup](https://rustup.rs) — install the
  `x86_64-pc-windows-msvc` target (rustup default on Windows).
- **LuaJIT 2.1** — `winget install DEVCOM.LuaJIT` (for `mod-loader-test`).

```powershell
.\build.ps1                   # build (default): dll + launcher + stage-mod_loader + stage-legal
.\build.ps1 check             # verify relay_shell.dll is a valid PE with the production seam
.\build.ps1 test              # c-tests + cargo test + mod-loader-test
.\build.ps1 mod-loader-test   # offline LuaJIT harness (no game, no wine)
.\build.ps1 clean             # cargo clean + remove bin\
```

Targets: `build` (default) / `all` / `dll` / `launcher` / `stage-mod_loader` /
`stage-legal` / `check` / `c-tests` / `mod-loader-test` / `test` / `clean`.
`build` (or `all`) produces the full `bin\` artifact set — `relay_shell.dll`,
`mod_relay.exe`, `mod_loader\` (the 7 runtime Lua modules), and the
staged `LICENSE` + `THIRD_PARTY_NOTICES.md`.

`DARKTIDE_GAME_DIR` points at your Darktide install root so the oracle tests
can run discovery against the real binary.
To avoid re-typing it each session, drop `export DARKTIDE_GAME_DIR=...` into a
shell file and `source` it — keep it **outside** the repo (e.g.
`~/.config/darktide-mod-relay/env`), or if you keep it inside the repo,
add it to `.gitignore` (never commit the game path or the game binary). Without
it, oracle tests skip cleanly. See `AGENTS.md` for the full ops notes.

- **MinGW cross-compile** from Linux produces the Windows DLL + launcher. MSVC
  native on Windows is also supported (CI runs both).
- **Oracle tests** run discovery against the real `Darktide.exe` (resolved via
  `DARKTIDE_GAME_DIR`). The engine is build-agnostic (Tier-2 self-validation
  passes on any build; Tier-1 exact-match skips if the SHA differs from the
  pinned one). In CI (no game install) they skip cleanly.
- **Mod loader Lua tests** are an offline LuaJIT harness — no game, no wine.
  They cover the scan/load split, the class registry, the require bridge, the
  lifecycle closure-wraps, the IO observer adaptation, persisted developer-mode
  restoration, and the full hot-reload state machine (`test_hot_reload.lua`:
  request seam, exact LEFT Ctrl+Shift+R parity, two-frame teardown/replacement
  ordering, reload-data keying, identity survival across three generations,
  generation-aware IO + single observer, global retirement, the failure/best-
  effort contract, and the no-double-unload shutdown invariant).
- **`test-hooks` feature** gates the debug panic-boundary symbol out of release
  builds: `cargo test --features test-hooks -p relay-discovery` (and
  `cargo clippy --all-targets --features test-hooks -- -D warnings`). `make
  test` handles this.

## Launcher CLI

The launcher is **flag-based**, where every setting follows
**flag > env var > default**. `--game-binary` is the only required flag; the
shell DLL, log file, and mod loader root all default next to the launcher exe.

| Flag | Env var | Default |
| --- | --- | --- |
| `--game-binary <path>` | `RELAY_GAME_BINARY` | — **(required)** |
| `--mod-path <path>` | `RELAY_MOD_PATH` | unset (mods won't load) |
| `--log-file <path>` | `RELAY_LOG_FILE` | `<launcher-dir>\relay.log` |
| `--log-level <level>` | `RELAY_LOG_LEVEL` | `info` (`error`/`warn`/`info`/`debug`/`trace`) |
| `--steam-app-id <id>` | `RELAY_STEAM_APP_ID` | `1361210` |
| `--` (separator) | — (none) | unset (rest-of-line forwarded to the game) |
| `--version` | — (none) | — (prints the build-injected version; see below) |

The injected DLL (`relay_shell.dll`) is hardcoded to `<launcher-dir>\` and
self-locates the mod loader (`<dll-dir>\mod_loader\`); neither path is
configurable.

### Forwarding command-line arguments to the game

A bare `--` is the **end-of-options separator**. Every token after it is
forwarded to the game verbatim, in order, as a separate argv entry — appended
after the quoted exe and rendered with the **MSVC CRT quoting algorithm**
(spaces/tabs/quotes are quoted; backslashes before a quote are escaped; trailing
backslashes inside a quoted token are doubled). Relay's own flags must precede
`--`; a token that looks like `--version` or `--mod-path` **after** `--` is a
raw game argument, not a Relay flag. The `--` itself is consumed (not
forwarded). No `--` (or no tokens after it) yields the original exe-only command
line byte-for-byte. A space-containing game arg is shell-quoted once by the
caller (`-- "a b"`) exactly as for any CLI. There is deliberately **no env
serialization** of the tail — the only input path is the command line after `--`.

```
mod_relay.exe --game-binary <exe> -- --lua-heap-mb-size 2048
  → game argv: Darktide.exe --lua-heap-mb-size 2048
```

- **ANSI only** (the Windows active code page). Darktide.exe arguments are ASCII
  (relative paths, ini-section identifiers, HTTPS URLs); there is no known
  Darktide argument that takes a non-ANSI value, so the launcher stays on
  `CreateProcessA`. If a non-ANSI value ever needs forwarding, the launcher must
  widen to `CreateProcessW` (a separate change).
- The full command line is capped at **32,767 chars** (`RELAY_CMDLINE_MAX`,
  the `CreateProcessA` ceiling including the NUL); an oversize line is rejected
  before any process is created (the launcher exits nonzero).
- `--version` is a **value-less flag**: it prints `mod_relay <version>`
  and exits 0 without requiring `--game-binary`. The version is **build-injected**
  from `.release-please-manifest.json` (the file release-please bumps at release
  time), so a shipped exe always reports its release version with no version
  constant baked into source. A caller like Curator uses it for version
  comparison (e.g. to detect the minimum version that supports `--` forwarding).

See [`docs/architecture/MOD-RELAY.md`](../docs/architecture/MOD-RELAY.md)
→ `launcher/` for the full table, the env-var contract, and logging details.

## Two roots

The mod loader and the mods live in **separate** directories, resolved as two
values:

- **`MOD_LOADER_DIR`** (self-located by the shell from its own DLL path as
  `<dll-dir>\mod_loader\`, set as an **internal** global — not an env var/flag)
  — **Relay-controlled**. Holds `init.lua` + its modules. Ships with the build
  (`make build` stages it); a DMF/mod update never requires a Relay rebuild.
- **`RELAY_MOD_PATH`** (from `--mod-path` / `RELAY_MOD_PATH`) —
  **user-controlled**. The **mod-path boundary**: a directory that *contains*
  a `mods/` subdirectory. DMF + user mods + `mods.lst` (the load-order file;
  you author it, or your app generates it) live at `<mod_path>/mods/`. The
  loader derives `Mods._mod_root` as `<mod_path>/mods` (what `Mods.file.*`
  roots at) and `Mods._mod_path` as the containment boundary for the
  `Mods.lua.io` raw-read wrapper.

The split keeps the loader's own code Relay-owned while the mods it loads are
user-owned. Detail in
[`docs/architecture/MOD_LOADER-DMF.md`](../docs/architecture/MOD_LOADER-DMF.md).
