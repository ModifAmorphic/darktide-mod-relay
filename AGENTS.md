# AGENTS.md — darktide-mod-relay

> Orientation for any agent working in this repo. Read this first. This file
> is for **agents**, not humans — the human-facing entry point is `README.md`.

## What this is

**Mod Relay** is the injected modding runtime + launcher for Warhammer
40,000: Darktide. It launches the game modded via DLL injection (no
game-directory footprint, no bundle-database patching) and stays out of the way
for vanilla play (launch from Steam = unmodified game).

Architecture: a **Hybrid** — a Rust discovery pure-library (C-ABI staticlib) +
a C live-game shell, linked into one DLL, delivered by `CreateRemoteThread`;
plus the C injector (the launcher) and the runtime-staged Lua **mod loader**
that loads DMF + user mods. See `docs/architecture/` for the full architecture.

Mod Relay is a standalone runtime: run the launcher from a shell, or
invoke it from an app. (It's the runtime that powers Mod Curator, but any
caller works — there's no required coupling to a particular mod manager.)

## Baseline

Production is built ground-up with testability, review, and production-readiness
as first-class goals. Validated technical constraints that are properties of
the Darktide binary (not of any implementation) are recorded in
`docs/reference/darktide/darktide-binary.md`.

## Repository state

- **`main`** — production. The Relay runtime (the injected modding runtime +
  launcher + mod loader) is the production seed, migrated under `src/`.
  Releases are cut by release-please (see
  `.github/workflows/release-please.yml`); the project is currently in 0.x
  prereleases. The shipped shell installs exactly two production hooks
  (`lua_newstate` + `lua_pcall`) and the one-shot production trampoline.
- Development is branch + PR; no unreviewed merges to `main` (reviewed +
  covered + qa'd + CI green).

## Directory structure (current `main`)

```
src/                Mod Relay — the injected modding runtime + injector
  Cargo.toml        workspace root (members = ["discovery"])
  Cargo.lock
  Makefile          builds Relay: make build / check / test / mod-loader-test / clean
                    (run from src/ — all commands below assume CWD = src/)
  bin/              ALL build outputs land here (gitignored): mod_relay.exe,
                      relay_shell.dll + mod_loader/ (the staged mod loader Lua),
                      and the staged root legal notices (LICENSE +
                      THIRD_PARTY_NOTICES.md — required in every distributable
                      bundle).
  target/           cargo build artifacts (gitignored)
  discovery/        Rust crate: LuaJIT discovery engine (pure library, C-ABI staticlib)
  shell/            C shell — the injected DLL (DllMain, MinHook, lua_newstate +
                      lua_pcall hooks, production trampoline @ pcall#1; log_sink.c
                      is the pure, I/O-free lua-print line-sanitization helper for
                      the optional print tee, compiled into both the DLL and the
                      C unit tests)
  launcher/         C launcher — CreateRemoteThread injector + hook-ready handshake
  mod_loader/       the mod loader — Relay's runtime-staged Lua loader (LuaJIT):
                      init.lua entry + modules (path/file/class_registry/
                      require_bridge/lifecycle/mod_manager/dmf_adapter) +
                      tests/ (offline LuaJIT harness, run via
                      `make mod-loader-test`). init.lua publishes the engine
                      LuaJIT FFI module via the pre-wrap module loader
                      (Mods.original_require("ffi") — require("ffi") creates no
                      global in LuaJIT 2.1; bootstrap-private, degrades to nil +
                      one diagnostic if unavailable); init.lua also owns the
                      OPTIONAL Lua print tee (the process-lifetime, non-stacking
                      print/__print wrapper that copies Lua print output into
                      relay.log when --lua-logs/RELAY_LUA_LOGS=1 — retires the
                      trampoline's private __mod_relay_lua_log_sink temp global
                      before its idempotency guard; originals stay authoritative;
                      covered by tests/test_lua_logs.lua + the
                      tests/probes/observational/lua_logs_probe/ live probe); lifecycle.lua is the
                      bootstrap coordinator + the direct closure-wraps
                      (BootStateRequireGameScripts._state_update,
                      StateGame.update, GameStateMachine._change_state exit/enter
                      dispatch, and GameStateMachine.destroy — the final-exit
                      wrapper that dispatches one deduplicated
                      on_game_state_changed("exit",…) for the active state before
                      destruction, closing the community-contract gap where a
                      state destroyed without a preceding _change_state exit
                      would otherwise receive none); mod_manager.lua is the generic
                      scan/load/lifecycle driver + the hot-reload state machine
                      (request_reload seam, _check_reload trigger-detection seam
                      for the community reload-control contract (detection only,
                      dynamic dispatch so a community replacement can suppress or
                      redirect the built-in gesture), LEFT Ctrl+Shift+R keyboard
                      trigger, two-frame teardown/replacement sequencing,
                      reload-data association keyed by name, nil/table-only
                      run-result validation, unconditional load finalization,
                      generation-aware Crashify metadata (`Mod:<name>` plus
                      process-lifetime `ModRelay:Version`), one-strike outer
                      lifecycle containment (standalone disable vs framework-
                      boundary generation stop), guarded engine-event alerts,
                      exactly-once cleanup, failure isolation, no stacking);
                      dmf_adapter.lua is the stock-DMF compatibility boundary
                      (persisted developer-mode restoration from
                      Application.user_setting, DMF-visible contract fields +
                      transitions incl. mark_load_pending/is_load_done/
                      developer_mode_enabled, entry-shape validation, the eight
                      DMFMod:io_* overrides + the file observer that drives them,
                      installation-aware re-adaptation across reload (tracks
                      DMFMod table identity + the exact Relay io_dofile wrapper
                      so a reused class table whose methods core/io overwrites
                      is re-adapted, not left on stock ./../mods), and
                      retire_stale_generation_globals (clears the globals but
                      retains the private markers)).
                      `make build` stages the entry + modules into bin/mod_loader/
                      (the Relay-controlled loader root, self-located by the
                      shell from its own DLL path and set as MOD_LOADER_DIR).
  tests/            C unit tests (run via wine); includes the pure log_sink.c
                      sanitizer tests (compiled directly, no Windows/Lua deps)
  README.md         the component README (developers / power users)
docs/               architecture/ + reference/ (darktide/, community-tools/)
.github/workflows/  CI: pr.yml (PR gate: mingw cross-compile + msvc native) +
                      release-please.yml (release pipeline + Windows bundle attach)
.gitignore          ignores src/target, src/bin, build artifacts
```

The workspace root (`Cargo.toml`/`Cargo.lock`/`Makefile`) lives under `src/`,
not the repo root — all build/test commands run from there.

## Agent ops

Build + test (Linux dev box) — run from `src/`:
```sh
export PATH="$HOME/.cargo/bin:$PATH"      # system rust lacks the windows-gnu target
export DARKTIDE_GAME_DIR=/path/to/Darktide # game install dir; needed for oracle tests (see below)
make build          # cross-compile DLL + launcher (x86_64-pc-windows-gnu)
make check          # verify valid PE DLL with DllMain
make test           # C tests (via wine) + Rust tests + mod loader Lua tests
make mod-loader-test # mod loader Lua tests (offline LuaJIT harness; no game/wine)
```
Build outputs land in `src/bin/`; cargo's artifacts in `src/target/`.
- **Windows native (MSVC):** `.\src\build.ps1 <target>` (PowerShell 5.1;
  mirrors the Makefile target-for-target — same names, same semantics).
  Toolchain: VS 2022 Build Tools + VCTools workload, Rust via rustup, LuaJIT
  via `winget install DEVCOM.LuaJIT`. See `src/README.md` → "Build + test
  (Windows native / MSVC)" for the target list + prereqs.
- **Oracle tests need the game.** `DARKTIDE_GAME_DIR` points at your Darktide
  install root so discovery can run against the
  real binary. The engine is build-agnostic (Tier-2 self-validation passes on
  any build; Tier-1 exact-match skips if the SHA differs from the pinned one);
  in CI (no game install) oracle tests skip cleanly. **If `DARKTIDE_GAME_DIR`
  is unset, ask the operator for it** — do not guess or hardcode it. To avoid
  re-typing it each session, drop `export DARKTIDE_GAME_DIR=...` into a shell
  file and `source` it. Keep that file **outside** the repo (e.g.
  `~/.config/darktide-mod-relay/env`); if you keep it inside the repo, it
  must be in `.gitignore` — never commit the game path or the game binary.
- **`test-hooks` feature** gates the debug panic-boundary symbol out of
  release builds. Tests use it: `cargo test --features test-hooks -p
  relay-discovery`. `make test` handles this; clippy too
  (`cargo clippy --all-targets --features test-hooks -- -D warnings`).
- **Launcher CLI** is flag-based (**flag > env var > default**; `--game-binary`
  is the only required flag; the shell DLL is hardcoded next to the launcher
  and self-locates the mod loader). `--mod-path` (env `RELAY_MOD_PATH`)
  is the user-controlled mod-path **boundary** — a directory that *contains*
  a `mods/` subdirectory (DMF + user mods live at `<mod_path>/mods/`); the
  loader derives `Mods._mod_root` as `<mod_path>/mods` and contains raw
  `Mods.lua.io` reads at `_mod_path`. The loader root is self-located by the
  shell
  from its own DLL path (`<dll-dir>/mod_loader/`, set as the internal
  `MOD_LOADER_DIR` — not an env var/flag). A bare `--` (end-of-options
  separator) forwards every token after it to the game verbatim, in order, as
  separate argv entries, appended after the quoted exe and CRT-quoted (ANSI
  only; capped at 32,767 chars); Relay's own flags must precede `--`, and a
  flag-looking token after `--` is a raw game arg. No `--` is the legacy
  exe-only launch. `--version` prints the build-injected product version (read
  from `.release-please-manifest.json` at build time) and exits — callers like
  Curator use it for version comparison. `--lua-logs` (env `RELAY_LUA_LOGS=1`,
  exact value `1` only; default off) is a value-less switch that tees Lua
  `print`/`__print` output into `relay.log` as `INFO lua-print:` lines (a tee,
  never a redirect — console stays authoritative); the launcher canonicalizes
  the child env to `1` or removes it. See
  `docs/architecture/MOD-RELAY.md` → `launcher/`
  for the full flag/env/default table + the env-var contract.
- **Shell log** is `relay.log`, structured + level-filtered via `RELAY_LOG_LEVEL`
  (default `info`; crank to `debug`/`trace` for verbose output); it carries the
  C-side shell + trampoline lines only. Each line is timestamped in **local
  time with an ISO-8601 UTC offset** that follows the system time zone (e.g.
  `2026-07-16T12:34:56-04:00`), and the worker logs a `launching <cmdline>`
  INFO line (the host process command line as the game sees it — the quoted exe
  + forwarded game args) right after the startup banner. By default the mod
  loader's Lua-side `print` lines (the `[mod_loader] …` lines), DMF, and mods go
  to Darktide's **console log** (`console-*.log`, at
  `%APPDATA%\Fatshark\Darktide\console_logs\` on Windows, or
  `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/`
  under Proton) — NOT to `relay.log` and NOT to the Proton `steam-$APPID.log`
  (Wine/Proton diagnostics only). With `--lua-logs`/`RELAY_LUA_LOGS=1` on,
  Relay additionally copies `print`/`__print` output into `relay.log` as
  `INFO lua-print:` lines (the console log stays complete/authoritative; it is a
  tee, not a redirect). `--log-level warn`/`error` filters the `INFO lua-print`
  lines out of `relay.log` while the console log is unaffected. See MOD-RELAY.md
  → Logging (native sink policy: 4096-byte input budget, 768-byte chunks,
  CR/LF/CRLF split, `\xNN` for controls/NUL/DEL, one truncation marker, no new
  hook — still exactly lua_newstate + lua_pcall).
- **Loader failure diagnostics** are in Darktide's console log. Relay disables
  a standalone outer entry after its first escaped lifecycle error; an escaped
  `dmf` outer boundary stops the current generation without attributing an
  inner culprit. Guarded in-game alerts repeat at a controlled cadence until a
  completed developer-mode hot reload or process exit. Cleanup is best effort;
  restart remains the safe recovery when side effects may survive.
- **CI** runs on PRs to `main` (`.github/workflows/pr.yml`: mingw Linux
  cross-compile + wine tests, and msvc Windows native). Pushes to `main` run
  the release pipeline (`.github/workflows/release-please.yml`: release-please
  versions + tags, then builds + attaches the Windows x64 runtime bundle to the
  release). Both gate on clippy + tests.
- **Release Please metadata invariant — do not “fix” the Cargo version.** The
  non-negotiable operational requirement is that a PR created or updated by
  Release Please **must not start `.github/workflows/pr.yml` at all**. Do not
  replace this with actor checks, skipped jobs, or approval workarounds: the
  workflow must be excluded at the `pull_request.paths-ignore` trigger. The
  product version (the Release Please manifest, changelog, Git tag, and GitHub
  release) is intentionally decoupled from the Cargo workspace/package version.
  The Rust crate has `publish = false`; an apparently stale Cargo version is not
  automatically a bug. `.release-please-config.json` deliberately uses the
  `simple` strategy, package path `src`, and **no** Cargo `extra-files`. The
  `rust` strategy previously failed on this virtual mixed-language workspace.
  Release Please bot PRs must therefore change only
  `.release-please-manifest.json` and `src/CHANGELOG.md`; those exact two files
  are ignored by `.github/workflows/pr.yml` so bot PRs do not enter the
  human-approval-required quality gate. Adding another generated file —
  especially `src/Cargo.toml` or `src/Cargo.lock` — breaks that invariant and
  triggers the PR workflow (`action_required`) for release PRs. A schema-valid
  Cargo-lock `extra-files` updater already failed to update the real generated
  release PR, so config/JSONPath simulation is not sufficient validation. Any
  future Cargo-version synchronization is a CI/architecture redesign: discuss
  it with the operator first, preserve CI for legitimate Cargo-only PRs, and
  verify the actual generated Release Please PR file list end-to-end. This
  invariant applies equally to stable and pre-release releases.
- **Legal notices ship in every distributable bundle.** `make build` stages
  the root `LICENSE` (Relay's GPL-3.0) + `THIRD_PARTY_NOTICES.md` (the notices
  for the statically-linked MinHook + Capstone dependencies) into `src/bin/`
  beside the executables; the release bundle zips that dir. Do not assemble or
  ship a runtime bundle without both files present. If a future bundle-assembly
  path (Makefile target, release workflow, or out-of-band packaging) is added,
  it must carry these forward.

## Key docs

- `docs/architecture/` — the production architecture (component model, the
  Hybrid, the seam, test strategy, build, launcher flow).
- `docs/reference/darktide/darktide-binary.md` — validated game-binary constraints.
- `docs/reference/community-tools/darktide-framework-analysis.md` — the existing
  modding ecosystem the runtime patch replaces.

## Conventions

- **Conventional Commits** (`type(scope): subject`); commit freely on feature
  branches. Branch + PR flow; no unreviewed merges to `main`.
- Don't commit secrets or the game binary.
- **Do not trust training data for version/library-specific APIs.** Before
  deciding an approach that relies on a specific API (Rust crate semantics
  across editions, MinHook, LuaJIT 2.1 behavior, PE/`.pdata` details), confirm
  the exact version in use and, if you are not current on it, read the current
  docs/source rather than relying on memory.
- **Discuss non-trivial or hacky approach decisions before implementing.** Do
  not delegate or commit a workaround without surfacing it first.
- **Do not commit a change as a "fix" before the operator verifies it.** Leave
  fixes uncommitted (or clearly WIP/pending) until the operator confirms; they
  test on their own machine.

## Naming convention

**Mod Relay** is the runtime's public name — keep it; don't rename it.
Use plain, descriptive names for new components/modules (Rust crates, C
modules, Lua modules, functions); the runtime's Lua loader is `mod_loader`
(descriptive), not a themed name. Docs and code read as plain engineering
documentation.

The brand hierarchy:
- **Mod** = the suite/brand — the umbrella over the operator's
  mod-management tools.
- **Mod Relay** (short form **"Relay"**) = the product/toolset in *this*
  repo (launcher + shell + mod loader).
- **Mod Curator (Darktide Mod Manager)** (short form **"Curator"**) =
  the operator's separate mod-manager product (different repo); it manages mods
  and leverages the Relay runtime to run them.

Identifier namespacing follows ownership: Relay-owned concerns (its log, its
config, the game binary, the Steam app id, the mod path, the shared discovery
library, its internal Lua contract, the launcher↔shell handshake, its CI) are
prefixed `RELAY_*` / `relay_*`. External products that consume the runtime
(e.g., Mod Curator) interact via the documented flags/env vars and the staged
Lua loader, not via internal prefix conventions.

- **Folders/filenames:** lowercase (`src/mod_loader/init.lua`).
- **Prose/docs:** first mention in a doc is "Mod Relay (runtime)",
  thereafter "the Relay runtime" / "Relay". The Lua loader inside Relay is "the
  mod loader" (prose) / `mod_loader` (code/dir references).
- Don't obscure — names should be descriptive and accessible, not cryptic.

## README pattern

Docs follow a two-tier README pattern:

- **Root `README.md`** — audience is the **general / end user**: what
  Mod Relay is and how to get it running. **No build internals.**
- **Component-dir `README.md`** (`src/README.md`) — audience is
  **developers / power users**: build instructions, sub-component details,
  testing, links to the architecture specs.

The **root README links to** the component README — it does **not** duplicate
its content. When a component gets (or changes) a README, ensure the root links
to it and that the split holds (user-facing up top, dev detail under the
component).

## Before opening a PR — keep docs current

Docs must reflect the code in the PR. Before opening a PR for any change that
affects repo structure, build, architecture, or ops, update:
- **`AGENTS.md`** (this file) — directory structure, ops, architecture
  pointers — to reflect the change.
- **`README.md`** (root) — if the **user-facing** structure/status changed.
  Keep it user-facing (see [README pattern](#readme-pattern)); dev/build detail
  goes in `src/README.md`, and the root must link to it.
- **`src/README.md`** — for build/dev detail under the component; ensure the
  root links to it.
- **`docs/architecture/`** for any architecture change.
- **`docs/reference/`** — categorized: `darktide/` (game-binary facts),
  `community-tools/` (existing modding ecosystem).

Then ensure `make build/check/test` + clippy pass. **Outdated docs in a PR are
a review blocker** — including this file.
