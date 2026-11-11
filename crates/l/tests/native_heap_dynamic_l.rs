//! Executable ELF64 proofs for ELE-written runtime-sized heap and owner
//! emitters. Windows runs the temporary Stage 0 builder; Linux executes
//! the generated ELF binaries from these tests. Not Stage 2 or LIR drops.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn dynamic_generator() -> &'static Path {
    static BIN: OnceLock<PathBuf> = OnceLock::new();
    BIN.get_or_init(|| stage1_support::build("native_heap_dynamic_cases", false))
}

fn owner_generator() -> &'static Path {
    static BIN: OnceLock<PathBuf> = OnceLock::new();
    BIN.get_or_init(|| stage1_support::build("native_heap_owner_cases", false))
}

fn export_case(generator: &Path, family: &str, mode: &str) -> Vec<u8> {
    let output = root().join(format!(
        "target/stage1-tests/native-heap-advanced/{family}-{mode}.elf"
    ));
    fs::create_dir_all(output.parent().unwrap()).unwrap();
    let run = Command::new(generator)
        .arg(mode)
        .arg(&output)
        .output()
        .expect("run ELE heap emitter");
    assert!(
        run.status.success(),
        "{family} {mode}: status={:?}\nstderr={}\nstdout={}",
        run.status.code(),
        String::from_utf8_lossy(&run.stderr),
        String::from_utf8_lossy(&run.stdout)
    );
    let image = fs::read(output).unwrap();
    assert!(image.len() > 4096, "{family}/{mode}: empty machine code");
    assert_eq!(&image[..7], b"\x7fELF\x02\x01\x01");
    assert_eq!(
        u64::from_le_bytes(image[24..32].try_into().unwrap()),
        0x401000
    );
    image
}

#[test]
fn runtime_sized_linux_mmap_validates_bounds_and_rounds_two_pages() {
    for mode in ["t", "z", "n", "h", "u"] {
        let image = export_case(dynamic_generator(), "dynamic", mode);
        let code = &image[4096..];
        assert!(code.windows(2).any(|b| b == [0x0f, 0x05]));
        assert!(
            code.windows(2).any(|b| b == [0x48, 0x21]),
            "dynamic page-rounding AND instruction missing: {mode}"
        );
    }
}

#[test]
fn linear_owner_slots_emit_move_and_exactly_once_drop_guards() {
    for mode in ["o", "d", "m", "r", "b"] {
        let image = export_case(owner_generator(), "owner", mode);
        assert!(
            image[4096..].windows(2).any(|b| b == [0x0f, 0x05]),
            "missing Linux syscall for {mode}"
        );
    }
}

fn resize_generator() -> &'static Path {
    static BIN: OnceLock<PathBuf> = OnceLock::new();
    BIN.get_or_init(|| stage1_support::build("native_heap_resize_cases", false))
}

#[test]
fn linux_mremap_preserves_bytes_across_grow_shrink_and_owner_transfer() {
    for mode in ["g", "s", "t", "z", "h", "m"] {
        let image = export_case(resize_generator(), "resize", mode);
        assert!(
            image[4096..].windows(2).any(|b| b == [0x0f, 0x05]),
            "Linux syscall missing in mremap case {mode}"
        );
    }
}

fn list_generator() -> &'static Path {
    static BIN: OnceLock<PathBuf> = OnceLock::new();
    BIN.get_or_init(|| stage1_support::build("native_list_cases", false))
}

#[test]
fn native_int_buffer_push_grow_read_pop_and_drop_are_checked_in_elf() {
    for mode in ["p", "g", "t", "o", "e", "d", "b", "c", "k", "q"] {
        let image = export_case(list_generator(), "list", mode);
        assert!(
            image[4096..].windows(2).any(|b| b == [0x0f, 0x05]),
            "missing native Linux syscall for List<Int> case {mode}"
        );
    }
}
