//! Oracle integration test.
//!
//! Resolves the installed `Darktide.exe` via `$DARKTIDE_GAME_DIR`, runs the
//! full discovery engine, and validates the result on two tiers:
//!
//!   - **Tier 1 — pinned exact-match.** Runs *only* if the resolved binary's
//!     SHA-256 equals the oracle's pinned SHA (`132eed5f…`). Asserts every one
//!     of the 16 discovered RVAs equals the pinned value (transcribed from the
//!     runtime-confirmed `addresses.json` captures — see `src/oracle.rs`).
//!   - **Tier 2 — matcher self-validation (always).** [`discover`] returning
//!     `Ok` is itself the proof: each of the 16 finders requires a *unique*
//!     cluster candidate whose body satisfies that function's source-pattern
//!     signature, so success means all 16 were found unambiguously. We then
//!     also re-check each discovered address against its matcher and print the
//!     full table.
//!
//! The test **skips** (does not fail) when the binary is absent, so the suite
//! is portable; it runs fully wherever a Darktide install is reachable.

use relay_discovery::patterns::{self, Cluster};
use relay_discovery::pe::{map_from_file, Pe};
use relay_discovery::{discover, oracle::PINNED_SHA256, oracle::PINNED_SIXTEEN, DiscoverError};
use sha2::{Digest, Sha256};
use std::path::PathBuf;

/// Resolve `DARKTIDE_GAME_DIR` from the environment. Returns `None` if the
/// env var is unset or empty (the test then skips cleanly — same path CI
/// takes). The env var is the only resolution source; no files are read.
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

fn sha256_hex(bytes: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(bytes);
    let out = h.finalize();
    out.iter().map(|b| format!("{:02x}", b)).collect()
}

#[test]
fn oracle_all_sixteen_match() {
    let exe = match darktide_exe() {
        Some(p) => p,
        None => {
            eprintln!("[oracle] SKIP: Darktide.exe not resolvable (set $DARKTIDE_GAME_DIR)");
            return;
        }
    };
    let file = std::fs::read(&exe).expect("read Darktide.exe");
    let sha = sha256_hex(&file);
    let pinned = sha == PINNED_SHA256;
    eprintln!("[oracle] binary = {}", exe.display());
    eprintln!("[oracle] sha256 = {sha}");
    eprintln!(
        "[oracle] {} the pinned build ({})",
        if pinned { "MATCHES" } else { "DIFFERS FROM" },
        PINNED_SHA256
    );

    let image = map_from_file(&file).expect("map Darktide.exe");
    let table = discover(&image).expect("discovery must find all 16 uniquely (Tier 2)");

    // ---- Tier 1: pinned exact-match (only when the build matches the oracle) ----
    if pinned {
        for (name, pinned_rva) in PINNED_SIXTEEN {
            let got = table.sixteen().iter().find(|(n, _)| *n == name).unwrap().1;
            assert_eq!(
                got, pinned_rva,
                "Tier-1 mismatch on {name}: got 0x{got:x}, pinned 0x{pinned_rva:x}"
            );
        }
        eprintln!("[oracle] Tier-1 PASS: all 16 RVAs exactly match the pinned oracle");
    } else {
        eprintln!(
            "[oracle] Tier-1 SKIPPED: installed build differs from the pinned oracle \
             (this is a fixture-version note, not a discovery failure)."
        );
    }

    // ---- Tier 2: matcher self-validation (always) ----
    // discover() already required each signature to match uniquely; re-assert
    // each discovered address against its matcher for an explicit, reportable
    // pass/fail per function, and require all RVAs non-zero + distinct.
    let pe = Pe::from_mapped(&image).unwrap();
    let mut dis =
        relay_discovery::disasm::Disassembler::new_x86_64_intel().expect("capstone init");
    let cluster = test_cluster(&pe, &image);
    eprintln!(
        "[oracle] cluster window = [0x{:x}, 0x{:x}), _PRELOAD rva = 0x{:x}",
        cluster.lo, cluster.hi, cluster.preload_str_rva
    );

    let mut distinct = std::collections::HashSet::new();
    let sixteen = table.sixteen();
    for (name, rva) in sixteen {
        assert!(rva != 0, "Tier-2: {name} discovered as 0");
        // The only legitimate duplicate: lua_newstate_thunk may equal
        // lua_newstate_body when the CFG thunk didn't resolve to a distinct
        // body. Every other pair must be distinct.
        let allowed_dup = name == "lua_newstate_body" && rva == table.lua_newstate_thunk;
        assert!(
            distinct.insert(rva) || allowed_dup,
            "Tier-2: duplicate RVA 0x{rva:x} for {name}"
        );
    }
    // Re-validate each function body against its signature at the discovered RVA.
    assert_match(
        "lua_gettop",
        table.lua_gettop,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_gettop,
    );
    assert_match(
        "lua_atpanic",
        table.lua_atpanic,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_atpanic,
    );
    assert_match(
        "lua_type",
        table.lua_type,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_type,
    );
    assert_match(
        "lua_tolstring",
        table.lua_tolstring,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_tolstring,
    );
    assert_match(
        "lua_createtable",
        table.lua_createtable,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_createtable,
    );
    assert_match(
        "lua_tonumber",
        table.lua_tonumber,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_tonumber,
    );
    assert_match(
        "lua_settop",
        table.lua_settop,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_settop,
    );
    assert_match(
        "lua_pcall",
        table.lua_pcall,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_pcall,
    );
    assert_match_c(
        "lua_pushcclosure",
        table.lua_pushcclosure,
        &pe,
        &image,
        &mut dis,
        cluster,
        patterns::match_lua_pushcclosure,
    );
    assert_match_c(
        "lua_setfield",
        table.lua_setfield,
        &pe,
        &image,
        &mut dis,
        cluster,
        patterns::match_lua_setfield,
    );
    assert_match_c(
        "lua_pushstring",
        table.lua_pushstring,
        &pe,
        &image,
        &mut dis,
        cluster,
        patterns::match_lua_pushstring,
    );
    assert_match_c(
        "luaL_openlibs",
        table.lual_openlibs,
        &pe,
        &image,
        &mut dis,
        cluster,
        patterns::match_lual_openlibs,
    );
    assert_match_body(
        "luaL_loadbuffer",
        table.lual_loadbuffer,
        &pe,
        &image,
        &mut dis,
        cluster,
        patterns::match_lual_loadbuffer,
    );
    // newstate body signature + thunk→body link.
    assert_match(
        "lua_newstate_body",
        table.lua_newstate_body,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_newstate_body,
    );
    assert!(
        table.lua_newstate_thunk == table.lua_newstate_body
            || thunk_targets(
                image.as_slice(),
                table.lua_newstate_thunk,
                table.lua_newstate_body
            ),
        "Tier-2: lua_newstate_thunk 0x{:x} must jump to body 0x{:x}",
        table.lua_newstate_thunk,
        table.lua_newstate_body
    );
    eprintln!("[oracle] Tier-2 PASS: all 16 signatures self-validate at their discovered RVAs");

    // ---- Additional LuaJIT C-API + engine anchor: lua_getfield ----
    // `lua_getfield` is the C-API table-get (`lua_getglobal` =
    // `lua_getfield(L, LUA_GLOBALSINDEX, s)`). Assert it was found uniquely
    // (discover() already required this), self-validates against its matcher,
    // and is distinct from its `lua_setfield` sibling.
    assert!(table.lua_getfield != 0, "lua_getfield discovered as 0");
    assert_ne!(
        table.lua_getfield, table.lua_setfield,
        "lua_getfield must differ from lua_setfield (top++ vs top-- epilogue)"
    );
    assert_match_c(
        "lua_getfield",
        table.lua_getfield,
        &pe,
        &image,
        &mut dis,
        cluster,
        patterns::match_lua_getfield,
    );
    eprintln!(
        "[oracle] lua_getfield @ 0x{:x} (self-validates)",
        table.lua_getfield
    );

    // `lua_resource::bytecode` is the engine's bundle-script loader — the
    // `.pdata` function that references the `stingray::lua_resource::bytecode`
    // string AND calls `luaL_loadbuffer`. Round-trip the discovery: the
    // discovered loader's body must exhibit both.
    assert!(
        table.lua_resource_bytecode != 0,
        "lua_resource::bytecode loader discovered as 0"
    );
    assert_bytecode_loader(
        &pe,
        &image,
        &mut dis,
        table.lua_resource_bytecode,
        table.lual_loadbuffer,
    );
    eprintln!(
        "[oracle] lua_resource::bytecode loader @ 0x{:x} (references anchor + calls luaL_loadbuffer @ 0x{:x})",
        table.lua_resource_bytecode, table.lual_loadbuffer
    );

    // ---- Additional C-API env-table accessors: lua_getfenv + lua_setfenv ----
    // `lua_getfenv` / `lua_setfenv` are lapi.c siblings of `lua_getfield` /
    // `lua_setfield` (same index2adr prologue + func/udata/thread type-check
    // triple), discriminated by `top++` (getfenv pushes the env) vs `top--`
    // (setfenv pops the env). Assert each was found uniquely (discover() already
    // required this), self-validates against its matcher, is non-zero, and that
    // the two are distinct from each other and from their getfield/setfield
    // siblings (the top++/top-- epilogue is the discriminator).
    assert!(table.lua_getfenv != 0, "lua_getfenv discovered as 0");
    assert!(table.lua_setfenv != 0, "lua_setfenv discovered as 0");
    assert_ne!(
        table.lua_getfenv, table.lua_setfenv,
        "lua_getfenv must differ from lua_setfenv (top++ vs top-- epilogue)"
    );
    assert_ne!(
        table.lua_getfenv, table.lua_getfield,
        "lua_getfenv must differ from lua_getfield"
    );
    assert_ne!(
        table.lua_setfenv, table.lua_setfield,
        "lua_setfenv must differ from lua_setfield"
    );
    assert_match(
        "lua_getfenv",
        table.lua_getfenv,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_getfenv,
    );
    assert_match(
        "lua_setfenv",
        table.lua_setfenv,
        &pe,
        &image,
        &mut dis,
        patterns::match_lua_setfenv,
    );
    eprintln!(
        "[oracle] lua_getfenv @ 0x{:x}, lua_setfenv @ 0x{:x} (both self-validate)",
        table.lua_getfenv, table.lua_setfenv
    );

    // ---- Report: full table + shift vs the pinned build (informative) ----
    eprintln!("[oracle] ---- discovered 16 (RVA) ----");
    let mut deltas: Vec<i64> = Vec::new();
    for (name, pinned_rva) in PINNED_SIXTEEN {
        let got = sixteen.iter().find(|(n, _)| *n == name).unwrap().1;
        let delta = got as i64 - pinned_rva as i64;
        eprintln!("[oracle]   {name:<22} 0x{got:08x}  (pinned 0x{pinned_rva:08x}, Δ {delta:+#x})");
        if got != 0 {
            deltas.push(delta);
        }
    }
    if !deltas.is_empty() {
        let min = *deltas.iter().min().unwrap();
        let max = *deltas.iter().max().unwrap();
        eprintln!(
            "[oracle] shift vs pinned: min Δ = {min:+#x}, max Δ = {max:+#x} ({})",
            if min == max {
                "UNIFORM — code block relocated as a unit"
            } else {
                "NON-UNIFORM — investigate"
            }
        );
    }
}

// ---- helpers ----

fn test_cluster(pe: &Pe, image: &[u8]) -> Cluster {
    // Mirror engine::discover_with's cluster derivation.
    let rdata = pe.rdata();
    let rlen = std::cmp::min(rdata.raw_size, rdata.virtual_size) as usize;
    let preload = image
        .get(rdata.rva as usize..rdata.rva as usize + rlen)
        .and_then(|s| {
            s.windows(b"_PRELOAD\x00".len())
                .position(|w| w == b"_PRELOAD\x00")
        })
        .map(|off| rdata.rva + off as u32)
        .unwrap_or(0);
    let center = pe.text().rva; // fallback only
                                // Use the LuaJIT version string anchor like the engine.
    let mut center = center;
    if let Some(rva) = string_rva(pe, image, b"LuaJIT 2.1.") {
        let mut sites = Vec::new();
        relay_discovery::scan::find_lea_xrefs(pe, image, rva, &mut sites);
        if let Some(&site) = sites.first() {
            if let Some(rf) = pe.find_runtime_function(site) {
                center = rf.begin;
            }
        }
    }
    Cluster {
        lo: center.saturating_sub(0x10_0000),
        hi: center.saturating_add(0x10_0000),
        preload_str_rva: preload,
    }
}

fn string_rva(pe: &Pe, image: &[u8], needle: &[u8]) -> Option<u32> {
    let r = pe.rdata();
    let len = std::cmp::min(r.raw_size, r.virtual_size) as usize;
    let slice = image.get(r.rva as usize..r.rva as usize + len)?;
    let off = slice.windows(needle.len()).position(|w| w == needle)?;
    Some(r.rva + off as u32)
}

fn assert_match(
    name: &str,
    rva: u32,
    pe: &Pe,
    image: &[u8],
    dis: &mut relay_discovery::disasm::Disassembler,
    matcher: fn(&[relay_discovery::disasm::DecodedInsn]) -> bool,
) {
    let (begin, end) = relay_discovery::disasm::body_bounds(pe, rva);
    let insns = dis.disasm_range(image, begin, end);
    assert!(
        !insns.is_empty() && matcher(&insns),
        "Tier-2: signature mismatch for {name} @ 0x{rva:x}"
    );
}

fn assert_match_c(
    name: &str,
    rva: u32,
    pe: &Pe,
    image: &[u8],
    dis: &mut relay_discovery::disasm::Disassembler,
    cluster: Cluster,
    matcher: fn(&[relay_discovery::disasm::DecodedInsn], Cluster) -> bool,
) {
    let (begin, end) = relay_discovery::disasm::body_bounds(pe, rva);
    let insns = dis.disasm_range(image, begin, end);
    assert!(
        !insns.is_empty() && matcher(&insns, cluster),
        "Tier-2: signature mismatch for {name} @ 0x{rva:x}"
    );
}

fn assert_match_body(
    name: &str,
    rva: u32,
    pe: &Pe,
    image: &[u8],
    dis: &mut relay_discovery::disasm::Disassembler,
    cluster: Cluster,
    matcher: fn(&[relay_discovery::disasm::DecodedInsn], &Pe, &[u8], Cluster) -> bool,
) {
    let (begin, end) = relay_discovery::disasm::body_bounds(pe, rva);
    let insns = dis.disasm_range(image, begin, end);
    assert!(
        !insns.is_empty() && matcher(&insns, pe, image, cluster),
        "Tier-2: signature mismatch for {name} @ 0x{rva:x}"
    );
}

/// Assert the discovered `lua_resource::bytecode` loader is a real function
/// whose body both LEA-references the `stingray::lua_resource::bytecode` anchor
/// string AND makes a direct call to the discovered `luaL_loadbuffer`. This
/// round-trips the Method-A trace in `engine::find_loadbuffer_via_bytecode`
/// against the binary.
fn assert_bytecode_loader(
    pe: &Pe,
    image: &[u8],
    dis: &mut relay_discovery::disasm::Disassembler,
    loader_rva: u32,
    loadbuffer_rva: u32,
) {
    let (begin, end) = relay_discovery::disasm::body_bounds(pe, loader_rva);
    let insns = dis.disasm_range(image, begin, end);
    assert!(
        !insns.is_empty(),
        "lua_resource::bytecode loader body empty @ 0x{loader_rva:x}"
    );
    let bytecode_str_rva = string_rva(pe, image, b"stingray::lua_resource::bytecode\x00")
        .expect("bytecode anchor string must be present in .rdata");
    let has_str_xref = insns.iter().any(|i| {
        i.id == relay_discovery::disasm::X86_INS_LEA
            && relay_discovery::disasm::rip_relative_target(i) == Some(bytecode_str_rva)
    });
    let has_loadbuffer_call = insns.iter().any(|i| {
        i.id == relay_discovery::disasm::X86_INS_CALL
            && relay_discovery::disasm::parse_branch_target(i) == Some(loadbuffer_rva as u64)
    });
    assert!(
        has_str_xref,
        "loader @ 0x{loader_rva:x} must LEA-reference the bytecode anchor string"
    );
    assert!(
        has_loadbuffer_call,
        "loader @ 0x{loader_rva:x} must call luaL_loadbuffer (0x{loadbuffer_rva:x})"
    );
}

fn thunk_targets(image: &[u8], thunk_rva: u32, body_rva: u32) -> bool {
    let p = match image.get(thunk_rva as usize..thunk_rva as usize + 5) {
        Some(p) => p,
        None => return false,
    };
    if p[0] != 0xE9 {
        return false;
    }
    let rel = i32::from_le_bytes([p[1], p[2], p[3], p[4]]);
    (thunk_rva as i64 + 5 + rel as i64) as u32 == body_rva
}

// Smoke: the DiscoverError Display impl renders (keeps the public API honest).
#[test]
fn discover_error_displays() {
    let e = DiscoverError::Anchor("test");
    assert_eq!(format!("{e}"), "method-A anchor 'test' not found");
}
