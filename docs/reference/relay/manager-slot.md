# Mod Relay manager slot

This document defines the normative contract for the **manager slot** — the
single object Relay's mod loader instantiates to own mod discovery, ordering,
loading, and lifecycle. Relay ships a **built-in** manager (the `mods.lst`
scan/load driver); `--mod-manager` / `RELAY_MOD_MANAGER` selects an
**alternate mod manager** file to occupy the slot instead. The implementation
architecture lives in `docs/architecture/MOD_LOADER-DMF.md` (the loader and
its bootstrap steps) and `docs/architecture/MOD-RELAY.md` (the launcher + the
shell/trampoline plumbing).

## Scope

The relationship is a **one-way community contract**, the same posture Relay
takes toward DMF: Relay provides the surfaces a manager expects — the `Mods`
file/io surface, the class registry, the print surfaces, the `Managers.mod`
publication, and the per-frame/state-change drive — and knows nothing about
who occupies the slot. An alternate manager replaces Relay's built-in
load/lifecycle driver wholesale; everything the built-in does beyond the
contract below is its own policy, which Relay neither performs nor polices
under an alternate (see [Not provided](#not-provided)).

## Selection

| Setting | Flag | Env var | Default |
| --- | --- | --- | --- |
| Alternate mod manager | `--mod-manager <file>` | `RELAY_MOD_MANAGER` | unset — the built-in manager loads, with behavior identical to a launch without the feature |

- **flag > env var > unset.** When both are set, the flag wins and the env
  var is ignored.
- **The path is used verbatim.** No canonicalization or absolutization. A
  relative path resolves against the game process CWD when the file is
  opened (the game's `binaries\` directory) — an absolute path is the robust
  form.
- **The value is configuration, not an API.** The launcher publishes
  `RELAY_MOD_MANAGER` into the game process env only when configured; the
  shell's trampoline bakes it into a one-shot internal Lua global; the
  loader entry snapshots it privately and retires the global before any mod
  code runs. The manager file never sees the flag, the env var, or the
  global.
- **`--mod-path` still selects where mods live.** `Mods.file.*` operations
  root at the mod root (`<mod_path>/mods`, from `--mod-path` /
  `RELAY_MOD_PATH`); `--mod-manager` only replaces the manager file. An
  alternate installed inside the mod tree (e.g. at
  `<mod_path>/mods/base/mod_manager.lua`) is selected by its own path and
  loads its mods through the same rooted surface as everyone else. With
  `--mod-path` unset the mod root is empty and `Mods.file.*` paths resolve
  as-is.

## Failure policy

A configured alternate is a hard operator commitment: Relay never silently
falls back to the built-in manager and never continues a managerless game.

1. **Launcher pre-flight (refusal).** Before any process is created, the
   launcher verifies the configured target exists as a regular file. A
   missing target or a directory produces a stderr diagnostic naming the
   path and its source (`--mod-manager` or `env RELAY_MOD_MANAGER`), and the
   launcher exits with status 2 — the game is not launched. An env
   `RELAY_MOD_MANAGER` too long for the launcher's buffer (> 1023 chars) is
   refused the same way (stderr diagnostic, exit 2) — an oversized value is
   never silently degraded to the built-in manager.
2. **Shell backstop (fatal, pre-resume).** The injected shell reads
   `RELAY_MOD_MANAGER` while staging the trampoline. A set-but-unreadable,
   overlong (≥ 1024 chars), or control-character-bearing value (a control
   byte cannot be escaped into the staged chunk's Lua string literal) is
   fatal: the shell logs at `ERROR` and terminates the process while the
   launcher still holds the main thread suspended, so the game never resumes
   half-configured. This is the authoritative check for direct injection
   (no launcher in the path).
3. **In-engine (retry, then hard exit).** The manager chunk is loaded from
   the configured path by the loader's bootstrap retry loop. Each distinct
   failure mode — the file cannot be opened, parsed, or run; the chunk
   returns something other than a table; `:new()` raises or returns no
   instance; the loader-internal chunk seam is unavailable or raises — is
   logged once (the configured path is in the message) and retried on every
   bootstrap pass **while the engine is not yet ready** (the loader's
   manager-independent engine wraps are not all installed). Once the engine
   is ready, a failure is permanent: Relay logs a final `ERROR` naming the
   path, the failure, and the policy, then terminates the process (via FFI
   `ExitProcess(1)`, with an `os.exit(1)` fallback). The game does not
   continue without the configured manager.

When an alternate manager is configured, launch with `--log-lua`: the final
hard-exit `ERROR` is a Lua-side line destined for Darktide's console log,
whose buffers an immediate mid-update exit can discard — the tee copies it
into `relay.log` (the C-side sink flushes per line), so the diagnostic
survives the exit.

Two residual corners bound the "never" above; both log loudly and neither is
reachable in practice. If the manager-independent engine wraps can never
install (the engine contract itself is broken — `StateGame` /
`GameStateMachine` absent), the engine-ready gate is never satisfied and
evaluation stops with the game running managerless — the same stall class as
the built-in manager's pre-existing behavior. And if no exit surface is
usable at all (neither FFI nor `os.exit`), the final step raises instead of
exiting: the boot wrapper contains the raise, the once-guard silences
further failures, and the game continues managerless after that one log.

## The manager-facing contract

**Loading.** The configured file is opened at its exact path with the
engine's raw `io` (verbatim — neither loader-rooted nor mod-root rooted),
compiled with `loadstring`, and run in the loader's shared global
environment. It runs during engine boot, from the loader's bootstrap retry
loop, after the engine's global `class` is available; boot-complete globals
may not exist yet, so defer engine access to `update()` — the built-in
manager defers its entire load pass to the first update tick for exactly
this reason.

**The contract:**

- The chunk **must return a table** — the manager class, created with the
  engine's global `class(...)` (e.g. `local Manager = class("ModManager")
  … return Manager`). Any other return value is a permanent failure (see
  [Failure policy](#failure-policy)).
- The class must be **instantiable with `:new()` and no arguments**, and the
  call must return a non-nil instance.
- The chassis publishes that instance as **`Managers.mod`**.

**The chassis calls exactly two members** on the instance — no others, ever:

| Call | When | Containment |
| --- | --- | --- |
| `update(dt)` | every frame, before the engine's own `StateGame` update | pcall-contained; an error is logged (throttled, see note below) and the frame proceeds |
| `on_game_state_changed(status, state_name, state_object)` | on every game-state transition: `"exit"` before it and `"enter"` after it, plus one final `"exit"` for the active state before the state machine is destroyed | pcall-contained; an error is logged (throttled, see note below) and the transition proceeds |

`on_game_state_changed` dispatches are deduplicated per state object: a
state that already received its exit via the transition dispatch is not
dispatched again at destruction, and vice versa — exactly one exit per state
object.

**Throttled containment logging.** Contained errors from these two calls are
logged through the chassis's throttled containment logging: the first
occurrence of a given call site + error text logs immediately, and
recurrences within a 10-second window are counted silently — surfacing as
one error line per window with a suppressed-count suffix, so a per-frame
raise stays visible at a bounded cadence instead of flooding the log (and is
never swallowed entirely). Without a usable `Mods.lua.os.time` clock the
chassis logs every occurrence.

**Ownership.** The manager owns mod discovery, ordering, loading, and
failure handling, however it sees fit. `mods.lst` (the order file the
built-in manager reads) is the built-in's convention, **not** a chassis
requirement. Conversely, everything the built-in manager does beyond the
two calls above is its own policy — the chassis neither performs nor
polices it under an alternate.

**Optional members the chassis never calls.** Members like
`all_mods_loaded`, `destroy`, or `developer_mode_enabled` exist for other
consumers (DMF reads manager fields; community extensions call manager
methods; the manager's own loop may use them). Defining them is fine;
expecting the chassis to call them is not.

**Chassis duties (run under any manager).** Around those two calls, the
loader performs the manager-agnostic startup duties exactly once per
process, regardless of who occupies the slot: it publishes `Managers.mod`;
it restores `Managers.mod._settings` from the persisted
`Application.user_setting("mod_manager_settings")` **only when the manager
left it nil** (a manager that sets its own `_settings` keeps it,
identity-preserved; a missing/invalid persisted value falls back to
`{ developer_mode = false }`); it registers the DMF IO observer (the eight
`DMFMod:io_*` adaptations — active whenever a stock DMF surfaces, whichever
manager loaded it); and it publishes the process-lifetime
`ModRelay:Version` Crashify property (attempted at startup, retried until
it succeeds).

**If the manager loads DMF.** DMF is just a mod, but it reads three fields
off `Managers.mod` (`_mods[_mod_load_index].{id,name,handle}`,
`_state == "done"`, and `_settings.developer_mode`). A manager that drives
DMF must provide them; the exact read sites are pinned in
`docs/architecture/MOD_LOADER-DMF.md` → "The `Managers.mod` shape contract
DMF requires".

## Provided environment

The chunk runs in the shared global environment: every engine global plus
the `Mods` surface Relay builds at pcall#1. Relay-owned surfaces:

| Surface | What it is |
| --- | --- |
| `class(...)` / `CLASS` | the engine's class system, wrapped: every `class()` result is recorded in `CLASS` and mirrored to `_G[name]` (rawget-guarded) — the handle mods expect |
| `Mods.file.*` | the mod-root-rooted file exec/read family (below) |
| `Mods.lua.io` / `.loadstring` / `.os` / `.ffi` | the engine's captured `io` (with the rooting wrappers below), `loadstring`, `os`, and the LuaJIT FFI module |
| `Mods.original_require` / `Mods.require_store` | the engine's real `require` (captured before Relay wraps the global) + the identity-deduped store of required table results (what DMF's `hook_require` builds on) |
| `print` / `__print` | the engine print surfaces. A manager's `print` output lands in Darktide's console log (the authoritative Lua destination); with `--log-lua` it is additionally copied into `relay.log` (see [`logging.md`](logging.md)) |

Engine globals (`table` augmentation like `table.contains`/`table.find`,
`Keyboard`, `Application`, `Crashify`, `Managers`, …) are engine-provided —
Relay publishes none of them, and their availability at chunk-run time is an
engine property, not a Relay guarantee (defer to `update()`).

**`Mods.file.*` — the file exec family.** All eight operations (`dofile`,
`dofile_unsafe`, `exec`, `exec_unsafe`, `exec_with_return`,
`exec_unsafe_with_return`, `read_content`, `read_content_to_table`) accept
two argument shapes:

- **path form:** `(path, args?)` — `path` is mod-root-relative; `args` (any
  non-string type) is the chunk argument. Reads ignore it.
- **join form:** `(name, ext)` → `name.ext`, or `(dir, name, ext[, args])`
  → `dir/name.ext` — a string second argument selects it. `ext` is bare
  (`"mod"`, not `".mod"`); the join supplies the dot. Each component is
  validated as a single path segment: a non-empty string with no separator,
  no `..`, no NUL, and no `:`.

The joined (or given) path resolves against the mod root; an extensionless
basename gets `.lua` appended (a join-form result always carries its
extension). Safe variants (`dofile`, `exec`, `exec_with_return`,
`read_content`, `read_content_to_table`) return the chunk value / content /
`true`, or `false` on failure (the dofile-shaped ones also return a reason);
unsafe variants (`*_unsafe`) propagate compile/runtime failures.
`read_content_to_table` returns a trimmed line list (blank and `--` comment
lines skipped).

**`Mods.lua.io.open` / `io.lines` — mod-root rooting with absolute
passthrough.** A relative path resolves against the mod root; an absolute
path (drive-qualified, root-anchored, or UNC) is forwarded **verbatim** — no
rooting, no normalization, the caller's separators preserved. The surface is
a routing shim, not a sandbox: in-process Lua can reach any path.

**`Mods.lua.io.popen` — CWD anchoring.** A string command is prefixed with
`cd /d "<mod root>" && ` so commands using relative paths resolve against
the mods directory. The `cd` runs only in the spawned `cmd.exe` child — the
parent Lua CWD is never touched. Non-string commands pass through.

## Not provided

Everything below is built-in-manager policy. Under an alternate, Relay does
**not** provide:

- **Hot-reload machinery** — generations, the two-frame teardown/replacement
  sequencing, the LEFT Ctrl+Shift+R gesture, and the `request_reload` seam.
- **Failure containment** — the nil/table-only run-result validation, the
  one-strike outer lifecycle containment (standalone disable vs
  framework-boundary generation stop), guarded engine-event alerts, and the
  exactly-once cleanup driving.
- **Per-mod Crashify publication** — `Mod:<name>` properties are the
  built-in's; under an alternate only the process-lifetime
  `ModRelay:Version` is published.
- **Load-order services** — discovery, ordering, dependency resolution, and
  entry validation are the manager's own concern.

An alternate that brings its own reload or containment is self-contained:
the chassis calls the two members for the process lifetime and never
re-instantiates or replaces the manager.

## Known consumer note (AML)

**AML — Auto Mod Loading and Ordering** (Nexus Mods Darktide mod 246) is the
known occupant of this slot. It installs as `base/`, placing its manager at
`<mod_path>/mods/base/mod_manager.lua`. Verified by behavioral analysis of
the distributed artifact only — no code reuse — and no claims beyond:

- the file is a chunk that builds its manager with `class("ModManager")`
  and returns it;
- it preloads mod metadata via the join form
  `Mods.file.exec_with_return(folder, folder, "mod")`;
- it drives its mods from `update(dt)` and implements
  `on_game_state_changed(status, state_name, state_object)`.

## Related docs

- `docs/architecture/MOD_LOADER-DMF.md` — the loader architecture: the
  bootstrap steps (manager-slot selection, instantiation, the chassis
  duties), the `Mods` surface detail, and the DMF shape contract.
- `docs/architecture/MOD-RELAY.md` — the launcher flag/env plumbing and the
  env-var contract.
- [`shell.md`](shell.md) — the trampoline-baked globals, including the
  `RELAY_MOD_MANAGER` fatal backstop.
- [`logging.md`](logging.md) — the logging destinations, including the
  optional Lua print tee.
