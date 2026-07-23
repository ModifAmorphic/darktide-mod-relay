# Mod Relay logging

This document defines the operator-visible logging contract for Mod Relay: log
destinations, configuration, line format, the optional Lua print tee, and
failure behavior. The implementation architecture lives in
`docs/architecture/MOD-RELAY.md` → Logging and
`docs/architecture/MOD_LOADER-DMF.md` → Lua print tee.

## Scope

Two things are documented here:

1. The logging **destinations** Relay writes to, and which output goes where.
2. The optional **Lua print tee** (`--lua-logs` / `RELAY_LUA_LOGS=1`) — a
   best-effort copy of calls through the wrapped global `print` / `__print`
   surfaces into `relay.log`.

## Destinations

| Destination | Contents | Set by |
| --- | --- | --- |
| **`relay.log`** | The C-side shell + trampoline lines (discovery, hook arming, startup diagnostics, and the one-shot trampoline's status/failure diagnostics). When the Lua print tee is enabled, also structured `INFO  lua-print:` copies of captured Lua print output. Every emitted line is also sent to `OutputDebugString`. | `--log-file` / `RELAY_LOG_FILE`. Default `<launcher-dir>\relay.log`. |
| **Darktide `console-*.log`** | The authoritative engine Lua print destination: the mod loader's `[mod_loader] …` lines, DMF, and mods. Relay never redirects or suppresses it. Windows: `%APPDATA%\Fatshark\Darktide\console_logs\console-*.log`. Proton: `<compatdata>/pfx/drive_c/users/steamuser/AppData/Roaming/Fatshark/Darktide/console_logs/console-*.log`. | Darktide itself. |
| **Proton `steam-$APPID.log`** | Wine/Proton diagnostics only. It does not carry Darktide Lua output. | Proton (`PROTON_LOG=1`). |

## Configuration contract

Every setting follows **flag > env var > default**.

| Setting | Flag | Env var | Default | Notes |
| --- | --- | --- | --- | --- |
| Log file | `--log-file <path>` | `RELAY_LOG_FILE` | `<launcher-dir>\relay.log` | The launcher resolves this and publishes it into the child env, so the shell normally opens the launcher-dir path. The shell itself opens `RELAY_LOG_FILE` when set; if a process is injected directly without the launcher (no env), it falls back to beside the game exe, then to a relative `relay.log`. |
| Log level | `--log-level <level>` | `RELAY_LOG_LEVEL` | `info` | One of `error`, `warn`, `info`, `debug`, `trace`. Matched case-insensitively in the shell. Unset, oversized, or an unknown value resolves to `info`. |
| Lua print tee | `--lua-logs` | `RELAY_LUA_LOGS=1` | off | A value-less switch. Only the exact env value `1` enables; every other value (unset, empty, `0`, `true`, whitespace, oversized) is off. Recognized only before the `--` end-of-options separator; after `--` it is a raw game argument. The launcher canonicalizes the child env to `1` when enabled and **removes** it when disabled, so a stale parent value cannot leak in as a non-`1`. A process injected directly without the launcher may set `RELAY_LUA_LOGS=1` itself — that is the external non-launcher contract. |

## `relay.log` line and lifecycle contract

Each physical line has the form:

```text
<local-timestamp+UTC-offset> <LEVEL> <component>: <message>
```

For example:

```text
2026-07-16T12:34:56-04:00 INFO  trampoline: @ pcall#1: OK
2026-07-16T12:34:56-04:00 INFO  lua-print: [mod_loader] loaded at pcall#1
```

- **Timestamp.** Local time with an ISO-8601 UTC offset that follows the
  system time zone (`YYYY-MM-DDThh:mm:ss±HH:MM`). UTC itself shows `+00:00`;
  there is no `Z` special case.
- **Level.** The level name in a fixed-width uppercase column (`ERROR`,
  `WARN`, `INFO`, `DEBUG`, `TRACE`).
- **Component + message.** A short component identifier (`shell`,
  `trampoline`, `discovery`, `lua-print`, …) followed by the message.
- **Fresh file per game process.** The shell truncates the file when it opens
  it. There is no append or rotation across runs; each game launch starts a new
  `relay.log`.
- **Level filter before emission.** Lines below the configured logging
  threshold are not emitted.
- **Serialized physical-line writes.** Complete physical-line writes are
  serialized so shell-thread and Lua-thread (tee) lines never interleave
  mid-line.
- **Startup line.** Right after the startup banner the worker logs a
  `launching <cmdline>` INFO line — the host-process command line as the game
  sees it (the quoted exe + the forwarded game arguments).
- **Trampoline diagnostics.** The one-shot trampoline normally logs `OK`,
  `FAIL`, or `SKIPPED` as a single `@ pcall#1:` line. If loading or running the
  staged chunk fails before it can return a status, Relay emits explicit
  `CHUNK LOAD FAILED` or `CHUNK PCALL FAILED` error lines instead. These
  diagnostics are the reliable bootstrap validation.

`relay.log` is diagnostic data, not a privacy-filtered report. It can contain
the full game command line and, with the Lua print tee enabled, arbitrary game,
framework, and mod text. That output can include account, machine, character,
path, or profile identifiers. Review the file before sharing it.

## Lua print tee behavior

The tee is a copy, never a redirect. The engine's own `print` / `__print`
call runs first and remains authoritative for its console output; the tee only
adds `relay.log` copies of what traverses the wrapped surfaces.

- **Installed once per process**, at pcall#1, before Relay modules, DMF, or
  user mods load. It does not stack across hot reload (the entry never re-runs
  on reload), and a partial/repeated entry cannot stack a second wrapper.
- **Original call semantics remain authoritative.** Each wrapper forwards the
  original arguments unchanged and calls the original directly. Original
  errors propagate without replacement, and original return values and their
  exact cardinality are preserved. Rendering and the relay copy happen only
  after a successful original call.
- **A mod that later replaces global `print` wins.** The wrapper does not
  re-assert itself over a replacement; calls through the replacement are not
  copied. (`__print` retains the installed wrapper only if the mod did not
  replace it too.)
- **Captured:** calls through the global `print` and `__print` made after the
  wrapper installs at pcall#1 — Relay loader output, plus any DMF/mod path
  whose runtime ultimately calls one of those wrapped globals.
- **Not captured:** a `print` / `__print` reference captured before Relay
  wraps the globals; DMF/mod APIs that bypass those globals; native, engine,
  Wine, or Proton output; or lines that reach `console-*.log` by any other
  path. DMF `mod:info` / `mod:warning` / `mod:error` coverage depends on
  whether their runtime path calls the wrapped globals — observed, not
  guaranteed.
- **No console-log ingestion.** Relay does not tail, parse, or merge
  `console-*.log`; copies are made in-process only when a call crosses a
  wrapped print surface.
- **No caller identity.** Relay does not identify which game script, Relay
  module, DMF module, or user mod called `print`. It adds no source file, line
  number, or mod name; the printed text may identify itself, but Relay does not
  supply that metadata. The component is always `lua-print`, and the message is
  only the rendered argument list.
- **All copied lines are `INFO`.** `print` / `__print` carry no severity
  metadata, and Relay does **not** infer severity from text prefixes — a line
  whose text begins `error:`, `[WARN]`, etc. is still copied at `INFO`. As a
  consequence, `--log-level warn` or `error` filters the copied lines out of
  `relay.log` while the console log is unaffected.
- **Not a public mod logging API**, and it does not wrap DMF logging methods.
  There is no `Mods.log` / `Mods.message` surface; the tee is runtime-private
  plumbing.

## Argument rendering (the observable relay copy)

When a captured call succeeds, the tee renders its argument list into one
string and hands it to the native sink. The relay copy is a **separate
render** from whatever the engine's own `print` wrote to the console — they
agree for simple values and may differ for complex ones.

| Argument type | Lua render before native line handling |
| --- | --- |
| string | unchanged, byte-for-byte |
| number | ordinary textual form (`tostring`) |
| boolean | `true` / `false` |
| `nil` | `nil` |
| table | `<table>` |
| function | `<function>` |
| thread | `<thread>` |
| cdata (LuaJIT) | `<cdata>` |
| userdata | `<userdata>` |

- Arguments are **joined with a tab byte** (`0x09`). The native sanitizer
  renders that tab as the 4-byte escape `\x09`, so multi-argument copies
  appear tab-separated by that escape in `relay.log`.
- **Complex values use stable placeholders.** The relay renderer never invokes
  `__tostring`; the original print surface remains solely responsible for its
  console rendering.
- **Multiline content is handed to the native sink intact.** Lua performs no
  splitting; the native sink owns CR/LF/CRLF handling (below).
- **An empty argument list produces no relay line.**
- The **console rendering** remains whatever the original engine `print` does,
  and may differ from the relay copy for complex values.

## Native line safety

Every captured string is processed through a pure, bounded sanitizer before
it reaches the structured logger. The guarantees:

- **Explicit byte length** is used throughout; embedded NUL is data, not a
  terminator.
- **4096-byte input budget per captured call.** The budget applies to the
  joined, rendered argument string before control-byte escaping. Bytes past the
  budget are dropped after exactly **one** trailing truncation-marker line,
  whose text is exactly `[input exceeded 4096-byte budget; truncated]`.
- **768-byte output chunks.** The chunk limit applies after control-byte
  escaping. A physical line longer than this is emitted as consecutive
  width-bounded chunks, each via a separate structured line (so every chunk
  gets its own timestamp/level/component prefix).
- **CR, LF, and CRLF each end a line**; CRLF is one break (not two). Empty
  resulting lines are emitted faithfully (a bare `\n` yields one empty line).
- **`\xNN` escaping** (lowercase hex) for C0 control bytes `0x00`–`0x1f`
  (except the line terminators above) and for `0x7f` (DEL). Embedded NUL
  therefore cannot terminate a buffer, and no control byte can forge line
  structure.
- **`%` (`0x25`) and bytes `>= 0x80` pass through unchanged** as data. Percent
  signs are never interpreted as formatting directives.
- **"UTF-8 preserved" means raw high bytes are passed through**, not validated
  or transcoded. A malformed byte sequence is emitted as-is; Relay does no
  UTF-8 decoding. A 768-byte chunk boundary can split a multi-byte sequence
  across two physical `relay.log` lines.
- **Bounded native processing.** The sanitizer's memory use does not grow in
  proportion to the input string.
- **Every emitted physical line gets the structured prefix.**

## Failure behavior and troubleshooting

Tee failures omit individual relay copies or leave the run console-only. They
never block the original print, mod loading, or the game.

- **Disabled (the default).** No wrapper is installed, there is no per-print
  tee cost, and there are no `lua-print` lines in `relay.log`.
- **Log file cannot be opened.** Relay continues and sends emitted lines to
  `OutputDebugString`; it does not retry a different file path after the
  selected path fails to open.
- **`--log-level warn`/`error` with the tee enabled.** The wrapper and native
  sanitizer still process captured calls, but the resulting `INFO lua-print`
  lines are filtered before emission. The console log is unaffected.
- **Bypassed path.** A `print` reference captured before Relay wraps the
  globals, or a call through a mod's replacement `print`, is not copied.
- **Sink registration unavailable.** If the tee is enabled but a required
  C-API registration pointer is unavailable, the shell records exactly one
  `WARN` event and continues console-only for that run. The event is subject to
  `RELAY_LOG_LEVEL` like any other warning (`error` filters it). Mod loading is
  not blocked.
- **Malformed callback invocation.** A native callback call with the wrong
  argument count or a non-string argument is ignored; no error is raised into
  Lua.
- **Capture/render/sink failures are contained.** After a successful original
  `print`, any failure in the render or sink step is swallowed; it never
  changes the original call's results, return cardinality, or error behavior.
- **Log growth.** `relay.log` starts fresh each launch, but while the tee is
  enabled during one run it duplicates print traffic at `INFO` and can grow
  quickly. Disable the tee, or set the level to `warn`/`error`, to keep
  `relay.log` to the shell/trampoline lines.

## Related docs and verification

- `docs/architecture/MOD-RELAY.md` → Logging — the native-side mechanism: the
  structured logger, the private C callback registration, the no-new-hook
  invariant, and the sanitizer policy.
- `docs/architecture/MOD_LOADER-DMF.md` → Lua print tee — the wrapper
  architecture: capture/retirement of the private sink, original-authoritative
  ordering, result-cardinality preservation, and the process-lifetime
  non-stacking contract.
- `src/mod_loader/tests/probes/observational/lua_logs_probe/` — a non-shipped,
  read-only observational probe an operator can stage into the real game to
  confirm what the tee captures, how it sanitizes, and that it does not stack.
  It is an optional live diagnostic, not part of the architecture or the
  shipped runtime; the offline LuaJIT harness only structurally validates it.
