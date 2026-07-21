//! Unit test: PE-parsing machinery against a small synthetic PE built in
//! memory. Validates section discovery, `.pdata` `RUNTIME_FUNCTION` parsing
//! and sorting, and `.pdata` gap binary-search — all without the multi-MB
//! game binary, so the parsing layer has its own fast, hermetic coverage.

use relay_discovery::pe::{map_from_file, Pe, PeError};

/// Hand-build a minimal PE32+ image with `.text`, `.rdata`, `.pdata`, then
/// verify the parser recovers the sections and the `.pdata` table (sorted,
/// binary-searchable, with gaps reported correctly).
fn build_synthetic_pe() -> Vec<u8> {
    // We construct an *RVA-laid-out* image directly (what map_from_file would
    // produce), with a valid DOS+PE32+ header and a section table. Sizes are
    // tiny but the structure is real.
    const SIZE_OF_IMAGE: usize = 0x4000;
    let mut img = vec![0u8; SIZE_OF_IMAGE];

    // DOS header: MZ + e_lfanew at 0x3C -> 0x80.
    img[0..2].copy_from_slice(&0x5A4Du16.to_le_bytes());
    img[0x3C..0x40].copy_from_slice(&0x80u32.to_le_bytes());

    // PE signature at 0x80.
    let pe = 0x80usize;
    img[pe..pe + 4].copy_from_slice(&0x0000_4550u32.to_le_bytes());

    // File header (20 bytes) at 0x84: Machine=amd64, 3 sections, opt_size=240.
    let fh = pe + 4;
    img[fh..fh + 2].copy_from_slice(&0x8664u16.to_le_bytes()); // Machine
    img[fh + 2..fh + 4].copy_from_slice(&3u16.to_le_bytes()); // NumberOfSections
    img[fh + 16..fh + 18].copy_from_slice(&240u16.to_le_bytes()); // SizeOfOptionalHeader

    // Optional header (PE32+) at 0x98.
    let oh = fh + 20;
    img[oh..oh + 2].copy_from_slice(&0x020Bu16.to_le_bytes()); // Magic PE32+
    img[oh + 24..oh + 32].copy_from_slice(&0x1_4000_0000u64.to_le_bytes()); // ImageBase
    img[oh + 56..oh + 60].copy_from_slice(&(SIZE_OF_IMAGE as u32).to_le_bytes()); // SizeOfImage
    img[oh + 108..oh + 112].copy_from_slice(&16u32.to_le_bytes()); // NumberOfRvaAndSizes

    // Section table at oh + opt_size.
    let sect = oh + 240;
    let mut write_section = |idx: usize, name: &str, vsize: u32, rva: u32, raw: u32, foff: u32| {
        let o = sect + idx * 40;
        let mut n = [0u8; 8];
        let nb = name.as_bytes();
        n[..nb.len()].copy_from_slice(nb);
        img[o..o + 8].copy_from_slice(&n);
        img[o + 8..o + 12].copy_from_slice(&vsize.to_le_bytes());
        img[o + 12..o + 16].copy_from_slice(&rva.to_le_bytes());
        img[o + 16..o + 20].copy_from_slice(&raw.to_le_bytes());
        img[o + 20..o + 24].copy_from_slice(&foff.to_le_bytes());
    };
    // .text at rva 0x1000, .rdata at 0x2000, .pdata at 0x3000.
    write_section(0, ".text", 0x1000, 0x1000, 0x1000, 0x0400);
    write_section(1, ".rdata", 0x1000, 0x2000, 0x1000, 0x1400);
    write_section(2, ".pdata", 0x1000, 0x3000, 0x1000, 0x2400);

    // .pdata at 0x3000: two RUNTIME_FUNCTION entries (12 bytes each), given
    // OUT OF ORDER to verify sorting: [0x1100,0x1150), [0x1000,0x1050).
    let pd = 0x3000usize;
    let e1 = [0x1100u32, 0x1150u32, 0x0];
    let e2 = [0x1000u32, 0x1050u32, 0x0];
    for (k, &v) in e1.iter().enumerate() {
        img[pd + k * 4..pd + k * 4 + 4].copy_from_slice(&v.to_le_bytes());
    }
    for (k, &v) in e2.iter().enumerate() {
        img[pd + 12 + k * 4..pd + 12 + k * 4 + 4].copy_from_slice(&v.to_le_bytes());
    }

    img
}

#[test]
fn parses_sections_and_sorts_pdata() {
    let img = build_synthetic_pe();
    let pe = Pe::from_mapped(&img).expect("parse");
    assert_eq!(pe.size_of_image as usize, 0x4000);
    assert_eq!(pe.text().rva, 0x1000);
    assert_eq!(pe.rdata().rva, 0x2000);
    assert_eq!(pe.pdata().rva, 0x3000);

    // .pdata entries must be sorted by begin.
    assert_eq!(pe.runtime_functions.len(), 2);
    assert_eq!(pe.runtime_functions[0].begin, 0x1000);
    assert_eq!(pe.runtime_functions[0].end, 0x1050);
    assert_eq!(pe.runtime_functions[1].begin, 0x1100);
    assert_eq!(pe.runtime_functions[1].end, 0x1150);
}

#[test]
fn find_runtime_function_handles_gaps() {
    let img = build_synthetic_pe();
    let pe = Pe::from_mapped(&img).unwrap();
    // Inside an entry.
    assert!(pe.find_runtime_function(0x1010).is_some());
    // In a gap (between 0x1050 and 0x1100).
    assert!(pe.find_runtime_function(0x1075).is_none());
    // Inside the second entry.
    assert!(pe.find_runtime_function(0x1120).is_some());
    // Far outside.
    assert!(pe.find_runtime_function(0x3000).is_none());
}

#[test]
fn rejects_non_pe32plus() {
    let mut img = build_synthetic_pe();
    // Corrupt the optional-header magic to PE32 (0x010B).
    let pe = 0x80usize;
    let oh = pe + 4 + 20;
    img[oh..oh + 2].copy_from_slice(&0x010Bu16.to_le_bytes());
    assert_eq!(
        Pe::from_mapped(&img).unwrap_err(),
        PeError::NotPe32Plus(0x010B)
    );
}

#[test]
fn map_from_file_copies_sections_to_rvas() {
    // Build an on-disk-style file: headers + one section whose file offset
    // differs from its RVA, then ensure map_from_file places the bytes at the
    // RVA (so Pe::from_mapped sees them in place).
    let mut file = vec![0u8; 0x800];
    file[0..2].copy_from_slice(&0x5A4Du16.to_le_bytes());
    file[0x3C..0x40].copy_from_slice(&0x80u32.to_le_bytes());
    file[0x80..0x84].copy_from_slice(&0x0000_4550u32.to_le_bytes());
    let fh = 0x84;
    file[fh..fh + 2].copy_from_slice(&0x8664u16.to_le_bytes());
    file[fh + 2..fh + 4].copy_from_slice(&1u16.to_le_bytes());
    file[fh + 16..fh + 18].copy_from_slice(&240u16.to_le_bytes());
    let oh = fh + 20;
    file[oh..oh + 2].copy_from_slice(&0x020Bu16.to_le_bytes());
    file[oh + 56..oh + 60].copy_from_slice(&0x2000u32.to_le_bytes()); // SizeOfImage
    file[oh + 108..oh + 112].copy_from_slice(&16u32.to_le_bytes());
    let sect = oh + 240;
    file[sect..sect + 8].copy_from_slice(b".text\0\0\0");
    file[sect + 8..sect + 12].copy_from_slice(&0x1000u32.to_le_bytes()); // vsize
    file[sect + 12..sect + 16].copy_from_slice(&0x1000u32.to_le_bytes()); // rva
    file[sect + 16..sect + 20].copy_from_slice(&0x100u32.to_le_bytes()); // raw size
    file[sect + 20..sect + 24].copy_from_slice(&0x600u32.to_le_bytes()); // file offset
                                                                         // Section payload: a recognizable byte pattern at file offset 0x600.
    for (i, b) in [0xDEu8, 0xAD, 0xBE, 0xEF].iter().enumerate() {
        file[0x600 + i] = *b;
    }
    // Also add .pdata so from_mapped is happy (it requires .pdata).
    // (Append a second section.)
    file[fh + 2..fh + 4].copy_from_slice(&2u16.to_le_bytes()); // 2 sections
    let sect2 = sect + 40;
    file[sect2..sect2 + 8].copy_from_slice(b".pdata\0\0");
    file[sect2 + 8..sect2 + 12].copy_from_slice(&0x18u32.to_le_bytes());
    file[sect2 + 12..sect2 + 16].copy_from_slice(&0x1800u32.to_le_bytes()); // rva
    file[sect2 + 16..sect2 + 20].copy_from_slice(&0x18u32.to_le_bytes());
    file[sect2 + 20..sect2 + 24].copy_from_slice(&0x700u32.to_le_bytes()); // file offset

    let image = map_from_file(&file).unwrap();
    // The payload must appear at the section RVA (0x1000), not the file offset.
    assert_eq!(&image[0x1000..0x1004], &[0xDE, 0xAD, 0xBE, 0xEF]);
}
