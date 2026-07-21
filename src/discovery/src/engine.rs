//! Discovery orchestration: Method A (string anchors) + Method B (source-
//! pattern cluster scan) → a complete [`AddressTable`] (the canonical 16
//! target function RVAs plus the additional validated LuaJIT/engine anchors).
//!
//! Build-agnostic. No address is hardcoded in the logic: the LuaJIT cluster is
//! located at runtime via the `LuaJIT 2.1.<build>` version-string anchor
//! (whose containing function sits inside the cluster and which survives game
//! content updates), and every target function is identified by its
//! source-derived signature.

use crate::disasm::{parse_branch_target, Disassembler, X86_INS_CALL};
use crate::patterns::{self, candidate_starts, find_unique, Cluster, MatchError};
use crate::pe::{map_from_file, Pe};
use crate::scan::{find_callers, find_lea_xrefs};

/// All 16 target function addresses (RVAs) plus the bonus Method-A engine
/// anchors. `lua_newstate` appears as both the CFG thunk callers invoke and
/// the real body after the thunk follow.
///
/// The additional fields past the canonical 16 are validated LuaJIT C-API and
/// engine anchors discovered by the same methods: `lua_getfield` is the C-API
/// table-get (`lua_getglobal` is a macro over it), `lua_resource_bytecode` is
/// the engine's bundle-script loader (the
/// `stingray::lua_resource::bytecode` string-anchor's containing function that
/// calls `luaL_loadbuffer`), and `lua_getfenv`/`lua_setfenv` are the C-API
/// env-table accessors. The shell consumes the subset it needs; the rest are
/// retained for a stable ABI.
#[derive(Debug, Clone, Default)]
pub struct AddressTable {
    // --- the 16 target functions (the documented build's confirmed addresses) ---
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
    // --- bonus Method-A engine anchors (not part of the 16) ---
    pub luaenvironment_init_begin: u32,
    pub luaenvironment_init_end: u32,
    // --- additional LuaJIT C-API + engine anchors (not part of the 16) ---
    /// `lua_getfield(L, idx, k)` — the C-API table-get (`lua_getglobal(L, s)`
    /// is `lua_getfield(L, LUA_GLOBALSINDEX, s)`).
    pub lua_getfield: u32,
    /// Primary engine function whose body references the
    /// `stingray::lua_resource::bytecode` string and calls `luaL_loadbuffer`
    /// — i.e. the bundle-script loader (the `lua_resource::bytecode` anchor).
    pub lua_resource_bytecode: u32,
    // --- additional C-API env-table accessors (not part of the 16) ---
    /// `lua_getfenv(L, idx)` — pushes the env table of the func/udata/thread
    /// at `idx`.
    pub lua_getfenv: u32,
    /// `lua_setfenv(L, idx)` — sets the env of the func/udata/thread at `idx`
    /// to the table at `L->top-1`.
    pub lua_setfenv: u32,
}

impl AddressTable {
    /// The 16 LuaJIT/C-API RVAs as `(name, rva)` pairs, in spec-table order.
    pub fn sixteen(&self) -> [(&'static str, u32); 16] {
        [
            ("lua_newstate_thunk", self.lua_newstate_thunk),
            ("lua_newstate_body", self.lua_newstate_body),
            ("lua_atpanic", self.lua_atpanic),
            ("lua_gettop", self.lua_gettop),
            ("luaL_loadbuffer", self.lual_loadbuffer),
            ("lua_pcall", self.lua_pcall),
            ("luaL_openlibs", self.lual_openlibs),
            ("lua_pushcclosure", self.lua_pushcclosure),
            ("lua_setfield", self.lua_setfield),
            ("lua_pushstring", self.lua_pushstring),
            ("lua_tolstring", self.lua_tolstring),
            ("lua_createtable", self.lua_createtable),
            ("lua_type", self.lua_type),
            ("lua_tonumber", self.lua_tonumber),
            ("lua_settop", self.lua_settop),
            ("lua_panic_body", self.lua_panic_body),
        ]
    }
}

#[derive(Debug)]
pub enum DiscoverError {
    Pe(crate::pe::PeError),
    Disasm(String),
    Anchor(&'static str),
    Match(&'static str, MatchError),
}

impl core::fmt::Display for DiscoverError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::Pe(e) => write!(f, "pe parse: {e}"),
            Self::Disasm(e) => write!(f, "disasm: {e}"),
            Self::Anchor(a) => write!(f, "method-A anchor '{a}' not found"),
            Self::Match(name, e) => match e {
                MatchError::NoCandidate => write!(f, "no candidate matched signature '{name}'"),
                MatchError::Ambiguous(v) => write!(
                    f,
                    "signature '{}' matched {} candidates: {:?}",
                    name,
                    v.len(),
                    v
                ),
            },
        }
    }
}
impl std::error::Error for DiscoverError {}

impl From<crate::pe::PeError> for DiscoverError {
    fn from(e: crate::pe::PeError) -> Self {
        Self::Pe(e)
    }
}

/// Run the full discovery pipeline on an RVA-laid-out image.
pub fn discover(image: &[u8]) -> Result<AddressTable, DiscoverError> {
    let pe = Pe::from_mapped(image)?;
    let mut dis =
        Disassembler::new_x86_64_intel().map_err(|e| DiscoverError::Disasm(e.to_string()))?;
    discover_with(&pe, image, &mut dis)
}

/// Offline convenience: map an on-disk PE file to an RVA image, then discover.
pub fn discover_file(file: &[u8]) -> Result<AddressTable, DiscoverError> {
    let image = map_from_file(file)?;
    discover(&image)
}

pub fn discover_with(
    pe: &Pe,
    image: &[u8],
    dis: &mut Disassembler,
) -> Result<AddressTable, DiscoverError> {
    // ---- Phase A: Method-A string anchors ----
    let panic_body =
        method_a_lua_panic_body(pe, image, dis).ok_or(DiscoverError::Anchor("lua_panic"))?;
    let (init_begin, init_end) = method_a_luaenv_init(pe, image, panic_body)
        .ok_or(DiscoverError::Anchor("luaenvironment_init"))?;

    // LuaJIT version string → its single containing function is our cluster
    // anchor (it sits inside the LuaJIT API block).
    let cluster_center = containing_function_of_anchor(pe, image, b"LuaJIT 2.1.")
        .ok_or(DiscoverError::Anchor("LuaJIT version"))?;
    let preload_rva =
        string_rva(pe, image, b"_PRELOAD\x00").ok_or(DiscoverError::Anchor("_PRELOAD"))?;

    // Generous ±1 MiB window around the cluster anchor comfortably covers the
    // whole ~800 KiB LuaJIT API block (and then the signatures filter the rest).
    let lo = cluster_center.saturating_sub(0x10_0000);
    let hi = cluster_center.saturating_add(0x10_0000);
    let cluster = Cluster {
        lo,
        hi,
        preload_str_rva: preload_rva,
    };

    let candidates = candidate_starts(pe, image, lo, hi);

    // ---- Phase B: Method-B source-pattern cluster scan ----
    // Each finder returns the unique cluster candidate whose body satisfies
    // that function's source-derived signature.
    let lua_gettop = find_unique(dis, image, pe, &candidates, patterns::match_lua_gettop)
        .map_err(|e| DiscoverError::Match("lua_gettop", e))?;
    let lua_atpanic = find_unique(dis, image, pe, &candidates, patterns::match_lua_atpanic)
        .map_err(|e| DiscoverError::Match("lua_atpanic", e))?;
    let lua_type = find_unique(dis, image, pe, &candidates, patterns::match_lua_type)
        .map_err(|e| DiscoverError::Match("lua_type", e))?;
    let lua_pushcclosure = find_unique(dis, image, pe, &candidates, |i| {
        patterns::match_lua_pushcclosure(i, cluster)
    })
    .map_err(|e| DiscoverError::Match("lua_pushcclosure", e))?;
    let lua_setfield = find_unique(dis, image, pe, &candidates, |i| {
        patterns::match_lua_setfield(i, cluster)
    })
    .map_err(|e| DiscoverError::Match("lua_setfield", e))?;
    // `lua_getfield` is the symmetric sibling of `lua_setfield` (same prologue
    // + key-intern tag, but a `top++` epilogue instead of `top--`). It is a
    // validated LuaJIT C-API anchor (`lua_getglobal` is a macro over it), so
    // it is discovered alongside the 16 as part of the stable address table.
    let lua_getfield = find_unique(dis, image, pe, &candidates, |i| {
        patterns::match_lua_getfield(i, cluster)
    })
    .map_err(|e| DiscoverError::Match("lua_getfield", e))?;
    // `lua_getfenv` / `lua_setfenv` are lapi.c siblings of `lua_getfield` /
    // `lua_setfield` (same `index2adr(L, idx)` prologue + the func/udata/thread
    // type-check triple), discriminated by their `top++`/`top--` epilogues.
    // Validated C-API anchors, discovered as part of the stable address table.
    let lua_getfenv = find_unique(dis, image, pe, &candidates, patterns::match_lua_getfenv)
        .map_err(|e| DiscoverError::Match("lua_getfenv", e))?;
    let lua_setfenv = find_unique(dis, image, pe, &candidates, patterns::match_lua_setfenv)
        .map_err(|e| DiscoverError::Match("lua_setfenv", e))?;
    let lua_pushstring = find_unique(dis, image, pe, &candidates, |i| {
        patterns::match_lua_pushstring(i, cluster)
    })
    .map_err(|e| DiscoverError::Match("lua_pushstring", e))?;
    let lua_tolstring = find_unique(dis, image, pe, &candidates, patterns::match_lua_tolstring)
        .map_err(|e| DiscoverError::Match("lua_tolstring", e))?;
    let lua_createtable = find_unique(dis, image, pe, &candidates, patterns::match_lua_createtable)
        .map_err(|e| DiscoverError::Match("lua_createtable", e))?;
    let lua_tonumber = find_unique(dis, image, pe, &candidates, patterns::match_lua_tonumber)
        .map_err(|e| DiscoverError::Match("lua_tonumber", e))?;
    let lual_openlibs = find_unique(dis, image, pe, &candidates, |i| {
        patterns::match_lual_openlibs(i, cluster)
    })
    .map_err(|e| DiscoverError::Match("luaL_openlibs", e))?;
    let lual_loadbuffer = find_loadbuffer_via_bytecode(dis, image, pe, cluster)
        .ok_or(DiscoverError::Match(
            "luaL_loadbuffer",
            MatchError::NoCandidate,
        ))
        .and_then(|(lb, loader)| {
            if lb == 0 {
                Err(DiscoverError::Match(
                    "luaL_loadbuffer",
                    MatchError::NoCandidate,
                ))
            } else {
                Ok((lb, loader))
            }
        })?;
    let lua_settop = find_unique(dis, image, pe, &candidates, patterns::match_lua_settop)
        .map_err(|e| DiscoverError::Match("lua_settop", e))?;
    let lua_pcall = find_unique(dis, image, pe, &candidates, patterns::match_lua_pcall)
        .map_err(|e| DiscoverError::Match("lua_pcall", e))?;

    // lua_newstate: backward dataflow trace from the lua_atpanic call inside
    // LuaEnvironment::init (a proven method — a body signature is ambiguous
    // because many functions make indirect calls). The trace yields the CFG
    // thunk callers invoke + the real body it jumps to.
    let (lua_newstate_thunk, lua_newstate_body) =
        find_newstate_via_trace(dis, image, pe, init_begin, init_end, lua_atpanic).ok_or(
            DiscoverError::Match("lua_newstate_body", MatchError::NoCandidate),
        )?;

    let (lual_loadbuffer, lua_resource_bytecode) = lual_loadbuffer;

    Ok(AddressTable {
        lua_newstate_thunk,
        lua_newstate_body,
        lua_atpanic,
        lua_gettop,
        lual_loadbuffer,
        lua_pcall,
        lual_openlibs,
        lua_pushcclosure,
        lua_setfield,
        lua_pushstring,
        lua_tolstring,
        lua_createtable,
        lua_type,
        lua_tonumber,
        lua_settop,
        lua_panic_body: panic_body,
        luaenvironment_init_begin: init_begin,
        luaenvironment_init_end: init_end,
        lua_getfield,
        lua_resource_bytecode,
        lua_getfenv,
        lua_setfenv,
    })
}

// ============================ Method A helpers ============================

/// Find the RVA of `needle` (incl. trailing NUL if given) inside `.rdata`.
fn string_rva(pe: &Pe, image: &[u8], needle: &[u8]) -> Option<u32> {
    let r = pe.rdata();
    let len = core::cmp::min(r.raw_size, r.virtual_size) as usize;
    let (base, slice) = if (r.rva as usize) + len <= image.len() {
        (r.rva as usize, &image[r.rva as usize..r.rva as usize + len])
    } else {
        return None;
    };
    let off = slice.windows(needle.len()).position(|w| w == needle)?;
    Some((base + off) as u32)
}

/// `lua_panic` body: the string anchor
/// `stingray::LuaEnvironment::Internal::lua_panic` is self-referential (the
/// function logs its own name), so its first LEA-xref's containing function IS
/// `lua_panic` itself.
fn method_a_lua_panic_body(pe: &Pe, image: &[u8], _dis: &mut Disassembler) -> Option<u32> {
    let anchor = b"stingray::LuaEnvironment::Internal::lua_panic\x00";
    let rva = string_rva(pe, image, anchor)?;
    let mut sites = Vec::new();
    find_lea_xrefs(pe, image, rva, &mut sites);
    // The first xref site's containing .pdata function is lua_panic's body.
    let site = *sites.first()?;
    pe.find_runtime_function(site).map(|rf| rf.begin)
}

/// `LuaEnvironment::init`: the largest `.pdata` function that takes the address
/// of `lua_panic` (the `&lua_panic` passed to `lua_atpanic` during init).
fn method_a_luaenv_init(pe: &Pe, image: &[u8], lua_panic_body: u32) -> Option<(u32, u32)> {
    // LEA refs to the lua_panic body address (the &lua_panic takes), plus
    // direct E8 callers as a defensive fallback.
    let mut sites = Vec::new();
    find_lea_xrefs(pe, image, lua_panic_body, &mut sites);
    find_callers(pe, image, lua_panic_body, &mut sites);

    // Map each site to its containing .pdata function, dedup, pick largest.
    let mut best: Option<(u32, u32)> = None;
    for site in &sites {
        let rf = match pe.find_runtime_function(*site) {
            Some(rf) => rf,
            None => continue,
        };
        let size = rf.end - rf.begin;
        best = match best {
            Some((b, e)) if (e - b) >= size => Some((b, e)),
            _ => Some((rf.begin, rf.end)),
        };
    }
    let (begin, end) = best?;
    Some((begin, end))
}

/// The (first) `.pdata` function containing an LEA-xref of the *first*
/// occurrence of `needle` in `.rdata`. Used for the LuaJIT-version cluster
/// anchor.
fn containing_function_of_anchor(pe: &Pe, image: &[u8], needle: &[u8]) -> Option<u32> {
    let rva = string_rva(pe, image, needle)?;
    let mut sites = Vec::new();
    find_lea_xrefs(pe, image, rva, &mut sites);
    let site = *sites.first()?;
    pe.find_runtime_function(site).map(|rf| rf.begin)
}

/// `luaL_loadbuffer` via the `lua_resource::bytecode` anchor (a reliable
/// Method-A trace). The `luaL_load*` wrappers share a body shape, so a cluster
/// scan is ambiguous; instead we find the engine functions that reference the
/// `stingray::lua_resource::bytecode` string (the bytecode-loading path),
/// enumerate their direct calls, and return the unique call target whose body
/// satisfies the lua_load-wrapper signature. That target is `luaL_loadbuffer`
/// — the bytecode path loads buffers, not files/strings.
///
/// Returns `(luaL_loadbuffer_rva, primary_loader_rva)`. `primary_loader` is
/// the first (lowest-address) `.pdata` function that both references the
/// `stingray::lua_resource::bytecode` string AND calls `luaL_loadbuffer` — the
/// engine's bundle-script loader (the `lua_resource::bytecode` anchor
/// function). It is a validated discovery output; it is not hooked directly
/// (unknown C++ signature — the shell hooks `luaL_loadbuffer`/`lua_pcall`, the
/// known-sig LuaJIT C-API, instead).
fn find_loadbuffer_via_bytecode(
    dis: &mut Disassembler,
    image: &[u8],
    pe: &Pe,
    cluster: Cluster,
) -> Option<(u32, u32)> {
    let anchor = b"stingray::lua_resource::bytecode\x00";
    let rva = string_rva(pe, image, anchor)?;
    let mut sites = Vec::new();
    find_lea_xrefs(pe, image, rva, &mut sites);
    // Distinct .pdata functions containing a bytecode-string reference, sorted
    // by start address so the "primary loader" pick is deterministic.
    let mut containing: Vec<(u32, u32)> = Vec::new();
    for site in &sites {
        if let Some(rf) = pe.find_runtime_function(*site) {
            let entry = (rf.begin, rf.end);
            if !containing.contains(&entry) {
                containing.push(entry);
            }
        }
    }
    containing.sort_unstable();
    // Enumerate direct calls from each containing function; collect call
    // targets whose body matches the lua_load-wrapper shape. The first
    // containing function (lowest address) that yields such a call is the
    // primary loader.
    let mut hits: Vec<u32> = Vec::new();
    let mut primary_loader: Option<u32> = None;
    for (begin, end) in &containing {
        let insns = dis.disasm_range(image, *begin, *end);
        for ins in &insns {
            if ins.id != X86_INS_CALL {
                continue;
            }
            let Some(tgt) = parse_branch_target(ins) else {
                continue;
            };
            let t = tgt as u32;
            let (bb, be) = crate::disasm::body_bounds(pe, t);
            let body = dis.disasm_range(image, bb, be);
            if !body.is_empty() && patterns::match_lual_loadbuffer(&body, pe, image, cluster) {
                hits.push(t);
                if primary_loader.is_none() {
                    primary_loader = Some(*begin);
                }
            }
        }
    }
    hits.sort_unstable();
    hits.dedup();
    if hits.len() == 1 {
        Some((hits[0], primary_loader?))
    } else {
        None
    }
}

/// `lua_newstate` via backward dataflow trace from the `lua_atpanic` call
/// inside `LuaEnvironment::init` (the reference implementation's
/// `dt_identify_lua_newstate`).
///
/// Recipe:
///   1. Disassemble the init body; find the `call <lua_atpanic>` site.
///   2. Walk back to `mov rcx, <L src>` (the L feed for atpanic), stopping at
///      another call. Record the source operand (the L slot).
///   3. Walk back to `mov <same slot>, rax` — where newstate's return was
///      stored as L.
///   4. The nearest preceding direct call is `lua_newstate` (a CFG thunk);
///      follow the thunk to the real body.
///
/// Returns `(thunk_rva, body_rva)`.
fn find_newstate_via_trace(
    dis: &mut Disassembler,
    image: &[u8],
    pe: &Pe,
    init_begin: u32,
    init_end: u32,
    atpanic_rva: u32,
) -> Option<(u32, u32)> {
    let insns = dis.disasm_range(image, init_begin, init_end);
    // 1. Find the atpanic call.
    let atpanic_idx = insns
        .iter()
        .position(|i| i.id == X86_INS_CALL && parse_branch_target(i) == Some(atpanic_rva as u64))?;

    // helper: does `ins` write register `reg` (destination is `reg,`)?
    let writes_reg = |ins: &crate::disasm::DecodedInsn, reg: &str| -> bool {
        if !ins.is_mnemonic("mov") {
            return false;
        }
        let op = ins.op_str.trim_start();
        op.starts_with(&format!("{reg},")) || op.starts_with(&format!("{reg} ,")) || op == reg
    };

    // 2. Walk back to `mov rcx, <src>` (stop at another call).
    let lo = atpanic_idx.saturating_sub(20);
    let mut rcx_load_idx = None;
    let mut rcx_source = String::new();
    for b in (lo..atpanic_idx).rev() {
        if insns[b].id == X86_INS_CALL {
            break;
        }
        if writes_reg(&insns[b], "rcx") {
            rcx_load_idx = Some(b);
            if let Some((_dst, src)) = insns[b].op_str.split_once(',') {
                rcx_source = src.trim().to_string();
            }
            break;
        }
    }
    let rcx_load_idx = rcx_load_idx?;

    // Normalize the slot key: bracketed expr if memory operand, else the reg.
    let slot_key = {
        let s = &rcx_source;
        if let (Some(lb), Some(rb)) = (s.find('['), s.find(']')) {
            s[lb..=rb].to_string()
        } else {
            s.clone()
        }
    };

    // 3. Walk back to `mov <same slot>, rax` (newstate's return stored as L).
    let lo2 = rcx_load_idx.saturating_sub(100);
    let mut store_idx = None;
    for b in (lo2..rcx_load_idx).rev() {
        let ins = &insns[b];
        if !ins.is_mnemonic("mov") {
            continue;
        }
        let Some((dst, src)) = ins.op_str.split_once(',') else {
            continue;
        };
        let dst = dst.trim();
        let src = src.trim();
        if src != "rax" {
            continue;
        }
        let dst_key = {
            if let (Some(lb), Some(rb)) = (dst.find('['), dst.find(']')) {
                dst[lb..=rb].to_string()
            } else {
                dst.to_string()
            }
        };
        if dst_key == slot_key {
            store_idx = Some(b);
            break;
        }
    }
    let store_idx = store_idx?;

    // 4. Nearest preceding direct call = lua_newstate (thunk).
    let lo3 = store_idx.saturating_sub(15);
    let mut newstate_target = None;
    for b in (lo3..store_idx).rev() {
        let ins = &insns[b];
        if ins.id != X86_INS_CALL {
            continue;
        }
        if let Some(t) = parse_branch_target(ins) {
            newstate_target = Some(t as u32);
            break;
        }
    }
    let thunk = newstate_target?;

    // Follow the CFG thunk (E9 rel32) to the real body. (The trace result is
    // returned as-is whether or not the thunk resolved to a distinct body —
    // both cases yield the same `(thunk, body)` pair for the caller.)
    let (body, _chain) = crate::scan::trace_thunk(pe, image, thunk, 8);
    Some((thunk, body))
}
