/*
 * relay_discovery.h — C-ABI of the Rust `relay-discovery` staticlib.
 *
 * The Rust crate (discovery/src/lib.rs) defines the same struct with `#[repr(C)]`;
 * this header mirrors it exactly for the C shell. All fields are RVAs (offsets
 * from the module base passed to `relay_discover`).
 *
 * The table carries the canonical 16 LuaJIT/engine function addresses plus a
 * small set of additional validated anchors discovered by the same methods
 * (string-anchor + source-pattern). The shell consumes the subset it needs
 * (lua_newstate, lua_pcall, luaL_loadbuffer, lua_gettop, lua_settop,
 * lua_tolstring); the remainder are validated discovery outputs retained for a
 * stable ABI (see dllmain.c's discovery note). The layout is fixed: changing
 * field order or removing fields breaks the C↔Rust mirror.
 */
#ifndef RELAY_DISCOVERY_H
#define RELAY_DISCOVERY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t lua_newstate_thunk;
    uint32_t lua_newstate_body;
    uint32_t lua_atpanic;
    uint32_t lua_gettop;
    uint32_t lual_loadbuffer;
    uint32_t lua_pcall;
    uint32_t lual_openlibs;
    uint32_t lua_pushcclosure;
    uint32_t lua_setfield;
    uint32_t lua_pushstring;
    uint32_t lua_tolstring;
    uint32_t lua_createtable;
    uint32_t lua_type;
    uint32_t lua_tonumber;
    uint32_t lua_settop;
    uint32_t lua_panic_body;
    uint32_t luaenvironment_init_begin;
    uint32_t luaenvironment_init_end;
    /* Additional validated LuaJIT C-API + engine anchors. */
    uint32_t lua_getfield;             /* C-API table-get (`lua_getglobal` macro is over it). */
    uint32_t lua_resource_bytecode;    /* engine bundle-script loader (string-anchor). */
    uint32_t lua_getfenv;              /* C-API: read func/udata/thread env. */
    uint32_t lua_setfenv;              /* C-API: set func/udata/thread env. */
} RelayAddressTable;

/* Return codes. */
#define RELAY_OK              0
#define RELAY_ERR_NULL_ARG   (-1)
#define RELAY_ERR_PE         (-2)
#define RELAY_ERR_DISCOVERY  (-3)
#define RELAY_ERR_PANIC      (-100) /* a panic was caught at the boundary */

/*
 * Run discovery on an RVA-laid-out image (the live module base, or an
 * offline-mapped file). On success populates every field of *out — the
 * canonical 16 LuaJIT/engine function RVAs plus the additional validated
 * anchors (22 fields total; see the struct comment above) — and returns
 * RELAY_OK. Panics in the pure-library are caught at the boundary (never
 * unwind into C).
 *
 *   image : pointer to the first byte of the module (GetModuleHandle(NULL)
 *           for the live game; the loader maps headers there too).
 *   len   : SizeOfImage (use GetModuleHandle + ModuleInfo.SizeOfImage).
 *   out   : writable RelayAddressTable.
 */
int relay_discover(const uint8_t *image, size_t len, RelayAddressTable *out);

/* As above, plus a NUL-terminated error string into detail[0..detail_cap). */
int relay_discover_detail(const uint8_t *image, size_t len,
                          RelayAddressTable *out,
                          uint8_t *detail, size_t detail_cap);

/*
 * Test-only: induce a panic in the pure-library and catch it at the C-ABI
 * boundary. Returns 0 if induce==0, RELAY_PANIC_CAUGHT if contained.
 *
 * This symbol is exported by the Rust staticlib ONLY when built with the
 * `test-hooks` Cargo feature (`cargo build/test --features test-hooks`). A
 * release staticlib (the artifact linked into the shipped shell) does NOT
 * export it. Declare RELAY_TEST_HOOKS before including this header to opt in
 * to the declaration — intended only for test builds that link the test-hooks
 * staticlib. Mirrors the `#[cfg(feature = "test-hooks")]` gate on the Rust
 * side (discovery/src/lib.rs).
 */
#ifdef RELAY_TEST_HOOKS
int relay_test_panic_boundary(int induce);
#define RELAY_PANIC_CAUGHT 0x7FFFFFB7
#endif /* RELAY_TEST_HOOKS */

#ifdef __cplusplus
}
#endif

#endif /* RELAY_DISCOVERY_H */
