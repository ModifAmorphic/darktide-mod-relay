# Reference — living

Reference material organized by category. Each document records current
validated facts or contracts.

- [`relay/`](relay/) — normative Mod Relay-owned contracts (the runtime's
  observable behavior): [`relay/logging.md`](relay/logging.md) — logging
  destinations, the `relay.log` line/lifecycle contract, and the optional Lua
  print tee.
- [`darktide/`](darktide/) — validated facts about the Darktide engine binary
  (LuaJIT, `lua_State` offsets, sandboxed `_G`, discovery methodology).
  Properties of the game, independent of any implementation.
- [`community-tools/`](community-tools/) — the existing Darktide modding
  ecosystem (DMF + dtkit-patch toolchain) that the Mod Relay runtime
  patch replaces: the
  [toolchain/framework reference](community-tools/darktide-framework-analysis.md)
  and its [version-pinned verification record](community-tools/analysis-verification.md).
