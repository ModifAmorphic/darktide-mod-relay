//! The oracle: the 16 target-function RVAs pinned to the analyzed Darktide.exe
//! build (SHA-256 `132eed5f…791661`, 18,715,784 bytes), transcribed from the
//! runtime-confirmed `addresses.json` captures (the validated binary constraints
//! are documented in `docs/reference/darktide/darktide-binary.md`).
//!
//! The discovery engine itself is **build-agnostic** (no address is hardcoded
//! in its logic). This table exists only as the *Tier-1 exact-match oracle*
//! for the documented build, used by `tests/oracle.rs` to assert exact-equality
//! when (and only when) the resolved binary's SHA matches the pinned one. On
//! any other build, the test falls back to Tier-2 matcher self-validation
//! (every function found uniquely by its source-pattern signature) — which is
//! the build-agnostic proof that the engine is correct.

/// SHA-256 of the Darktide.exe build the oracle below is pinned to.
pub const PINNED_SHA256: &str = "132eed5fe58515774a41199269dd240ef6092f84b1efc8ad4a28e23ea6791661";

/// The 16 (name, RVA) pairs for the pinned build, in spec-table order.
pub const PINNED_SIXTEEN: [(&str, u32); 16] = [
    ("lua_newstate_thunk", 0x0c7c000),
    ("lua_newstate_body", 0x0c7eea0),
    ("lua_atpanic", 0x0c77f40),
    ("lua_gettop", 0x0c74050),
    ("luaL_loadbuffer", 0x0c7ad80),
    ("lua_pcall", 0x0c744c0),
    ("luaL_openlibs", 0x0c7f380),
    ("lua_pushcclosure", 0x0c74580),
    ("lua_setfield", 0x0c74cb0),
    ("lua_pushstring", 0x0c747d0),
    ("lua_tolstring", 0x0c75190),
    ("lua_createtable", 0x0c73ad0),
    ("lua_type", 0x0c753b0),
    ("lua_tonumber", 0x0c730c0),
    ("lua_settop", 0x0c74f30),
    ("lua_panic_body", 0x0328220),
];
