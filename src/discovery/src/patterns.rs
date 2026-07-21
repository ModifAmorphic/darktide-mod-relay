//! Method B — source-pattern matching for the 16 LuaJIT / engine functions.
//!
//! Each target function has a *signature*: a set of observable consequences
//! of its LuaJIT-2.1 / Stingray source, observable in capstone's Intel-syntax
//! disassembly (struct offsets, TValue tag constants, loop back-edges, call
//! counts, distinctive instructions like `movabs` magic constants). A matcher
//! returns `true` iff the disassembled body exhibits every feature.
//!
//! These signatures are derived from the LuaJIT 2.1 / Stingray source bodies,
//! with one deliberate choice: **no hardcoded absolute addresses**. Helper-call
//! checks are relaxed to "a direct call within the live LuaJIT cluster" and
//! cluster bounds are computed at runtime from the discovered cluster window.
//! The remaining self-contained features (tags, offsets, loop edges, magic
//! constants, call counts) are what the evidence shows to be unique over the
//! cluster — and uniqueness is asserted empirically by the oracle Tier-2 test
//! (`tests/oracle.rs`).

use crate::disasm::{
    body_end_rva, parse_branch_target, DecodedInsn, Disassembler, X86_INS_CALL, X86_INS_JLE,
    X86_INS_JNE, X86_INS_LEA, X86_INS_MOVABS, X86_INS_RET, X86_INS_TEST,
};
use crate::pe::Pe;

/// A discovered LuaJIT cluster window (RVA range) plus the discovered address
/// of the `_PRELOAD` string (the `luaL_openlibs` anchor).
#[derive(Debug, Clone, Copy)]
pub struct Cluster {
    pub lo: u32,
    pub hi: u32,
    pub preload_str_rva: u32,
}

/// Why a finder failed (used by the oracle test to report precisely).
#[derive(Debug, Clone)]
pub enum MatchError {
    NoCandidate,
    Ambiguous(Vec<u32>),
}

/// Feature: count direct (`call rel32`) calls in the body. capstone prints the
/// absolute target for a direct call (op_str starts with a hex digit).
fn direct_call_targets(insns: &[DecodedInsn]) -> Vec<u64> {
    insns
        .iter()
        .filter(|i| i.id == X86_INS_CALL)
        .filter_map(|i| {
            let o = i.op_str.trim();
            if let Some(h) = o.strip_prefix("0x") {
                u64::from_str_radix(h, 16).ok()
            } else if !o.is_empty() && o.starts_with(|c: char| c.is_ascii_digit()) {
                u64::from_str_radix(o, 16).ok()
            } else {
                None
            }
        })
        .collect()
}

/// Count indirect calls (`call qword ptr [..]` / `call reg`): calls whose
/// op_str is NOT a bare hex address.
fn count_indirect_calls(insns: &[DecodedInsn]) -> usize {
    insns
        .iter()
        .filter(|i| i.id == X86_INS_CALL)
        .filter(|i| {
            let o = i.op_str.trim();
            !(o.starts_with("0x")
                || (o.starts_with(|c: char| c.is_ascii_digit()) && !o.starts_with("0x")))
        })
        .count()
}

fn count_backward(insns: &[DecodedInsn], id: u32) -> usize {
    insns
        .iter()
        .filter(|i| i.id == id)
        .filter(|i| {
            parse_branch_target(i)
                .map(|t| t < i.address)
                .unwrap_or(false)
        })
        .count()
}

fn has_const_in_op(insns: &[DecodedInsn], needle: &str) -> bool {
    insns.iter().any(|i| i.op_str.contains(needle))
}

/// Cluster-bound check for a call target.
fn in_cluster(c: Cluster, v: u64) -> bool {
    (v as u32) >= c.lo && (v as u32) < c.hi
}

// ============================ leaf matchers ============================

/// `lua_gettop(L)` leaf: `mov rax,[rcx+0x18]; sub rax,[rcx+0x10]; sar rax,3; ret`
/// (top - base)>>3. Capstone prints `[rcx + 0x18]` / `[rcx + 0x10]`.
pub fn match_lua_gettop(insns: &[DecodedInsn]) -> bool {
    if insns.len() < 4 {
        return false;
    }
    insns[0].is_mnemonic("mov")
        && insns[0].op_contains("rax")
        && (insns[0].op_contains("[rcx + 0x18]") || insns[0].op_contains("[rcx + 18]"))
        && insns[1].is_mnemonic("sub")
        && (insns[1].op_contains("[rcx + 0x10]") || insns[1].op_contains("[rcx + 10]"))
        && (insns[2].is_mnemonic("sar") || insns[2].is_mnemonic("shr"))
        && (insns[2].op_contains(", 3") || insns[2].op_contains(", 0x3"))
        && (insns[3].id == X86_INS_RET)
}

/// `lua_atpanic(L, fn)` leaf: reads `[rcx+8]` (global_State*), swaps `rdx`
/// into `[g+0x118]` (panic fn slot), returns previous. Robust to the
/// `mov r8d,[rcx+8]` (32-bit) vs `mov r8,[rcx+8]` (64-bit) variants.
pub fn match_lua_atpanic(insns: &[DecodedInsn]) -> bool {
    if insns.is_empty() {
        return false;
    }
    let last_ret = insns.last().map(|i| i.id == X86_INS_RET).unwrap_or(false);
    if !last_ret {
        return false;
    }
    // a read of [rcx + 8]
    let reads_glref = insns.iter().any(|i| {
        i.op_contains("[rcx + 8]")
            && (i.op_contains("r8") || i.op_contains("eax") || i.op_contains("rax"))
    });
    // two accesses to offset 0x118 (the panic-fn slot): one load into rax,
    // one store of rdx.
    let load_118_rax = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("rax") && i.op_contains("0x118]"));
    let store_118_rdx = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("0x118]") && i.op_contains("rdx"));
    reads_glref && load_118_rax && store_118_rdx
}

// ============================ body matchers ============================

/// `lua_pcall(L, nargs, nresults, errfunc)` — the validated reference
/// implementation's rich feature set (production-spec / `disasm_check.c`).
pub fn match_lua_pcall(insns: &[DecodedInsn]) -> bool {
    let mut reads_glref = false; // [..+8]
    let mut reads_base = false; // [..+0x10]
    let mut reads_top = false; // [..+0x18]
    let mut reads_stack = false; // [..+0x24]
    let mut test_r9 = false;
    let mut jne = false;
    let mut jle = false;
    let mut lea_r9x8 = false;
    let mut inc_r8 = false;
    let mut saw_shl_rax_3 = false;
    let mut shl_sub = false;
    for ins in insns {
        let o = &ins.op_str;
        if o.contains("+ 8]") || o.contains("+ 0x8]") {
            reads_glref = true;
        }
        if o.contains("+ 0x10]") {
            reads_base = true;
        }
        if o.contains("+ 0x18]") {
            reads_top = true;
        }
        if o.contains("+ 0x24]") {
            reads_stack = true;
        }
        if ins.id == X86_INS_TEST && (o.contains("r9") || o.contains("r9d")) {
            test_r9 = true;
        }
        if ins.id == X86_INS_JNE {
            jne = true;
        }
        if ins.id == X86_INS_JLE {
            jle = true;
        }
        if ins.id == X86_INS_LEA && o.contains("r9*8") {
            lea_r9x8 = true;
        }
        if ins.is_mnemonic("inc") && (o.contains("r8") || o.contains("r8d")) {
            inc_r8 = true;
        }
        // api_call_base = L->top - nargs*8: `shl rax,3` then `sub rdx,rax`.
        if (ins.is_mnemonic("shl") || ins.is_mnemonic("sal"))
            && (o.contains("rax, 3") || o.contains("eax, 3") || o.contains("rax, 0x3"))
        {
            saw_shl_rax_3 = true;
        }
        if saw_shl_rax_3
            && ins.is_mnemonic("sub")
            && (o.contains("rdx, rax") || o.contains("edx, eax"))
        {
            shl_sub = true;
        }
    }
    let calls = direct_call_targets(insns);
    reads_glref
        && reads_base
        && reads_top
        && reads_stack
        && test_r9
        && jne
        && jle
        && lea_r9x8
        && inc_r8
        && shl_sub
        && calls.len() == 1
}

/// `lua_pushcclosure(L, f, n)`: `movsxd` of `r8d`, ≥1 backward `jne`
/// (upvalue-copy loop), writes `0xfffffff7` (LJ_TFUNC), exactly 3 direct calls.
pub fn match_lua_pushcclosure(insns: &[DecodedInsn], c: Cluster) -> bool {
    let movsxd = insns
        .iter()
        .any(|i| i.is_mnemonic("movsxd") && (i.op_contains("r8d") || i.op_contains("r8b")));
    let bw_jne = count_backward(insns, X86_INS_JNE) >= 1;
    let func_tag = has_const_in_op(insns, "0xfffffff7");
    let calls = direct_call_targets(insns);
    let all_in_cluster = calls.iter().all(|&t| in_cluster(c, t));
    movsxd && bw_jne && func_tag && calls.len() == 3 && all_in_cluster
}

/// `lua_setfield(L, idx, k)`: prologue saves `mov rsi, rcx` AND `mov rbx, r8`,
/// writes `0xfffffffb` (LJ_TSTR key tag), ends `lea rcx,[rdx-8]; mov
/// [rsi+0x18],rcx` (L->top--), exactly 4 direct calls.
pub fn match_lua_setfield(insns: &[DecodedInsn], _c: Cluster) -> bool {
    if insns.len() < 8 {
        return false;
    }
    let prologue = insns[..8]
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "rsi, rcx");
    let prologue2 = insns[..8]
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "rbx, r8");
    let str_tag = has_const_in_op(insns, "0xfffffffb");
    // L->top-- cleanup: lea rcx,[rdx - 8] then mov [rsi + 0x18], rcx
    let mut top_dec = false;
    for i in 0..insns.len().saturating_sub(1) {
        let a = &insns[i];
        let b = &insns[i + 1];
        if a.id == X86_INS_LEA
            && a.op_contains("rcx")
            && (a.op_contains("[rdx - 8]") || a.op_contains("[rdx - 0x8]"))
            && b.is_mnemonic("mov")
            && b.op_contains("[rsi + 0x18]")
        {
            top_dec = true;
        }
    }
    // Call count (4 in the pinned build, 5 in newer builds — one call targets
    // the string-intern cluster outside the LuaJIT API window) and the cluster
    // range are build-specific, so we key only on the three self-contained
    // features above, which the reference evidence shows are unique over the
    // cluster.
    prologue && prologue2 && str_tag && top_dec
}

/// `lua_getfield(L, idx, k)`: the symmetric sibling of `lua_setfield` — same
/// prologue (`mov rsi, rcx` saves L, `mov rbx, r8` saves k) and same
/// `0xfffffffb` (LJ_TSTR key tag) from `setstrV(&key, luaS_new(L, k))`, but
/// ends with `api_incr_top` (`L->top++`) instead of `L->top--`. The `top++`
/// epilogue (and the absence of setfield's `top--`) is the discriminator vs
/// `lua_setfield`.
///
/// This is a validated LuaJIT C-API anchor: `lua_getfield(L, LUA_GLOBALSINDEX,
/// name)` is what `lua_getglobal` expands to, so `lua_getfield` is discovered
/// alongside the 16 as part of the stable address table.
pub fn match_lua_getfield(insns: &[DecodedInsn], _c: Cluster) -> bool {
    if insns.len() < 8 {
        return false;
    }
    let prologue = insns[..8]
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "rsi, rcx");
    let prologue2 = insns[..8]
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "rbx, r8");
    let str_tag = has_const_in_op(insns, "0xfffffffb");
    // setfield's L->top-- epilogue: `lea rcx,[rdx - 8]; mov [rsi + 0x18],rcx`.
    // getfield must NOT exhibit this (it increments top instead).
    let mut has_top_dec = false;
    // getfield's api_incr_top (L->top++) — load-add-store compile shape:
    // `lea <reg>,[<topreg> + 8]; mov [rsi + 0x18],<reg>`.
    let mut has_top_inc_lea = false;
    for i in 0..insns.len().saturating_sub(1) {
        let a = &insns[i];
        let b = &insns[i + 1];
        if a.id == X86_INS_LEA
            && (a.op_contains("[rdx - 8]") || a.op_contains("[rdx - 0x8]"))
            && b.is_mnemonic("mov")
            && b.op_contains("[rsi + 0x18]")
        {
            has_top_dec = true;
        }
        if a.id == X86_INS_LEA
            && (a.op_contains("+ 8]") || a.op_contains("+ 0x8]"))
            && !a.op_contains(" - 8]")
            && !a.op_contains(" - 0x8]")
            && b.is_mnemonic("mov")
            && b.op_contains("[rsi + 0x18]")
        {
            has_top_inc_lea = true;
        }
    }
    // getfield's api_incr_top — direct-add compile shape:
    // `add qword [rsi + 0x18], 8`.
    let has_top_inc_add = insns.iter().any(|i| {
        i.is_mnemonic("add")
            && i.op_contains("[rsi + 0x18]")
            && (i.op_contains(", 8") || i.op_contains(", 0x8"))
    });
    prologue && prologue2 && str_tag && !has_top_dec && (has_top_inc_add || has_top_inc_lea)
}

/// `lua_pushstring(L, s)`: `test rdx, rdx` + `jne` (the `if (str==NULL)` check),
/// then the NULL branch writes the NIL tag via `mov dword [reg+4], 0xffffffff`
/// (setnilV) and the else branch writes the STR tag `0xfffffffb` (setstrV).
/// The setnilV `+4]` store is the discriminator that separates pushstring from
/// other functions that merely reference `0xffffffff`.
pub fn match_lua_pushstring(insns: &[DecodedInsn], _c: Cluster) -> bool {
    let test_rdx = insns
        .iter()
        .any(|i| i.id == X86_INS_TEST && (i.op_contains("rdx") || i.op_contains("edx")));
    let has_jne = insns.iter().any(|i| i.id == X86_INS_JNE);
    let setnil = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("+ 4], 0xffffffff"));
    let setstr = has_const_in_op(insns, "0xfffffffb");
    let calls = direct_call_targets(insns);
    test_rdx && has_jne && setnil && setstr && (3..=6).contains(&calls.len())
}

/// `lua_tolstring(L, idx, len*)`: `add rax, 0x14` (strdata, sizeof GCstr=0x14),
/// then the `if (len != NULL) *len = s->len` epilogue: `test rdi, rdi` (NULL
/// check on the len out-param, which was saved from r8) + a store to `[rdi]`
/// (the `*len` write), reading `s->len` from `[reg + 0x10]`. The `[rdi]`
/// out-param write is the discriminator vs other string-returning functions.
pub fn match_lua_tolstring(insns: &[DecodedInsn]) -> bool {
    // 3-arg prologue (L, idx, len*): len* (r8) saved into rdi. The 4-arg
    // sibling (lua_objlen &c.) saves r9→rdi / r8→rbx instead, so this fixes
    // the register-arg shape that the shared type-check features alone can't.
    let prologue = insns
        .iter()
        .take(12)
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "rdi, r8");
    let strdata = insns
        .iter()
        .any(|i| i.is_mnemonic("add") && i.op_contains("rax, 0x14"));
    // len* NULL check (len* was saved into rdi from r8 in the prologue).
    let len_null = insns
        .iter()
        .any(|i| i.id == X86_INS_TEST && (i.op_contains("rdi") || i.op_contains("r8")));
    // *len = s->len : a mov whose *destination* is `[rdi]` (or `[r8]`).
    let len_write = insns.iter().any(|i| {
        if !i.is_mnemonic("mov") {
            return false;
        }
        let dest = i.op_str.split(',').next().unwrap_or("");
        dest.contains("[rdi]") || dest.contains("[r8]")
    });
    // s->len read at GCstr+0x10.
    let len_read = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("+ 0x10]"));
    // Number-coercion branch: cmp <tag>, 0xfffeffff (LJ_TISNUM) — tolstring
    // converts numbers to strings, the discriminator vs other len-out-param
    // string helpers.
    let num_check = has_const_in_op(insns, "0xfffeffff");
    // setstrV: `mov dword [reg + 4], 0xfffffffb` — tolstring *creates* a string
    // TValue from a number on the coercion path. Length-returning siblings
    // (lua_objlen &c.) share the type-check + len-out-param shape but never
    // write the STR tag, so this is the clinching discriminator.
    let setstr = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("+ 4], 0xfffffffb"));
    strdata && len_null && len_write && len_read && num_check && setstr && prologue
}

/// `lua_createtable(L, narray, nrec)`: writes `0xfffffff4` (LJ_TTAB) via
/// settabV, `add [reg+0x18], 8` (incr_top), and — the discriminator vs other
/// table-pushers (settable/rawset operate on *existing* tables) — its prologue
/// reads `[rcx + 8]` (global_State, for the inline GC-threshold check) and
/// saves the two integer size args (`r8d`/`edx`), not pointer args.
pub fn match_lua_createtable(insns: &[DecodedInsn]) -> bool {
    let tab_tag = has_const_in_op(insns, "0xfffffff4");
    let top_inc = insns.iter().any(|i| {
        i.is_mnemonic("add")
            && i.op_contains("+ 0x18]")
            && (i.op_contains(", 8") || i.op_contains(", 0x8"))
    });
    // Prologue: read global_State ([rcx + 8]) + save the nrec int arg (r8d).
    let prologue = insns
        .iter()
        .take(12)
        .any(|i| i.is_mnemonic("mov") && i.op_contains("[rcx + 8]"))
        && insns
            .iter()
            .take(12)
            .any(|i| i.is_mnemonic("mov") && i.op_contains("r8d"));
    // Creates a fresh table → calls a table-allocation helper (lj_tab_new_ah).
    let calls = direct_call_targets(insns);
    tab_tag && top_inc && prologue && !calls.is_empty()
}

/// `lua_type(L, idx)`: `movabs rax, 0x75a0698042110` (the globally-unique
/// type-lookup constant) + exactly 1 direct call (index2adr). The constant
/// alone is unique in the whole binary.
pub fn match_lua_type(insns: &[DecodedInsn]) -> bool {
    let magic = insns
        .iter()
        .any(|i| i.id == X86_INS_MOVABS && i.op_contains("0x75a0698042110"));
    let calls = direct_call_targets(insns);
    magic && calls.len() == 1
}

/// `lua_tonumber(L, idx)`: calls index2adr → `rax` = the TValue; reads the tag
/// from `[rax + 4]`, checks the number tag `0xfffeffff`, and returns the
/// double via `movsd xmm0, [rax]` (the number value at the same TValue base).
/// The `[rax+4]` tag read + `[rax]` movsd pair is the discriminator vs the
/// many functions that merely reference the `0xfffffffb`/`0xfffeffff` tags.
pub fn match_lua_tonumber(insns: &[DecodedInsn]) -> bool {
    let num_tag = has_const_in_op(insns, "0xfffeffff")
        || insns
            .iter()
            .any(|i| i.is_mnemonic("cmp") && i.op_contains("-131073"));
    // tag read from the index2adr-returned TValue: mov <reg>, [rax + 4]
    let tag_read = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("[rax + 4]"));
    // number value from the same TValue base: movsd xmm0, [rax]  (no offset)
    let movsd = insns
        .iter()
        .any(|i| i.is_mnemonic("movsd") && i.op_contains("xmm0") && i.op_contains("[rax]"));
    // 2-arg public entry: idx (edx) → ebx, L (rcx) → rdi. The 3-arg
    // lua_tonumberx saves r8 (the ok* out-param) too, so this prologue shape
    // separates tonumber from its sibling + the internal checkers.
    let prologue = insns
        .iter()
        .take(10)
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "ebx, edx")
        && insns
            .iter()
            .take(10)
            .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "rdi, rcx");
    // lua_tointeger reads the same double (`movsd xmm0,[rax]`) but then
    // `cvttsd2si`-converts it to an int (returns in rax). tonumber returns the
    // double directly, so the absence of cvttsd2si separates them.
    let no_int_convert = !insns.iter().any(|i| i.is_mnemonic("cvttsd2si"));
    // A sibling "number-with-default" helper returns a passed-in default
    // (`movaps xmm0, xmm2`) on the nil branch; the public lua_tonumber takes
    // no default, so it never references xmm2.
    let no_default_param = !insns.iter().any(|i| i.op_contains("xmm2"));
    num_tag && tag_read && movsd && prologue && no_int_convert && no_default_param && {
        let n = direct_call_targets(insns).len();
        (1..=3).contains(&n)
    }
}

/// `luaL_openlibs(L)`: LEA targeting the `_PRELOAD` string, ≥5 distinct direct
/// call targets, ≥1 backward `jne` (two registration loops).
pub fn match_lual_openlibs(insns: &[DecodedInsn], c: Cluster) -> bool {
    let preload = insns.iter().any(|i| {
        i.id == X86_INS_LEA && crate::disasm::rip_relative_target(i) == Some(c.preload_str_rva)
    });
    let calls = direct_call_targets(insns);
    let distinct = {
        let mut v = calls.clone();
        v.sort_unstable();
        v.dedup();
        v.len()
    };
    let bw_jne = count_backward(insns, X86_INS_JNE) >= 1;
    // openlibs is small (~0xc2 bytes); per-lib luaopen_* siblings that also
    // reference _PRELOAD are much larger (0x200+). Bound the body size.
    let body_size = insns
        .last()
        .map(|l| (l.address + l.size as u64) as u32)
        .unwrap_or(0)
        .saturating_sub(insns.first().map(|f| f.address as u32).unwrap_or(0));
    preload && calls.len() >= 5 && distinct >= 5 && bw_jne && body_size <= 0x200
}

/// `lua_settop(L, idx)`: sets `L->top = (idx >= 0) ? base + idx - 1 : top + idx`.
/// Distinctive: it sign-extends the idx arg (`movsxd <reg>, edx`) and scales by
/// the TValue size (`shl <reg>, 3`), then writes `[L + 0x18]` (L->top). The
/// idx-scale + top-write pair separates it from other single-call stack readers.
pub fn match_lua_settop(insns: &[DecodedInsn]) -> bool {
    // idx → byte offset: movsxd <reg>, edx ; shl <reg>, 3
    let idx_scale = insns
        .iter()
        .any(|i| i.is_mnemonic("movsxd") && i.op_contains("edx"))
        && insns
            .iter()
            .any(|i| (i.is_mnemonic("shl") || i.is_mnemonic("sal")) && i.op_contains(", 3"));
    // Writes L->top: a mov whose *destination* (before the comma) is `[reg + 0x18]`.
    let writes_top = insns.iter().any(|i| {
        if !i.is_mnemonic("mov") {
            return false;
        }
        let before = i.op_str.split(',').next().unwrap_or("");
        before.contains("+ 0x18]")
    });
    let reads_stack = insns.iter().any(|i| {
        i.is_mnemonic("mov")
            && (i.op_contains("[rcx + 0x10]")
                || i.op_contains("[rcx + 0x18]")
                || i.op_contains("[rbx + 0x10]")
                || i.op_contains("[rbx + 0x18]"))
    });
    let calls = direct_call_targets(insns);
    idx_scale && writes_top && reads_stack && calls.len() == 1
}

/// `lua_newstate` body shape: a small (~100-300B) function that makes ≥2
/// indirect calls through the first/second argument (the user allocator fn
/// pointer). Most cluster functions call direct LuaJIT helpers; newstate is
/// the CFG-thunked entry whose body invokes the allocator twice (once for the
/// `lua_State`, once for the stack).
pub fn match_lua_newstate_body(insns: &[DecodedInsn]) -> bool {
    let indirect = count_indirect_calls(insns);
    // newstate never writes a TValue tag (it's not a stack mutator).
    let no_tvalue_tag =
        !has_const_in_op(insns, "0xfffffff") && !has_const_in_op(insns, "0xfffeffff");
    indirect >= 2 && no_tvalue_tag
}

/// `luaL_loadbuffer` shape: a small (<400B) wrapper that calls exactly one
/// much-larger internal function (`lua_load`, >8000B by `.pdata`). Mirrors the
/// reference `lua_load_wrapper_candidate` classifier; the one-large-callee
/// shape disambiguates it from the other `luaL_load*` wrappers in the cluster
/// (which the reference implementation further pinned via the
/// `lua_resource::bytecode` call-site context — here uniqueness is asserted
/// empirically by the oracle Tier-2 test).
pub fn match_lual_loadbuffer(insns: &[DecodedInsn], pe: &Pe, image: &[u8], _c: Cluster) -> bool {
    // luaL_loadbuffer(L, buf, size, name): the wrapper tests the `name` arg
    // (r9) for NULL and sets up a large stack frame (sub rsp, ≥0x80) to hold
    // lua_load's lex state, then calls lua_load. The large frame distinguishes
    // it from the thin lua_pcall wrapper (which also tests r9 but has a small
    // frame). Call count varies across builds (1 in the pinned build, 3 in
    // newer ones), so we require: name-NULL-test + large frame + a call into
    // lua_load (a large .pdata callee, or the low lj_vm asm entry <0x10000).
    let test_name = insns
        .iter()
        .any(|i| i.id == X86_INS_TEST && (i.op_contains("r9") || i.op_contains("r9d")));
    let big_frame = sub_rsp_imm(insns).map(|v| v >= 0x80).unwrap_or(false);
    let calls = direct_call_targets(insns);
    let has_load_callee = calls
        .iter()
        .any(|&t| callee_body_size(pe, image, t as u32) > 8000 || t < 0x10_000);
    test_name && big_frame && !calls.is_empty() && has_load_callee
}

/// Extract the immediate of a `sub rsp, <imm>` prologue instruction, if any.
fn sub_rsp_imm(insns: &[DecodedInsn]) -> Option<u32> {
    for i in insns {
        if !i.is_mnemonic("sub") {
            continue;
        }
        let rest = i.op_str.strip_prefix("rsp, ")?;
        let v = if let Some(h) = rest.strip_prefix("0x") {
            u32::from_str_radix(h, 16).ok()
        } else {
            rest.parse::<u32>().ok()
        };
        return v;
    }
    None
}

/// Best-effort callee body size: follow E9 thunk hop(s) then read `.pdata`.
fn callee_body_size(pe: &Pe, image: &[u8], rva: u32) -> u32 {
    let (real, _chain) = crate::scan::trace_thunk(pe, image, rva, 8);
    if let Some(rf) = pe.find_runtime_function(real) {
        return rf.end - rf.begin;
    }
    if rva != real {
        if let Some(rf) = pe.find_runtime_function(rva) {
            return rf.end - rf.begin;
        }
    }
    0
}

/// `lua_getfenv(L, idx)`: the symmetric sibling of `lua_setfenv` — same
/// `index2adr(L, idx)` prologue and the same func/udata/thread type-check
/// triple (LJ_TFUNC/LJ_TUDATA/LJ_TTHREAD), but it *pushes* the object's env
/// table (settabV → `0xfffffff4` LJ_TTAB), or NIL (`0xffffffff`, setnilV) for
/// any other type, then `api_incr_top` (`L->top++`). The `top++` epilogue (and
/// the absence of setfenv's `top--`) is the discriminator vs `lua_setfenv`.
///
/// This is a validated LuaJIT C-API anchor: `lua_getfenv(L, idx)` reads a
/// func/udata/thread's env table. It is discovered alongside the 16 as part of
/// the stable address table.
///
/// Source (LuaJIT 2.1 `lj_api.c`): for func → `tabref(funcV(o)->c.env)`,
/// udata → `tabref(udataV(o)->env)`, thread → `tabref(threadV(o)->env)` (the
/// thread `env` field, offset 0x2c in this build — the thread's globals
/// table). The thread-globals read at `+0x2c` is the clinching discriminator:
/// it is the only `(L, idx)` API function that reads `obj + 0x2c`.
pub fn match_lua_getfenv(insns: &[DecodedInsn]) -> bool {
    // Pushes the env as a TABLE (settabV writes the LJ_TTAB tag 0xfffffff4 to
    // the pushed TValue's tag byte at +4) — and pushes NIL (0xffffffff) for the
    // non-func/udata/thread else branch. This TAB-or-NIL push pair is unique to
    // getfenv: createtable pushes only TAB (never NIL); pushnil/pushstring push
    // only NIL-type tags (never TAB).
    let pushes_tab = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("0xfffffff4") && i.op_contains("4]"));
    let pushes_nil = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("0xffffffff") && i.op_contains("4]"));
    // api_incr_top (L->top++): `add qword [reg + 0x18], 8`.
    let incr_top = insns.iter().any(|i| {
        i.is_mnemonic("add")
            && i.op_contains("+ 0x18]")
            && (i.op_contains(", 8") || i.op_contains(", 0x8"))
    });
    // Reads the thread globals from obj + 0x2c (threadV(o)->env): a `mov` whose
    // SOURCE contains `0x2c]`. getfenv reads this; setfenv WRITES it (the dest
    // contains 0x2c). The read alone is shared with setfenv, but combined with
    // the TAB+NIL push + incr_top it is unique to getfenv.
    let reads_thread_env = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("0x2c]"));
    // Exactly one direct call (index2adr). The stack-grow path is a tail `jmp`,
    // not a `call`, so the direct-call count is 1.
    let calls = direct_call_targets(insns);
    pushes_tab && pushes_nil && incr_top && reads_thread_env && calls.len() == 1
}

/// `lua_setfenv(L, idx)`: the symmetric sibling of `lua_getfenv` — same
/// `index2adr(L, idx)` prologue and func/udata/thread type-check triple, but
/// it *reads* the env table from `L->top-1` (the value the caller pushed),
/// writes it into the object's env field (func/udata → `+0x8`, thread →
/// `+0x2c` = `threadV(o)->env`, the thread's globals), runs a GC write
/// barrier, then `L->top--` (pops the env) and returns 1 (set) or 0 (type
/// didn't match). The `top--` epilogue (and the `+0x2c` *write*) is the
/// discriminator vs `lua_getfenv`.
///
/// This is a validated LuaJIT C-API anchor: `lua_setfenv` has the known
/// LuaJIT signature `int (lua_State*, int)`, so it is safe to discover and
/// (unlike the unknown-sig `lua_resource::bytecode`) would be safe to detour
/// if a future shell needed to observe env assignment. Discovered alongside
/// the 16 as part of the stable address table.
///
/// Source (LuaJIT 2.1 `lj_api.c`): `lua_setfenv` stores `obj2gco(t)` into
/// `funcV(o)->c.env` / `udataV(o)->env` / `threadV(o)->env`, calls
/// `lj_gc_objbarrier`, does `L->top--`, returns `(o != NULL)`.
pub fn match_lua_setfenv(insns: &[DecodedInsn]) -> bool {
    // WRITES the env into the thread globals field obj + 0x2c
    // (`setgcref(threadV(o)->env, ...)`): a `mov` whose DESTINATION (before the
    // comma) contains `0x2c]`. This is the clinching discriminator — getfenv
    // only *reads* +0x2c (source, not dest), and `lua_setmetatable` writes the
    // metatable at +0x10, not +0x2c.
    let writes_thread_env = insns.iter().any(|i| {
        if !i.is_mnemonic("mov") {
            return false;
        }
        let dest = i.op_str.split(',').next().unwrap_or("");
        dest.contains("0x2c]")
    });
    // L->top-- (pops the env the caller pushed): `add qword [reg + 0x18], -8`.
    let top_dec = insns.iter().any(|i| {
        i.is_mnemonic("add")
            && i.op_contains("+ 0x18]")
            && (i.op_contains(", -8") || i.op_contains(", -0x8"))
    });
    // Reads the env from L->top-1: a `mov` reading `[reg + 0x18]` (L->top) into
    // a register, then that register is adjusted by -8 to point at the env
    // TValue. We key on the L->top read + a reg-relative `-8` adjust.
    let reads_top = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_contains("+ 0x18]"));
    // Returns int: the matched branch sets `mov eax, 1`; the else branch
    // `xor eax, eax`. Both appear (two return paths).
    let ret_one = insns
        .iter()
        .any(|i| i.is_mnemonic("mov") && i.op_str.trim() == "eax, 1");
    let ret_zero = insns
        .iter()
        .any(|i| i.is_mnemonic("xor") && i.op_str.trim() == "eax, eax");
    // 2 direct calls: index2adr + lj_gc_objbarrier. Allow 1..=3 for build
    // variance (barrier may be inlined); uniqueness comes from the features above.
    let calls = direct_call_targets(insns);
    writes_thread_env
        && top_dec
        && reads_top
        && ret_one
        && ret_zero
        && (1..=3).contains(&calls.len())
}

// ============================ candidate scanning ============================

/// Build the candidate function-start set for a window: every `.pdata`
/// `RUNTIME_FUNCTION.begin` in `[lo,hi)` plus every direct `E8`/`E9` target in
/// `[lo,hi)` (the latter reaches leaf functions in `.pdata` gaps such as
/// `lua_gettop`/`lua_atpanic`). Deduplicated and sorted.
pub fn candidate_starts(pe: &Pe, image: &[u8], lo: u32, hi: u32) -> Vec<u32> {
    let mut out: Vec<u32> = pe
        .runtime_functions
        .iter()
        .filter(|rf| rf.begin >= lo && rf.begin < hi)
        .map(|rf| rf.begin)
        .collect();
    for t in crate::scan::direct_call_targets(pe, image) {
        if t >= lo && t < hi {
            out.push(t);
        }
    }
    // Also include E9 thunk starts in the window (CFG thunks like
    // lua_newstate's entry sit in .pdata gaps and are reached via E9).
    let txt_lo = pe.text().rva;
    let blob_lo = txt_lo as usize;
    let blob_len = core::cmp::min(pe.text().raw_size, pe.text().virtual_size) as usize;
    if blob_lo + blob_len <= image.len() {
        let blob = &image[blob_lo..blob_lo + blob_len];
        let mut i = 0usize;
        while i + 5 <= blob_len {
            if blob[i] == 0xE9 {
                let site = (blob_lo + i) as u32;
                if site >= lo && site < hi {
                    out.push(site);
                }
            }
            i += 1;
        }
    }
    out.sort_unstable();
    out.dedup();
    out
}

/// Scan candidates and return the unique RVA whose body satisfies `matcher`.
/// `body(insns)` decides leaf-vs-bounded disassembly per candidate.
pub fn find_unique(
    dis: &mut Disassembler,
    image: &[u8],
    pe: &Pe,
    candidates: &[u32],
    matcher: impl Fn(&[DecodedInsn]) -> bool,
) -> Result<u32, MatchError> {
    let mut hits = Vec::new();
    for &rva in candidates {
        // Reject spurious mid-function targets: a candidate that sits inside a
        // `.pdata` entry but not at its begin is an E8/E9 landing mid-body, not
        // a real function start — disassembling its tail can coincidentally
        // satisfy a feature-based matcher. Real starts are either `.pdata`
        // begins or leaves in `.pdata` gaps (no covering entry).
        if let Some(rf) = pe.find_runtime_function(rva) {
            if rf.begin != rva {
                continue;
            }
        }
        // Disassemble starting AT the candidate's own address (not the
        // `.pdata`-resolved begin). Bound the decode by the `.pdata` entry's
        // end when the candidate sits inside one; else leaf mode.
        let end = pe.find_runtime_function(rva).map(|rf| rf.end).unwrap_or(0);
        let insns = dis.disasm_range(image, rva, end);
        if !insns.is_empty() && matcher(&insns) {
            hits.push(rva);
        }
    }
    match hits.len() {
        0 => Err(MatchError::NoCandidate),
        1 => Ok(hits[0]),
        _ => Err(MatchError::Ambiguous(hits)),
    }
}

/// Re-scan a single known RVA and assert the matcher still agrees (used by the
/// oracle Tier-2 test to *self-validate* a discovered address).
pub fn matches_at(
    dis: &mut Disassembler,
    image: &[u8],
    pe: &Pe,
    rva: u32,
    matcher: impl Fn(&[DecodedInsn]) -> bool,
) -> bool {
    let (begin, end) = crate::disasm::body_bounds(pe, rva);
    let insns = dis.disasm_range(image, begin, end);
    !insns.is_empty() && matcher(&insns)
}

/// Body size (bytes) of the function at `rva`: from `.pdata` if present,
/// else disassembled leaf-trimmed length. Used by the oracle/report.
pub fn measured_body_size(dis: &mut Disassembler, image: &[u8], pe: &Pe, rva: u32) -> u32 {
    if let Some(rf) = pe.find_runtime_function(rva) {
        return rf.end - rf.begin;
    }
    let (begin, end) = crate::disasm::body_bounds(pe, rva);
    let insns = dis.disasm_range(image, begin, end);
    body_end_rva(&insns, rva).saturating_sub(rva)
}
