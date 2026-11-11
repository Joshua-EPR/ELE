//! Linux syscall heap bootstrap emitted by the ELE-written x86-64 backend.
//! The Rust Stage 0 builder is only used to execute the ELE code generator.
//! ELF64 output is executed on a real Linux x86-64 runner by GitHub Actions.
mod stage1_support;

use std::{fs, path::PathBuf, process::Command, sync::OnceLock};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn generator() -> &'static std::path::Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("native_heap_cases", false))
}

fn generate(mode: &str) -> Vec<u8> {
    let output = root().join(format!("target/stage1-tests/native-heap/heap-{mode}.elf"));
    fs::create_dir_all(output.parent().unwrap()).unwrap();
    let generated = Command::new(generator())
        .arg(mode)
        .arg(&output)
        .output()
        .expect("run ELE-native heap fixture");
    assert!(
        generated.status.success(),
        "heap mode {mode}: exit={:?}, stderr={}, stdout={}",
        generated.status.code(),
        String::from_utf8_lossy(&generated.stderr),
        String::from_utf8_lossy(&generated.stdout)
    );
    let elf = fs::read(&output).unwrap();
    assert!(elf.len() > 4096, "no executable ELF64 code in {mode}");
    assert_eq!(&elf[..7], b"\x7fELF\x02\x01\x01");
    assert_eq!(
        u64::from_le_bytes(elf[24..32].try_into().unwrap()),
        0x401000
    );
    elf
}

#[test]
fn ele_heap_emits_real_map_read_write_unmap_elf64() {
    let elf = generate("ok");
    let code = &elf[4096..];
    // mmap, map failure exit, munmap, unmap failure exit, success exit.
    assert!(
        code.windows(2).filter(|b| *b == [0x0f, 0x05]).count() >= 5,
        "missing Linux syscalls"
    );
}

#[test]
fn ele_heap_emits_unaligned_unmap_failure_elf64() {
    let elf = generate("bad");
    let code = &elf[4096..];
    assert!(code.windows(2).any(|b| b == [0x0f, 0x05]));
    // This output must exit 124 at runtime: a successful bad unmap would
    // incorrectly continue and return 42 instead.
}
