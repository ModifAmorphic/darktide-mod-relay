# Darktide binary — validated constraints

Immutable technical facts about the Darktide engine binary that any
implementation must respect. These are properties of the game, not of any
implementation.

## LuaJIT

- Version: LuaJIT 2.1, statically linked into `Darktide.exe` (no `lua51.dll`);
  functions are in `.text`, not exported.
- Mode: non-GC64 (LJ_64, 32-bit MRefs).

## `lua_State` field offsets (LJ_64 non-GC64)

| Offset | Field | Type |
|--------|-------|------|
| `0x08` | `glref` (global_State*) | 4-byte MRef |
| `0x10` | `base` (TValue*) | 8-byte |
| `0x18` | `top` (TValue*) | 8-byte |
| `0x24` | `stack` (TValue*) | 4-byte MRef |
| `0x38` | `stacksize` | integer |

Stack slot size: **8 bytes** (TValue). `lua_gettop` = `(top - base) >> 3`.

## Globals lifecycle (validated)

The engine's script init calls `luaL_openlibs`, which registers the **full**
Lua standard library into `_G` (`io`, `loadstring`, `require`, `print`, `table`,
`string`, `math`, …). At that point:

- `_G` carries the complete stdlib. A chunk whose env is the globals table
  sees `io`, `loadstring`, etc.
- A chunk's env **is** the globals table at `lua_pcall` #1 — there is **no**
  `setfenv` sandbox for chunks run at pcall#1. (`setfenv` exists in the engine,
  but it is not used to sandbox the pcall#1 chunk.)

Around early boot — between `lua_pcall` #1 and ~#10 — the engine **removes**
`io` and `loadstring` from `_G` (and replaces `_G.print`, `_G.require`,
`_G.dofile`, `_G.loadfile`, `_G.load` with engine wrappers). After that window
an injected chunk no longer sees `io`/`loadstring` in its env.

**Implication for injection:** the one-shot trampoline runs on the FIRST
`lua_pcall` (pcall #1), BEFORE the original pcall, so it executes while
`io`/`loadstring` are still in globals. It `io.open`s the staged entry, reads
it, `loadstring`s it, and runs it — capturing those facilities (and the others
listed above) into the mod loader before the engine strips them. This is
one-shot (no retry, no polling); missing the pcall#1 window means missing
`io`/`loadstring`, so the injection timing is the load-bearing constraint.

**Never re-call `luaL_openlibs`.** It is destructive — it overwrites the
engine's custom wrappers and crashes the game. The trampoline captures the
already-registered facilities instead of re-registering them. Dependencies the
loader must register as C functions go in via `lua_pushcclosure` +
`lua_setfield(L, LUA_GLOBALSINDEX, name)` — the same mechanism the engine uses.

## Function discovery

16 LuaJIT/engine functions confirmed at runtime, discovered via:
- **String-anchor** — `stingray::` names → LEA xref → `.pdata` function
  (engine functions).
- **Source-pattern** — match compiled bodies against LuaJIT 2.1 source (the C
  API cluster).
- `.pdata` gap handling — CFG thunks (`E9 rel32`), leaf functions, import
  thunks (`FF 25`).

Build-agnostic: the engine finds all 16 at shifted RVAs across binary versions
(validated — a newer build shifted the cluster uniformly +0xf0680).

A small set of additional LuaJIT C-API + engine anchors (e.g. `lua_getfield`,
`lua_getfenv`/`lua_setfenv`, the `lua_resource::bytecode` bundle-script
loader) are discovered by the same methods and carried in the address table as
validated outputs (ABI-stable).

## Key constants

- `LUA_GLOBALSINDEX` = `-10002`; `LUA_REGISTRYINDEX` = `-10000`.
- `lua_pushcfunction(L, f)` → `lua_pushcclosure(L, f, 0)`; `lua_setglobal(L,
  name)` → `lua_setfield(L, LUA_GLOBALSINDEX, name)` (macros, not real fns).
- `sizeof(GCstr)` = `0x14`; `strdata(s)` = `(char*)s + 0x14`.

## Pinned reference binary

SHA-256 `132eed5fe58515774a41199269dd240ef6092f84b1efc8ad4a28e23ea6791661`
(the pinned reference build; the engine is build-agnostic, so addresses shift
uniformly across builds).

## Command-line arguments

Darktide.exe accepts **ASCII** `--flag <value>` tokens on its command line; the
engine tokenizes them like a standard C `argv`. The stock Fatshark launcher /
Steam bypass command is one known instance of this — it runs the engine with
flags that point it at its bundle, ini, and backend services:

```
<exe> --bundle-dir ../bundle --ini settings \
      --backend-auth-service-url <https URL> \
      --backend-title-service-url <https URL>
```

Those values are each ASCII: a **relative path** (`--bundle-dir ../bundle`), an
**ini-section identifier** (`--ini settings`), or an **HTTPS URL**
(`--backend-auth-service-url`, `--backend-title-service-url`). This is a known
instance of the engine's general `--flag <value>` parsing, **not** an exhaustive
vocabulary: Relay launches `Darktide.exe` directly and works without any of
these flags, so what a caller forwards is whatever it chooses to supply (e.g. a
`--lua-heap-mb-size`-style tuning flag). There is **no known Darktide argument
that accepts a non-ANSI value.** This is the grounding that lets the launcher
forward arguments via `CreateProcessA` (ANSI / the active code page) rather than
`CreateProcessW`: real-world Darktide command lines are ASCII, so the ANSI path
is lossless. If a non-ANSI argument is ever introduced, the launcher must widen
to `CreateProcessW` (a separate change).

- **Source:** PCGamingWiki, "Warhammer 40,000: Darktide", rev 2026-04-26,
  "Issues fixed → Bypass launcher" (the documented stock-launcher bypass
  command line).
- **Launcher impact:** Mod Relay forwards a caller-supplied argument list
  via the end-of-options `--` separator — every token after `--` is appended
  after the quoted exe, in order, rendered with MSVC CRT quoting; the full line
  is capped at 32,767 chars (`RELAY_CMDLINE_MAX`, the `CreateProcessA` ceiling).
  See `docs/architecture/MOD-RELAY.md` → `launcher/`.
