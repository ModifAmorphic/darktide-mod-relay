//! Minimal PE-x86-64 parser, hand-rolled in safe Rust.
//!
//! The engine consumes a buffer *laid out by RVA* — i.e. `image[rva]` is the
//! byte at that RVA. This matches what the Windows loader produces for a
//! mapped module (so the live-game shell can hand us the module base directly)
//! and is trivially produced offline by copying each section from its file
//! offset to its `VirtualAddress` (see [`map_from_file`]).
//!
//! No `unsafe`, no external PE dependency: every read is a bounds-checked
//! little-endian slice read. PE constants are hard-coded so the same code
//! compiles on Linux, MinGW and MSVC without `windows.h`.
//!
//! Fresh, safe-Rust implementation (shared design with prior validated
//! implementations of this discovery path).

// PE header constants (subset of IMAGE_* from winnt.h).
const DOS_MAGIC: u16 = 0x5A4D; // "MZ"
const NT_SIGNATURE: u32 = 0x0000_4550; // "PE\0\0"
const PE32PLUS_MAGIC: u16 = 0x020B;
const DIR_IMPORT: usize = 1;

/// A PE section header (the fields the engine uses).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Section {
    pub name: [u8; 8],
    pub virtual_size: u32,
    pub rva: u32,
    pub raw_size: u32,
    pub file_offset: u32,
}

impl Section {
    /// Section name as a `&str` (NUL-padded, lossy).
    pub fn name_str(&self) -> &str {
        let n = self.name.iter().position(|&b| b == 0).unwrap_or(8);
        core::str::from_utf8(&self.name[..n]).unwrap_or("<bad-utf8>")
    }

    /// Scan bound for byte-pattern scanners over this section. Mirrors the
    /// reference implementation's `scan_bound`: use `min(raw_size,
    /// virtual_size)` so we never walk past real bytes into loader zero-fill
    /// or absent on-disk tails.
    pub fn scan_bound(&self) -> u32 {
        core::cmp::min(self.raw_size, self.virtual_size)
    }
}

/// One `.pdata` `RUNTIME_FUNCTION` (12 bytes: begin, end, unwind RVAs).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeFunction {
    pub begin: u32,
    pub end: u32,
    pub unwind: u32,
}

/// A resolved import (for `FF 25` import-thunk resolution).
#[derive(Debug, Clone)]
pub struct ImportEntry {
    pub iat_rva: u32,
    pub dll: String,
    pub name: String,
}

/// Parsed PE metadata. Borrows nothing; the caller owns the image buffer.
#[derive(Debug, Clone)]
pub struct Pe {
    pub image_base: u64,
    pub size_of_image: u32,
    pub sections: Vec<Section>,
    pub runtime_functions: Vec<RuntimeFunction>, // sorted by (begin, end)
    pub imports: Vec<ImportEntry>,               // sorted by iat_rva
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PeError {
    TooSmallForDos,
    BadDosSig,
    BadPeSig,
    NotPe32Plus(u16),
    SectionsOob,
    MissingSection(&'static str),
    OptHeaderOob,
}

impl core::fmt::Display for PeError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        match self {
            Self::TooSmallForDos => write!(f, "buffer too small for DOS header"),
            Self::BadDosSig => write!(f, "bad DOS signature (not MZ)"),
            Self::BadPeSig => write!(f, "bad PE signature"),
            Self::NotPe32Plus(m) => write!(f, "not PE32+ (optional header magic {m:#x})"),
            Self::SectionsOob => write!(f, "section table out of bounds"),
            Self::MissingSection(n) => write!(f, "required section {n} not found"),
            Self::OptHeaderOob => write!(f, "optional header out of bounds"),
        }
    }
}

impl std::error::Error for PeError {}

// ---- little-endian readers (bounds-checked ⇒ safe) ----
fn u16le(b: &[u8], off: usize) -> Option<u16> {
    b.get(off..off + 2)
        .map(|s| u16::from_le_bytes([s[0], s[1]]))
}
fn u32le(b: &[u8], off: usize) -> Option<u32> {
    b.get(off..off + 4)
        .map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}
fn u64le(b: &[u8], off: usize) -> Option<u64> {
    b.get(off..off + 8)
        .map(|s| u64::from_le_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]))
}

/// COFF file-header field offsets, given *absolute from `e_lfanew`* (the
/// "PE\0\0" signature). The file header itself starts at `e_lfanew + 4`, so
/// these are `4 + <offset within file header>`.
mod fh {
    pub const NUMBER_OF_SECTIONS: usize = 4 + 2; // Machine@0, NumberOfSections@2
    pub const SIZE_OF_OPTIONAL_HEADER: usize = 4 + 16; // …@16
}

/// PE32+ optional-header field offsets (relative to optional-header start).
mod oh {
    pub const MAGIC: usize = 0;
    pub const IMAGE_BASE: usize = 24;
    pub const SIZE_OF_IMAGE: usize = 56;
    pub const NUMBER_OF_RVA_AND_SIZES: usize = 108;
    pub const DATA_DIR: usize = 112; // first DataDirectory entry
}

impl Pe {
    /// Parse an RVA-laid-out image (headers at offset 0, sections at their
    /// RVAs). Works for both offline-mapped files and live loader-mapped
    /// modules.
    pub fn from_mapped(image: &[u8]) -> Result<Self, PeError> {
        if image.len() < 0x40 {
            return Err(PeError::TooSmallForDos);
        }
        if u16le(image, 0) != Some(DOS_MAGIC) {
            return Err(PeError::BadDosSig);
        }
        let e_lfanew = u32le(image, 0x3C).ok_or(PeError::TooSmallForDos)? as usize;
        if e_lfanew + 4 + 20 > image.len() {
            return Err(PeError::TooSmallForDos);
        }
        if u32le(image, e_lfanew) != Some(NT_SIGNATURE) {
            return Err(PeError::BadPeSig);
        }
        let num_sections =
            u16le(image, e_lfanew + fh::NUMBER_OF_SECTIONS).ok_or(PeError::OptHeaderOob)?;
        let opt_size =
            u16le(image, e_lfanew + fh::SIZE_OF_OPTIONAL_HEADER).ok_or(PeError::OptHeaderOob)?;
        let opt_base = e_lfanew + 4 + 20;
        let magic = u16le(image, opt_base + oh::MAGIC).ok_or(PeError::OptHeaderOob)?;
        if magic != PE32PLUS_MAGIC {
            return Err(PeError::NotPe32Plus(magic));
        }
        let image_base = u64le(image, opt_base + oh::IMAGE_BASE).ok_or(PeError::OptHeaderOob)?;
        let size_of_image =
            u32le(image, opt_base + oh::SIZE_OF_IMAGE).ok_or(PeError::OptHeaderOob)?;
        let num_rva = u32le(image, opt_base + oh::NUMBER_OF_RVA_AND_SIZES)
            .ok_or(PeError::OptHeaderOob)? as usize;

        // Section table immediately follows the optional header (incl. its
        // data directories).
        let sect_tab = opt_base + opt_size as usize;
        let sections = read_sections(image, sect_tab, num_sections as usize)?;

        // Import directory (data dir entry index 1).
        let (imp_rva, imp_size) = if num_rva > DIR_IMPORT {
            let dd = opt_base + oh::DATA_DIR + DIR_IMPORT * 8;
            (
                u32le(image, dd).unwrap_or(0),
                u32le(image, dd + 4).unwrap_or(0),
            )
        } else {
            (0, 0)
        };

        let pdata = find_section(&sections, ".pdata").ok_or(PeError::MissingSection(".pdata"))?;
        let runtime_functions = parse_pdata(image, pdata);

        let mut imports = parse_imports(image, imp_rva, imp_size);
        imports.sort_by_key(|e| e.iat_rva);

        Ok(Self {
            image_base,
            size_of_image,
            sections,
            runtime_functions,
            imports,
        })
    }

    pub fn section(&self, name: &str) -> Option<&Section> {
        find_section(&self.sections, name)
    }
    pub fn text(&self) -> &Section {
        self.section(".text").expect(".text present")
    }
    pub fn rdata(&self) -> &Section {
        self.section(".rdata").expect(".rdata present")
    }
    pub fn pdata(&self) -> &Section {
        self.section(".pdata").expect(".pdata present")
    }

    /// `.rdata` RVA delta = `rdata.rva - rdata.file_offset`. The documented
    /// pinned build has delta `0x2A00`; other builds differ. Used to turn a
    /// string's file offset into an RVA when scanning the on-disk file.
    pub fn rdata_delta(&self) -> i64 {
        let r = self.rdata();
        r.rva as i64 - r.file_offset as i64
    }

    /// Binary-search `.pdata` for the `RUNTIME_FUNCTION` containing `rva`.
    /// Returns `None` if `rva` falls in a `.pdata` gap (leaf / thunk).
    pub fn find_runtime_function(&self, rva: u32) -> Option<&RuntimeFunction> {
        let arr = &self.runtime_functions;
        let mut lo = 0i64;
        let mut hi = arr.len() as i64 - 1;
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let rf = &arr[mid as usize];
            if rva < rf.begin {
                hi = mid - 1;
            } else if rva >= rf.end {
                lo = mid + 1;
            } else {
                return Some(rf);
            }
        }
        None
    }

    /// Resolve an IAT RVA to `DLL!name`, if present.
    pub fn import_lookup(&self, iat_rva: u32) -> Option<(&str, &str)> {
        let arr = &self.imports;
        let mut lo = 0i64;
        let mut hi = arr.len() as i64 - 1;
        while lo <= hi {
            let mid = (lo + hi) / 2;
            let e = &arr[mid as usize];
            if e.iat_rva < iat_rva {
                lo = mid + 1;
            } else if e.iat_rva > iat_rva {
                hi = mid - 1;
            } else {
                return Some((e.dll.as_str(), e.name.as_str()));
            }
        }
        None
    }
}

fn read_sections(image: &[u8], sect_tab: usize, n: usize) -> Result<Vec<Section>, PeError> {
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let off = sect_tab + i * 40;
        let row = image.get(off..off + 40).ok_or(PeError::SectionsOob)?;
        let mut name = [0u8; 8];
        name.copy_from_slice(&row[0..8]);
        out.push(Section {
            name,
            virtual_size: u32::from_le_bytes(row[8..12].try_into().unwrap()),
            rva: u32::from_le_bytes(row[12..16].try_into().unwrap()),
            raw_size: u32::from_le_bytes(row[16..20].try_into().unwrap()),
            file_offset: u32::from_le_bytes(row[20..24].try_into().unwrap()),
        });
    }
    Ok(out)
}

fn find_section<'a>(sections: &'a [Section], name: &str) -> Option<&'a Section> {
    sections.iter().find(|s| s.name_str() == name)
}

/// Parse `.pdata` from an RVA-mapped image. Uses `min(raw, virtual)` as the
/// scan bound and sorts by `(begin, end)`. Skips all-zero terminators.
fn parse_pdata(image: &[u8], pdata: &Section) -> Vec<RuntimeFunction> {
    let scan = core::cmp::min(pdata.raw_size, pdata.virtual_size) as usize;
    let base = pdata.rva as usize;
    if base + scan > image.len() {
        return Vec::new();
    }
    let n = scan / 12;
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let o = base + i * 12;
        let (b, e, u) = (
            u32le(image, o).unwrap_or(0),
            u32le(image, o + 4).unwrap_or(0),
            u32le(image, o + 8).unwrap_or(0),
        );
        if b == 0 && e == 0 {
            continue;
        }
        out.push(RuntimeFunction {
            begin: b,
            end: e,
            unwind: u,
        });
    }
    // ~44k entries: sort by (begin, end). `.pdata` is normally already sorted,
    // so `sort_by_key` is adaptive (O(n) on sorted input) and safe against
    // malformed/out-of-order input.
    out.sort_by_key(|rf| (rf.begin, rf.end));
    out
}

/// Parse the import directory (for `FF 25` import-thunk resolution).
fn parse_imports(image: &[u8], dir_rva: u32, dir_size: u32) -> Vec<ImportEntry> {
    let mut out = Vec::new();
    if dir_rva == 0 || dir_size == 0 {
        return out;
    }
    let base = dir_rva as usize;
    let n = (dir_size as usize) / 20;
    for i in 0..n {
        let de = base + i * 20;
        let row = match image.get(de..de + 20) {
            Some(r) => r,
            None => break,
        };
        let original_first_thunk = u32::from_le_bytes(row[0..4].try_into().unwrap());
        let name_rva = u32::from_le_bytes(row[12..16].try_into().unwrap());
        let first_thunk = u32::from_le_bytes(row[16..20].try_into().unwrap());
        if name_rva == 0 && first_thunk == 0 {
            break; // terminator descriptor
        }
        let dll = read_cstr(image, name_rva as usize).unwrap_or_default();

        // OriginalFirstThunk (INT) is the authoritative on-disk name table.
        // If absent (bound import), skip entries rather than mis-read the
        // loader-overwritten IAT. Darktide has no bound imports.
        if original_first_thunk == 0 || first_thunk == 0 {
            continue;
        }
        let mut int = original_first_thunk as usize;
        let mut iat = first_thunk as usize;
        while let Some(v) = u64le(image, int) {
            if v == 0 {
                break;
            }
            if v & 0x8000_0000_0000_0000 != 0 {
                // ordinal import
                out.push(ImportEntry {
                    iat_rva: iat as u32,
                    dll: dll.clone(),
                    name: format!("ordinal#{}", v & 0xFFFF),
                });
            } else {
                let hn = v as usize; // hint/name RVA
                let nm = read_cstr(image, hn + 2).unwrap_or_default();
                out.push(ImportEntry {
                    iat_rva: iat as u32,
                    dll: dll.clone(),
                    name: nm,
                });
            }
            int += 8;
            iat += 8;
        }
    }
    out
}

fn read_cstr(image: &[u8], off: usize) -> Option<String> {
    if off >= image.len() {
        return None;
    }
    let end = image[off..]
        .iter()
        .position(|&b| b == 0)
        .map(|e| off + e)
        .unwrap_or(image.len());
    Some(String::from_utf8_lossy(&image[off..end]).into_owned())
}

// ---- offline mapping helper ----

/// Build an RVA-laid-out image from an on-disk PE file: allocate
/// `size_of_image` bytes, copy each section from its file offset to its RVA.
/// Headers (first `size_of_headers` bytes) are copied verbatim so that
/// [`Pe::from_mapped`] can re-parse them from the result.
pub fn map_from_file(file: &[u8]) -> Result<Vec<u8>, PeError> {
    if file.len() < 0x40 {
        return Err(PeError::TooSmallForDos);
    }
    if u16le(file, 0) != Some(DOS_MAGIC) {
        return Err(PeError::BadDosSig);
    }
    let e_lfanew = u32le(file, 0x3C).ok_or(PeError::TooSmallForDos)? as usize;
    if u32le(file, e_lfanew) != Some(NT_SIGNATURE) {
        return Err(PeError::BadPeSig);
    }
    let opt_base = e_lfanew + 4 + 20;
    let magic = u16le(file, opt_base + oh::MAGIC).ok_or(PeError::OptHeaderOob)?;
    if magic != PE32PLUS_MAGIC {
        return Err(PeError::NotPe32Plus(magic));
    }
    let size_of_image =
        u32le(file, opt_base + oh::SIZE_OF_IMAGE).ok_or(PeError::OptHeaderOob)? as usize;
    let opt_size =
        u16le(file, e_lfanew + fh::SIZE_OF_OPTIONAL_HEADER).ok_or(PeError::OptHeaderOob)? as usize;
    let num_sections =
        u16le(file, e_lfanew + fh::NUMBER_OF_SECTIONS).ok_or(PeError::OptHeaderOob)? as usize;
    let sect_tab = opt_base + opt_size;
    let size_of_headers = sect_tab + num_sections * 40;

    let mut image = vec![0u8; size_of_image];
    // Headers: copy up to the end of the section table (the part of the
    // on-disk header region that Pe::from_mapped re-parses). Everything past
    // it is section data, which the per-section copy below places by RVA.
    let hdr_copy = core::cmp::min(size_of_headers, file.len());
    let hdr_copy = core::cmp::min(hdr_copy, size_of_image);
    image[..hdr_copy].copy_from_slice(&file[..hdr_copy]);
    // Sections.
    let sections = read_sections(file, sect_tab, num_sections)?;
    for s in &sections {
        let raw = s.raw_size as usize;
        let off = s.file_offset as usize;
        let rva = s.rva as usize;
        if raw == 0 || off + raw > file.len() || rva + raw > image.len() {
            continue;
        }
        image[rva..rva + raw].copy_from_slice(&file[off..off + raw]);
    }
    Ok(image)
}
