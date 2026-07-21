//! Capstone disassembly wrapper.
//!
//! This module adapts the `capstone-rs` safe API into the engine's owned
//! [`DecodedInsn`] type. It contains **no `unsafe`** of its own — the capstone
//! C-FFI `unsafe` lives inside the `capstone-rs` / `capstone-sys` crates, fully
//! encapsulated — so the source-pattern matchers (`patterns.rs`) and the
//! Method-A logic that use this module stay 100% safe. (The only `unsafe` in
//! this crate is the C-ABI seam in `lib.rs`.)
//!
//! Mirrors the validated C reference engine's capstone configuration
//! (`disasm.c`): Intel syntax, detail off (we match on `mnemonic`/`op_str`
//! exactly as the reference implementation's substring classifiers do).

use crate::pe::Pe;

/// A disassembled instruction (owned, safe).
#[derive(Debug, Clone)]
pub struct DecodedInsn {
    pub address: u64,
    pub size: u32,
    pub bytes: Vec<u8>,
    pub mnemonic: String,
    pub op_str: String,
    /// Capstone x86 instruction id (e.g. `X86_INS_CALL`). Raw `u32` so the
    /// matchers need not depend on capstone enums.
    pub id: u32,
}

impl DecodedInsn {
    pub fn is_mnemonic(&self, m: &str) -> bool {
        self.mnemonic == m
    }
    pub fn op_contains(&self, needle: &str) -> bool {
        self.op_str.contains(needle)
    }
}

/// A configured capstone handle. Cheap to create; reuse across calls when
/// disassembling many bodies (the reference C engine opens one per call, but
/// reusing avoids re-initialising the engine ~50k times during a cluster
/// scan).
pub struct Disassembler {
    cs: capstone::Capstone,
}

impl Disassembler {
    pub fn new_x86_64_intel() -> Result<Self, capstone::Error> {
        // prelude brings `Capstone`, the `arch` module, and the `BuildsCapstone`
        // trait (which provides `.mode()`/`.syntax()`/`.build()`).
        use capstone::prelude::*;
        let mut cs = Capstone::new()
            .x86()
            .mode(arch::x86::ArchMode::Mode64)
            .syntax(arch::x86::ArchSyntax::Intel)
            .build()?;
        // Match the reference implementation: detail off (op_str is enough).
        let _ = cs.set_detail(false);
        Ok(Self { cs })
    }

    /// Disassemble `[begin, end)` from the image (RVA-addressed). `end == 0`
    /// ⇒ leaf mode: linear sweep, trimmed at the first `ret`/`retn`, capped at
    /// 256 bytes (mirrors the reference `dt_disasm_range`). Returns owned
    /// instructions.
    pub fn disasm_range(&mut self, image: &[u8], begin: u32, end: u32) -> Vec<DecodedInsn> {
        let leaf = end == 0;
        let limit = if leaf { begin + 256 } else { end };
        if limit <= begin {
            return Vec::new();
        }
        let want = (limit - begin) as usize;
        let code = match image.get(begin as usize..begin as usize + want) {
            Some(c) => c,
            None => return Vec::new(),
        };
        let mut out = Vec::new();
        let mut cur_off = 0usize;
        let mut cur_addr = begin as u64;
        loop {
            if cur_off >= code.len() {
                break;
            }
            let one = match self.cs.disasm_count(&code[cur_off..], cur_addr, 1) {
                Ok(insns) if !insns.is_empty() => insns,
                _ => break,
            };
            let ins = one.iter().next().unwrap();
            let mn = ins.mnemonic().unwrap_or("").to_string();
            let op = ins.op_str().unwrap_or("").to_string();
            let sz = ins.len() as u32;
            out.push(DecodedInsn {
                address: ins.address(),
                size: sz,
                bytes: ins.bytes().to_vec(),
                mnemonic: mn.clone(),
                op_str: op,
                id: mnemonic_to_id(&mn),
            });
            let is_ret = mn == "ret" || mn == "retn";
            cur_off += sz as usize;
            cur_addr += sz as u64;
            if leaf && is_ret {
                break;
            }
        }
        out
    }

    /// Disassemble a fixed window `[begin, begin+len)` without leaf-trimming.
    pub fn disasm_window(
        &mut self,
        image: &[u8],
        begin: u32,
        len: u32,
        max_insns: usize,
    ) -> Vec<DecodedInsn> {
        let code = match image.get(begin as usize..begin as usize + len as usize) {
            Some(c) => c,
            None => return Vec::new(),
        };
        let count = max_insns.min(512);
        let insns = match self.cs.disasm_count(code, begin as u64, count) {
            Ok(i) => i,
            Err(_) => return Vec::new(),
        };
        insns
            .iter()
            .map(|ins| {
                let mn = ins.mnemonic().unwrap_or("").to_string();
                DecodedInsn {
                    address: ins.address(),
                    size: ins.len() as u32,
                    bytes: ins.bytes().to_vec(),
                    id: mnemonic_to_id(&mn),
                    mnemonic: mn,
                    op_str: ins.op_str().unwrap_or("").to_string(),
                }
            })
            .collect()
    }
}

// ---- x86 instruction-id constants the matchers use (capstone-sys values) ----
pub const X86_INS_CALL: u32 = capstone::arch::x86::X86Insn::X86_INS_CALL as u32;
pub const X86_INS_JMP: u32 = capstone::arch::x86::X86Insn::X86_INS_JMP as u32;
pub const X86_INS_RET: u32 = capstone::arch::x86::X86Insn::X86_INS_RET as u32;
pub const X86_INS_JNE: u32 = capstone::arch::x86::X86Insn::X86_INS_JNE as u32;
pub const X86_INS_JLE: u32 = capstone::arch::x86::X86Insn::X86_INS_JLE as u32;
pub const X86_INS_LEA: u32 = capstone::arch::x86::X86Insn::X86_INS_LEA as u32;
pub const X86_INS_TEST: u32 = capstone::arch::x86::X86Insn::X86_INS_TEST as u32;
pub const X86_INS_INT3: u32 = capstone::arch::x86::X86Insn::X86_INS_INT3 as u32;
pub const X86_INS_MOVABS: u32 = capstone::arch::x86::X86Insn::X86_INS_MOVABS as u32;

/// Body-end RVA for a disassembled window: end of the last instruction before
/// the body terminator (`ret` / tail-`jmp` / `int3` padding). Mirrors the
/// reference matchers' body-size computation.
pub fn body_end_rva(insns: &[DecodedInsn], fn_start: u32) -> u32 {
    for ins in insns {
        if ins.id == X86_INS_RET || ins.id == X86_INS_INT3 {
            return ins.address as u32;
        }
        if ins.id == X86_INS_JMP {
            // Tail-call jmp: ends the body only if it leaves the body window.
            let tgt = parse_jmp_target(ins);
            if tgt < fn_start as u64 || tgt > (fn_start as u64 + 0x200) {
                return (ins.address + ins.size as u64) as u32;
            }
        }
    }
    insns
        .last()
        .map(|i| (i.address + i.size as u64) as u32)
        .unwrap_or(fn_start)
}

/// Parse the absolute target of `jmp`/`jcc`/`call` whose op_str is a bare hex
/// address (capstone prints absolute targets for rel8/rel32 branches).
pub fn parse_branch_target(ins: &DecodedInsn) -> Option<u64> {
    let op = ins.op_str.trim();
    if let Some(h) = op.strip_prefix("0x") {
        u64::from_str_radix(h, 16).ok()
    } else if op.starts_with("0") && op.len() > 1 && op.chars().all(|c| c.is_ascii_hexdigit()) {
        u64::from_str_radix(op, 16).ok()
    } else {
        None
    }
}
fn parse_jmp_target(ins: &DecodedInsn) -> u64 {
    parse_branch_target(ins).unwrap_or(u64::MAX)
}

/// Extract the RIP-relative target RVA from a `lea`/`mov` whose op_str is
/// `... [rip + 0xNNNN]` / `[rip - 0xNNNN]`. Mirrors the reference
/// `dt_lea_target_rva`.
pub fn rip_relative_target(ins: &DecodedInsn) -> Option<u32> {
    let op = &ins.op_str;
    let (sign, after): (i64, &str) = if let Some(p) = op.find("rip + ") {
        (1, &op[p + 6..])
    } else {
        let p = op.find("rip - ")?;
        (-1, &op[p + 6..])
    };
    // disp ends at ']'.
    let end = after.find(']').unwrap_or(after.len());
    let disp_text = after[..end].trim();
    let disp = if let Some(h) = disp_text.strip_prefix("0x") {
        i64::from_str_radix(h, 16).ok()?
    } else {
        disp_text.parse::<i64>().ok()?
    };
    let target = ins.address as i64 + ins.size as i64 + sign * disp;
    Some(target as u32)
}

// Mnemonic → capstone id for the small set the matchers inspect. (The matchers
// mostly use op_str substrings; ids are only needed for the handful below.)
fn mnemonic_to_id(mn: &str) -> u32 {
    match mn {
        "call" => X86_INS_CALL,
        "jmp" => X86_INS_JMP,
        "ret" | "retn" => X86_INS_RET,
        "jne" => X86_INS_JNE,
        "jle" => X86_INS_JLE,
        "lea" => X86_INS_LEA,
        "test" => X86_INS_TEST,
        "int3" => X86_INS_INT3,
        "movabs" => X86_INS_MOVABS,
        _ => 0,
    }
}

/// Convenience: bound a function body for disassembly. If `rva` is inside a
/// `.pdata` entry, use `[begin, end)`; otherwise treat it as a leaf (end=0).
pub fn body_bounds(pe: &Pe, rva: u32) -> (u32, u32) {
    match pe.find_runtime_function(rva) {
        Some(rf) => (rf.begin, rf.end),
        None => (rva, 0),
    }
}

#[cfg(test)]
mod tests {
    //! Hermetic unit tests for `rip_relative_target`'s three operand branches
    //! (positive `rip +`, negative `rip -`, neither ⇒ `None`). The positive
    //! branch is also covered indirectly by the oracle integration test against
    //! real `lea` disassembly; these directly pin the sign arithmetic and the
    //! `None` early-return, which previously had no direct coverage.
    use super::*;

    fn insn(op_str: &str, address: u64, size: u32) -> DecodedInsn {
        DecodedInsn {
            address,
            size,
            bytes: vec![],
            mnemonic: "lea".to_string(),
            op_str: op_str.to_string(),
            id: X86_INS_LEA,
        }
    }

    #[test]
    fn rip_relative_target_positive_operand() {
        // target = address + size + 1 * 0x100 = 0x1000 + 7 + 256 = 0x1107
        let ins = insn("rax, [rip + 0x100]", 0x1000, 7);
        assert_eq!(rip_relative_target(&ins), Some(0x1107));
    }

    #[test]
    fn rip_relative_target_negative_operand() {
        // target = address + size + (-1) * 0x10 = 0x1000 + 7 - 16 = 0x0ff7
        let ins = insn("rax, [rip - 0x10]", 0x1000, 7);
        assert_eq!(rip_relative_target(&ins), Some(0x0ff7));
    }

    #[test]
    fn rip_relative_target_no_rip_operand_returns_none() {
        // Neither `rip + ` nor `rip - ` present ⇒ None (the `?` early-return).
        let ins = insn("rax, [rbx + 0x100]", 0x1000, 7);
        assert_eq!(rip_relative_target(&ins), None);
    }
}
