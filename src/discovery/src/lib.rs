//! relay-discovery — the Mod Relay discovery pure-library (Rust).
//!
//! Production discovery engine for the Darktide LuaJIT runtime. Resolves all
//! 16 target function addresses via Method A (string-anchor) + Method B
//! (source-pattern) plus `.pdata` gap-handling. Pure computation over a
//! borrowed byte slice; no I/O, no globals, no live-game access.
//!
//! ## Safety boundary
//! Everything is safe Rust except two confined surfaces:
//!   1. [`disasm`] — the capstone C-FFI wrapper.
//!   2. this module's C-ABI seam ([`ffi`]) — which must dereference
//!      caller-provided pointers.
//!
//! Every `extern "C"` entry is wrapped in [`std::panic::catch_unwind`] so a
//! panic anywhere in the pure-library can never unwind across the C-ABI
//! boundary (which would be UB). See the *Panic boundary* notes below.

pub mod disasm;
pub mod engine;
pub mod oracle;
pub mod patterns;
pub mod pe;
pub mod scan;

pub use engine::{discover, discover_file, discover_with, AddressTable, DiscoverError};
pub use pe::{map_from_file, Pe};

// =========================================================================
// C-ABI seam (linked into the C shell as a static archive)
// =========================================================================
//
// The seam is intentionally tiny and holds the safety boundary: it turns a
// raw `(ptr, len)` the C shell hands us (the live module base, already laid
// out by RVA by the Windows loader) into a `&[u8]`, runs the safe discovery
// engine, and writes the result into a caller-provided `#repr(C)` struct.
// Every entry point catches unwinding panics so none can cross into C.

/// C-ABI address table. Field order is fixed; the C header (`shell/include/
/// relay_discovery.h`) mirrors it exactly. All values are RVAs (offsets from
/// the module base the caller passed in).
///
/// The table carries the canonical 16 LuaJIT/engine function addresses plus a
/// small set of additional validated LuaJIT C-API + engine anchors discovered
/// by the same methods. The shell consumes the subset it needs; the remainder
/// are validated discovery outputs retained for a stable ABI. Field order and
/// count are part of the ABI (changing them breaks the C↔Rust mirror).
#[repr(C)]
#[derive(Debug, Clone, Copy, Default)]
pub struct RelayAddressTable {
    pub lua_newstate_thunk: u32,
    pub lua_newstate_body: u32,
    pub lua_atpanic: u32,
    pub lua_gettop: u32,
    pub lual_loadbuffer: u32,
    pub lua_pcall: u32,
    pub lual_openlibs: u32,
    pub lua_pushcclosure: u32,
    pub lua_setfield: u32,
    pub lua_pushstring: u32,
    pub lua_tolstring: u32,
    pub lua_createtable: u32,
    pub lua_type: u32,
    pub lua_tonumber: u32,
    pub lua_settop: u32,
    pub lua_panic_body: u32,
    pub luaenvironment_init_begin: u32,
    pub luaenvironment_init_end: u32,
    /// C-API table-get (`lua_getglobal` is a macro over it).
    pub lua_getfield: u32,
    /// Primary `lua_resource::bytecode` loader function (the engine's
    /// bundle-script loader, resolved via its string-anchor).
    pub lua_resource_bytecode: u32,
    /// C-API: read a func/udata/thread's env table.
    pub lua_getfenv: u32,
    /// C-API: set a func/udata/thread's env table.
    pub lua_setfenv: u32,
}

impl From<&AddressTable> for RelayAddressTable {
    fn from(t: &AddressTable) -> Self {
        Self {
            lua_newstate_thunk: t.lua_newstate_thunk,
            lua_newstate_body: t.lua_newstate_body,
            lua_atpanic: t.lua_atpanic,
            lua_gettop: t.lua_gettop,
            lual_loadbuffer: t.lual_loadbuffer,
            lua_pcall: t.lua_pcall,
            lual_openlibs: t.lual_openlibs,
            lua_pushcclosure: t.lua_pushcclosure,
            lua_setfield: t.lua_setfield,
            lua_pushstring: t.lua_pushstring,
            lua_tolstring: t.lua_tolstring,
            lua_createtable: t.lua_createtable,
            lua_type: t.lua_type,
            lua_tonumber: t.lua_tonumber,
            lua_settop: t.lua_settop,
            lua_panic_body: t.lua_panic_body,
            luaenvironment_init_begin: t.luaenvironment_init_begin,
            luaenvironment_init_end: t.luaenvironment_init_end,
            lua_getfield: t.lua_getfield,
            lua_resource_bytecode: t.lua_resource_bytecode,
            lua_getfenv: t.lua_getfenv,
            lua_setfenv: t.lua_setfenv,
        }
    }
}

// Return codes for `relay_discover`.
pub const RELAY_OK: i32 = 0;
pub const RELAY_ERR_NULL_ARG: i32 = -1;
pub const RELAY_ERR_PE: i32 = -2;
pub const RELAY_ERR_DISCOVERY: i32 = -3;
pub const RELAY_ERR_PANIC: i32 = -100; // a panic was caught at the boundary

/// Run discovery on an RVA-laid-out image (the live module base, or an
/// offline-mapped file). On success populates every field of `*out` — the
/// canonical 16 LuaJIT/engine function RVAs plus the additional validated
/// anchors (22 fields total; see [`RelayAddressTable`]) — and returns
/// [`RELAY_OK`]. Returns a negative code on error or on a caught panic
/// (the latter must never happen in practice but is contained).
///
/// # Safety
/// `image` must point to at least `len` readable bytes for the duration of
/// the call; `out` must point to a writable `RelayAddressTable`. Both may
/// be null (returns [`RELAY_ERR_NULL_ARG`]).
#[no_mangle]
pub unsafe extern "C" fn relay_discover(
    image: *const u8,
    len: usize,
    out: *mut RelayAddressTable,
) -> i32 {
    // `AssertUnwindSafe`: the FFI inputs are not `UnwindSafe`, but on a panic
    // we discard everything and return a code — no Rust value escapes — so the
    // assertion is sound at this boundary.
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if image.is_null() || out.is_null() {
            return RELAY_ERR_NULL_ARG;
        }
        // SAFETY: caller upholds that `image[..len]` is valid for the call.
        let slice = unsafe { core::slice::from_raw_parts(image, len) };
        match discover(slice) {
            Ok(t) => {
                // SAFETY: caller upholds that `out` is writable.
                unsafe { *out = RelayAddressTable::from(&t) };
                RELAY_OK
            }
            Err(DiscoverError::Pe(_)) => RELAY_ERR_PE,
            Err(_) => RELAY_ERR_DISCOVERY,
        }
    }));
    match r {
        Ok(code) => code,
        Err(_payload) => {
            // Panic contained: no unwind into C, no UB. (Logged by the abort
            // hook in debug builds; in release the process would have aborted
            // only if `panic=abort` were active — see the profile notes.)
            RELAY_ERR_PANIC
        }
    }
}

/// Run discovery on an RVA-laid-out image and additionally fill `*detail` with
/// a UTF-8 error string (NUL-terminated) when the call fails. `detail` may be
/// null; `detail_cap` is the capacity of the buffer it points to.
///
/// # Safety
/// Same as [`relay_discover`] plus: if `detail` is non-null, it must point to
/// at least `detail_cap` writable bytes.
#[no_mangle]
pub unsafe extern "C" fn relay_discover_detail(
    image: *const u8,
    len: usize,
    out: *mut RelayAddressTable,
    detail: *mut u8,
    detail_cap: usize,
) -> i32 {
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if image.is_null() || out.is_null() {
            write_detail(detail, detail_cap, "null argument (image or out)");
            return RELAY_ERR_NULL_ARG;
        }
        let slice = unsafe { core::slice::from_raw_parts(image, len) };
        match discover(slice) {
            Ok(t) => {
                unsafe { *out = RelayAddressTable::from(&t) };
                RELAY_OK
            }
            Err(e) => {
                write_detail(detail, detail_cap, &e.to_string());
                match e {
                    DiscoverError::Pe(_) => RELAY_ERR_PE,
                    _ => RELAY_ERR_DISCOVERY,
                }
            }
        }
    }));
    match r {
        Ok(code) => code,
        Err(_) => {
            write_detail(detail, detail_cap, "panic contained at C-ABI boundary");
            RELAY_ERR_PANIC
        }
    }
}

// SAFETY-internal: copy a message into a caller buffer (NUL-terminated,
// truncated). `detail` may be null.
fn write_detail(detail: *mut u8, cap: usize, msg: &str) {
    if detail.is_null() || cap == 0 {
        return;
    }
    let n = msg.len().min(cap.saturating_sub(1));
    // SAFETY: caller upholds that `detail[..cap]` is writable.
    unsafe {
        core::ptr::copy_nonoverlapping(msg.as_ptr(), detail, n);
        *detail.add(n) = 0;
    }
}

// =========================================================================
// Panic boundary
// =========================================================================
//
// `panic = "abort"` (workspace `[profile.release]` keeps unwind so that
// `catch_unwind` is the *primary* containment; the separate `panic-abort`
// profile demonstrates the abort fail-safe). The two are subtly related:
//
//   - `catch_unwind` only catches a panic when the panic strategy is *unwind*
//     for the panicking code. That is why the artifact the shell links is
//     built with `panic = "unwind"` (the default): every `extern "C"` entry
//     is wrapped in `catch_unwind`, so a panic is gracefully contained and
//     the host receives an error code instead of UB.
//   - The `panic-abort` profile flips the strategy to abort: in that build a
//     panic the boundary fails to catch is impossible by construction, because
//     *any* uncaught panic terminates the process immediately. That is the
//     belt-and-suspenders backstop (no UB, but not graceful).
//
// `relay_test_panic_boundary` demonstrates the primary mechanism: it induces a
// panic in the pure-library and catches it, returning a sentinel code — proving
// no panic crosses into C and no UB occurs. (Build with the default unwind
// strategy; under `panic-abort` this entry would instead abort the test
// process, which is the documented alternative behaviour.)

/// Induce a panic inside the pure-library, caught at the C-ABI boundary.
/// Returns 0 if `induce == 0` (no panic); returns `RELAY_PANIC_CAUGHT` if a
/// panic was induced and successfully contained; never returns otherwise.
///
/// Test-only: gated behind the `test-hooks` Cargo feature so the release
/// staticlib linked into the C shell never exports this symbol.
#[cfg(feature = "test-hooks")]
#[no_mangle]
pub extern "C" fn relay_test_panic_boundary(induce: i32) -> i32 {
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if induce != 0 {
            panic!("induced panic for boundary test");
        }
    }));
    match r {
        Ok(()) => 0,
        Err(_) => RELAY_PANIC_CAUGHT,
    }
}

/// Sentinel returned by [`relay_test_panic_boundary`] when a panic is caught.
#[cfg(feature = "test-hooks")]
pub const RELAY_PANIC_CAUGHT: i32 = 0x7FFF_FFB7; // 'B7' = boundary

#[cfg(all(test, feature = "test-hooks"))]
mod panic_tests {
    use super::*;

    /// The catch_unind boundary contains an induced panic: it returns the
    /// sentinel rather than unwinding/aborting. (Requires the unwind strategy,
    /// which is the default for this crate.)
    #[test]
    fn induced_panic_is_contained_at_seam() {
        let code = relay_test_panic_boundary(0);
        assert_eq!(code, 0, "no-op path must return 0");
        let code = relay_test_panic_boundary(1);
        assert_eq!(
            code, RELAY_PANIC_CAUGHT,
            "induced panic must be caught at the C-ABI boundary"
        );
    }

    /// A plain `catch_unwind` in library code also contains panics — the same
    /// mechanism the seam relies on.
    #[test]
    fn catch_unwind_contains_library_panic() {
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            panic!("inner");
        }));
        assert!(r.is_err());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A null pointer is rejected cleanly (no UB), demonstrating the seam
    /// validates its inputs before touching them.
    #[test]
    fn seam_rejects_null_args() {
        let mut out = RelayAddressTable::default();
        // SAFETY: a null `image` is the explicit error path the seam validates
        // before any deref; `out` is a valid local.
        let code = unsafe { relay_discover(core::ptr::null(), 0, &mut out) };
        assert_eq!(code, RELAY_ERR_NULL_ARG);
        // SAFETY: `image` points at a valid 1-byte slice; a null `out` is the
        // explicit error path the seam validates before any deref.
        let code = unsafe { relay_discover(b"x".as_ptr(), 1, core::ptr::null_mut()) };
        assert_eq!(code, RELAY_ERR_NULL_ARG);
    }
}
