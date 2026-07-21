//! `.text` byte-pattern scanners and thunk resolvers.
//!
//! All operate on an RVA-laid-out `image` and report RVAs. The scanner design
//! (opcodes + offset math) is shared with prior validated implementations of
//! this discovery path, re-implemented here in safe Rust.
//!
//! Covered `.pdata` gap categories (production-spec §".pdata behavior"):
//!   - **CFG/hot-patch thunks** (`E9 rel32 + cc`): followed by [`trace_thunk`].
//!   - **Leaf functions** (no `.pdata`): reached as `E8`/`E9` call targets —
//!     they appear in the candidate-start set produced by
//!     [`direct_call_targets`] / [`collect_function_starts`].
//!   - **Import thunks** (`FF 25 disp32`): resolved via the PE import table
//!     by [`resolve_import_thunk`].

use crate::pe::Pe;

fn check_text(pe: &Pe, image: &[u8]) -> Option<(usize, usize)> {
    let t = pe.text();
    let base = t.rva as usize;
    let len = core::cmp::min(t.raw_size, t.virtual_size) as usize;
    if base + len > image.len() {
        return None;
    }
    Some((base, len))
}

/// `lea reg, [rip + disp32]` sites in `.text` whose target == `target_rva`.
///
/// Matches `48/4C 8D <modrm> <disp32>` with `(modrm & 0xC7) == 0x05`
/// (RIP-relative, no SIB). Target = insn_rva + 7 + disp32. Mirrors the
/// validated C reference `find_lea_xrefs` exactly.
pub fn find_lea_xrefs(pe: &Pe, image: &[u8], target_rva: u32, out: &mut Vec<u32>) {
    let Some((base, len)) = check_text(pe, image) else {
        return;
    };
    if len < 7 {
        return;
    }
    let blob = &image[base..base + len];
    let mut i = 0usize;
    while i + 7 <= len {
        let b0 = blob[i];
        if (b0 == 0x48 || b0 == 0x4C) && blob[i + 1] == 0x8D && (blob[i + 2] & 0xC7) == 0x05 {
            let disp = i32::from_le_bytes([blob[i + 3], blob[i + 4], blob[i + 5], blob[i + 6]]);
            let irva = (base + i) as i64;
            if irva + 7 + disp as i64 == target_rva as i64 {
                out.push(irva as u32);
            }
        }
        i += 1;
    }
}

/// `E8 rel32` call sites in `.text` whose target == `target_rva`.
pub fn find_callers(pe: &Pe, image: &[u8], target_rva: u32, out: &mut Vec<u32>) {
    let Some((base, len)) = check_text(pe, image) else {
        return;
    };
    if len < 5 {
        return;
    }
    let blob = &image[base..base + len];
    let mut i = 0usize;
    while i + 5 <= len {
        if blob[i] == 0xE8 {
            let rel = i32::from_le_bytes([blob[i + 1], blob[i + 2], blob[i + 3], blob[i + 4]]);
            let irva = (base + i) as i64;
            if irva + 5 + rel as i64 == target_rva as i64 {
                out.push(irva as u32);
            }
        }
        i += 1;
    }
}

/// Follow a chain of `E9 rel32` CFG/hot-patch thunks. Returns the final RVA
/// and fills `chain` (including the starting RVA) with each hop. Stops at the
/// first non-`E9` byte, after `max_hops`, or when the next hop leaves `.text`.
pub fn trace_thunk(pe: &Pe, image: &[u8], start: u32, max_hops: usize) -> (u32, Vec<u32>) {
    let mut chain = vec![start];
    let mut cur = start;
    let t = pe.text();
    let lo = t.rva;
    let hi = t.rva + core::cmp::min(t.raw_size, t.virtual_size);
    for _ in 0..max_hops {
        if cur < lo || cur >= hi {
            break;
        }
        let off = cur as usize;
        let p = match image.get(off..off + 5) {
            Some(p) => p,
            None => break,
        };
        if p[0] != 0xE9 {
            break;
        }
        let rel = i32::from_le_bytes([p[1], p[2], p[3], p[4]]);
        cur = (cur as i64 + 5 + rel as i64) as u32;
        chain.push(cur);
    }
    (cur, chain)
}

/// If `rva` points at `FF 25 disp32` (jmp `[rip+disp32]`), resolve the IAT
/// entry to `DLL!name` via the PE import table. Returns `None` otherwise.
pub fn resolve_import_thunk<'a>(pe: &'a Pe, image: &[u8], rva: u32) -> Option<(&'a str, &'a str)> {
    let p = image.get(rva as usize..rva as usize + 6)?;
    if p[0] != 0xFF || p[1] != 0x25 {
        return None;
    }
    let disp = i32::from_le_bytes([p[2], p[3], p[4], p[5]]);
    let iat_rva = (rva as i64 + 6 + disp as i64) as u32;
    pe.import_lookup(iat_rva)
}

/// Every direct `E8 rel32` call target inside `.text` (deduplicated, sorted).
/// These are function entry points — including leaf functions that have no
/// `.pdata` entry (e.g. `lua_gettop`, `lua_atpanic`), which is how we reach
/// `.pdata`-gap code without an exhaustive linear sweep.
pub fn direct_call_targets(pe: &Pe, image: &[u8]) -> Vec<u32> {
    let Some((base, len)) = check_text(pe, image) else {
        return Vec::new();
    };
    let blob = &image[base..base + len];
    let mut set = Vec::new();
    let mut i = 0usize;
    while i + 5 <= len {
        if blob[i] == 0xE8 {
            let rel = i32::from_le_bytes([blob[i + 1], blob[i + 2], blob[i + 3], blob[i + 4]]);
            let irva = (base + i) as i64;
            let tgt = (irva + 5 + rel as i64) as u32;
            // Keep only targets inside .text (drop self-relative junk / data).
            if (tgt as i64) >= base as i64 && (tgt as usize) < base + len {
                set.push(tgt);
            }
        }
        i += 1;
    }
    set.sort_unstable();
    set.dedup();
    set
}
