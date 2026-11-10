//! End-to-end unit-enum smoke test: source .l -> real Stage 1 ELE-LIR ->
//! ELE-written x86-64 ELF backend. The temporary Stage 0 builder is bootstrap.
//! On Windows the generated Linux ELF is inspected, not executed.
mod stage1_support;

use std::{fs, path::PathBuf, process::Command, sync::OnceLock};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}
fn sema() -> &'static std::path::Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}
fn native() -> &'static std::path::Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}

#[test]
fn unit_enum_source_uses_real_nominal_lir_and_native_encoder() {
    let temp = root().join("target/stage1-tests/enum-to-native");
    fs::create_dir_all(&temp).unwrap();
    let src = temp.join("enum.l");
    let lir_file = temp.join("enum.lir");
    let elf = temp.join("enum.elf");
    fs::write(&src, "enum Estado { No, Si }\nfn main() -> Int {\n let x = Estado.Si\n return 42\n}\n").unwrap();
    let emitted = Command::new(sema()).arg(&src).arg("--emit-lir").output().unwrap();
    assert!(emitted.status.success(), "Stage 1: {}", String::from_utf8_lossy(&emitted.stderr));
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.contains("module structs 0 enums 1"), "{lir}");
    assert!(lir.contains("i variant"), "{lir}");
    assert!(lir.contains(" e0 1 0"), "{lir}");
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
    fs::write(&lir_file, &lir).unwrap();
    let built = Command::new(native()).arg(&lir_file).arg(&elf).output().unwrap();
    assert!(built.status.success(), "backend ELE: {}", String::from_utf8_lossy(&built.stderr));
    let bytes = fs::read(&elf).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&elf).unwrap().permissions();
        perms.set_mode(0o700);
        fs::set_permissions(&elf, perms).unwrap();
        let o = Command::new(&elf).output().unwrap();
        assert_eq!(o.status.code(), Some(42));
    }
}

#[test]
fn unit_enum_match_uses_discriminant_not_integer_type_coercion() {
    let temp = root().join("target/stage1-tests/enum-to-native-match");
    fs::create_dir_all(&temp).unwrap();
    let src = temp.join("match.l");
    fs::write(
        &src,
        "enum Estado { No, Si }\nfn main() -> Int {\n let x = Estado.Si\n match x {\n  Estado.No => { return 0 },\n  _ => { return 42 },\n }\n return 1\n}\n",
    )
    .unwrap();
    let emitted = Command::new(sema()).arg(&src).arg("--emit-lir").output().unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1 match enum: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    assert!(lir.contains("i disc "), "{lir}");
    let parsed = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&parsed).unwrap();
}
