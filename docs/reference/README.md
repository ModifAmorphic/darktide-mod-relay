# Reference — living

Reference material organized by category. Each document records current
validated facts or contracts.

- [`relay/`](relay/) — normative Mod Relay-owned contracts (the runtime's
  observable behavior): [`relay/logging.md`](relay/logging.md) — logging
  destinations, the `relay.log` line/lifecycle contract, and the optional Lua
  print tee; [`relay/shell.md`](relay/shell.md) — the injected shell's
  contracts (the two required hooks, the pcall#1 trampoline game-safety
  invariants, the trampoline-baked roots, the deliberately-not-hooked
  discovery anchor);
  [`relay/manager-slot.md`](relay/manager-slot.md) — the manager-slot
  contract (selecting an alternate mod manager, the failure policy, and the
  environment provided to the occupant); and
  [`relay/relay-stack-analysis.md`](relay/relay-stack-analysis.md) — a
  descriptive (not normative) walkthrough of the full Relay stack, mirroring
  the community-toolchain reference's shape; and
  [`relay/load-phases.md`](relay/load-phases.md) — the phase-scheduling
  contract (phase 0 = the anchor tick; a mod scheduled at phase P loads
  exactly P engine updates after it; the positional `mods.lst` default —
  entry i at phase i, one entry per manager tick — is implemented; authored
  multi-mod-per-phase schedules are future work, carrier shape TBD).
- [`darktide/`](darktide/) — validated facts about the Darktide engine binary
  (LuaJIT, `lua_State` offsets, sandboxed `_G`, discovery methodology).
  Properties of the game, independent of any implementation.
- [`community-tools/`](community-tools/) — the existing Darktide modding
  ecosystem (DMF + dtkit-patch toolchain) that the Mod Relay runtime
  patch replaces: the
  [toolchain/framework reference](community-tools/darktide-framework-analysis.md)
  and its [version-pinned verification record](community-tools/analysis-verification.md).
