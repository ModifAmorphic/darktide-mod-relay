//! Integration test for the `relay_discover_detail` C-ABI seam — the variant
//! with a detail/error buffer that the live C shell (`shell/src/dllmain.c`)
//! calls. `relay_discover` is already unit-tested in `src/lib.rs`; this
//! covers the detail-buffer variant's two contracts:
//!
//!   - **Success path**: against the real `Darktide.exe` (resolved via
//!     `$DARKTIDE_GAME_DIR`, the same pattern as `oracle.rs`),
//!     `relay_discover_detail` returns `RELAY_OK`, all table fields are
//!     found (the canonical 16 plus the additional validated anchors), and the
//!     detail buffer is left untouched (success writes no error message). Skips
//!     cleanly when the binary is absent (portable in CI).
//!   - **Error path**: a non-PE byte buffer yields a non-OK status (the PE
//!     error code) AND populates the detail buffer with a non-empty message.

use relay_discovery::pe::map_from_file;
use relay_discovery::{relay_discover_detail, RelayAddressTable, RELAY_ERR_PE, RELAY_OK};
use std::path::PathBuf;

/// Resolve `DARKTIDE_GAME_DIR` from the environment. Returns `None` if the
/// env var is unset or empty (the test then skips cleanly — same path CI
/// takes). The env var is the only resolution source; no files are read.
/// Mirrors `tests/oracle.rs::resolve_game_dir`.
fn resolve_game_dir() -> Option<PathBuf> {
    let dir = std::env::var("DARKTIDE_GAME_DIR").ok()?;
    if dir.is_empty() {
        None
    } else {
        Some(PathBuf::from(dir))
    }
}

fn darktide_exe() -> Option<PathBuf> {
    let dir = resolve_game_dir()?;
    let exe = dir.join("binaries").join("Darktide.exe");
    if exe.exists() {
        Some(exe)
    } else {
        None
    }
}

/// The 16 LuaJIT/C-API RVAs of a `RelayAddressTable` as `(name, rva)` pairs, in
/// spec-table order. Mirrors `engine::AddressTable::sixteen` for the C-ABI
/// struct (which exposes the fields but no such accessor).
fn sixteen_of(t: &RelayAddressTable) -> [(&'static str, u32); 16] {
    [
        ("lua_newstate_thunk", t.lua_newstate_thunk),
        ("lua_newstate_body", t.lua_newstate_body),
        ("lua_atpanic", t.lua_atpanic),
        ("lua_gettop", t.lua_gettop),
        ("luaL_loadbuffer", t.lual_loadbuffer),
        ("lua_pcall", t.lua_pcall),
        ("luaL_openlibs", t.lual_openlibs),
        ("lua_pushcclosure", t.lua_pushcclosure),
        ("lua_setfield", t.lua_setfield),
        ("lua_pushstring", t.lua_pushstring),
        ("lua_tolstring", t.lua_tolstring),
        ("lua_createtable", t.lua_createtable),
        ("lua_type", t.lua_type),
        ("lua_tonumber", t.lua_tonumber),
        ("lua_settop", t.lua_settop),
        ("lua_panic_body", t.lua_panic_body),
    ]
}

#[test]
fn relay_discover_detail_success_and_error_paths() {
    // ---- Error path (hermetic, always runs): a non-PE buffer must surface a
    // PE error AND populate the detail buffer with a non-empty message. ----
    // 256 bytes of zeros: large enough to pass the DOS-header size gate, but
    // with no MZ signature → PeError::BadDosSig → RELAY_ERR_PE.
    let bad: [u8; 256] = [0; 256];
    let mut out = RelayAddressTable::default();
    let mut detail = [0u8; 256];
    let code = unsafe {
        relay_discover_detail(
            bad.as_ptr(),
            bad.len(),
            &mut out,
            detail.as_mut_ptr(),
            detail.len(),
        )
    };
    assert_ne!(code, RELAY_OK, "non-PE input must not succeed");
    assert_eq!(code, RELAY_ERR_PE, "non-PE input must surface a PE error");
    let nul = detail.iter().position(|&b| b == 0).unwrap_or(detail.len());
    let msg = std::str::from_utf8(&detail[..nul]).unwrap_or("<bad utf8>");
    assert!(!msg.is_empty(), "detail buffer must be populated on error");
    eprintln!("[detail] error path: rc={code}, detail=\"{msg}\"");

    // ---- Success path: against the real Darktide.exe (skip if absent, like
    // oracle.rs). Asserts RELAY_OK, all table fields found (the canonical
    // 16 plus the additional validated anchors), and the detail buffer left
    // untouched (success writes no error message). ----
    let exe = match darktide_exe() {
        Some(p) => p,
        None => {
            eprintln!(
                "[detail] SKIP success path: Darktide.exe not resolvable (set \
                 $DARKTIDE_GAME_DIR)."
            );
            return;
        }
    };
    let file = std::fs::read(&exe).expect("read Darktide.exe");
    let image = map_from_file(&file).expect("map Darktide.exe");
    let mut out = RelayAddressTable::default();
    let mut detail = [0u8; 256];
    let code = unsafe {
        relay_discover_detail(
            image.as_ptr(),
            image.len(),
            &mut out,
            detail.as_mut_ptr(),
            detail.len(),
        )
    };
    assert_eq!(code, RELAY_OK, "discovery must succeed on the real binary");
    for (name, rva) in sixteen_of(&out) {
        assert!(rva != 0, "success path: {name} discovered as 0");
    }
    // The additional LuaJIT C-API + engine anchors must also be populated
    // through the C-ABI seam.
    assert!(
        out.lua_getfield != 0,
        "success path: lua_getfield discovered as 0"
    );
    assert!(
        out.lua_resource_bytecode != 0,
        "success path: lua_resource::bytecode loader discovered as 0"
    );
    // The additional C-API env-table accessors must also be populated.
    assert!(
        out.lua_getfenv != 0,
        "success path: lua_getfenv discovered as 0"
    );
    assert!(
        out.lua_setfenv != 0,
        "success path: lua_setfenv discovered as 0"
    );
    // Success writes nothing to the detail buffer: it must remain empty
    // (all-NUL, i.e. untouched since zero-init — matching the C shell's
    // `uint8_t detail[256] = {0}` usage in shell/src/dllmain.c).
    assert!(
        detail.iter().all(|&b| b == 0),
        "detail buffer must be untouched on success"
    );
    eprintln!("[detail] success path: rc=RELAY_OK, all 22 fields found (16 canonical + 6 additional), detail empty");
}
