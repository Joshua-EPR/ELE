//! Pruebas de constructores amplios desde .l hasta ELF64 escrito en ELE.
//! En Windows se verifican imágenes y rechazos; Linux las ejecuta.
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
fn sema() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_sema", false))
}
fn native() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("native_cfg_demo", false))
}
fn temp(name: &str) -> PathBuf {
    let dir = root().join("target/stage1-tests/native-wide-struct");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}
fn backend(lir: &Path, image: &Path) -> std::process::Output {
    Command::new(native()).arg(lir).arg(image).output().unwrap()
}
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
fn execute(image: &Path) -> (Option<i32>, String) {
    use std::os::unix::fs::PermissionsExt;
    let mut permissions = fs::metadata(image).unwrap().permissions();
    permissions.set_mode(0o700);
    fs::set_permissions(image, permissions).unwrap();
    let run = Command::new(image).output().unwrap();
    assert!(run.stderr.is_empty());
    (run.status.code(), String::from_utf8(run.stdout).unwrap())
}

#[test]
fn wide_shapes_from_source_match_stage0() {
    for (name, constructor_size) in [
        ("native_wide_17_stage1", 17),
        ("native_wide_6_text_stage1", 6),
    ] {
        let out = Command::new(sema())
            .arg(root().join(format!("examples/{name}.l")))
            .arg("--emit-lir")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "Stage 1 {name}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let lir = String::from_utf8(out.stdout).unwrap();
        assert!(
            lir.contains(&format!(" fields {constructor_size}")),
            "{name}: sin declaracion esperada\n{lir}"
        );
        let has_constructor = lir.lines().any(|line| {
            line.starts_with("i struct ") && line.contains(&format!(" {constructor_size} "))
        });
        assert!(has_constructor, "{name}: sin constructor esperado\n{lir}");
        let lir_file = temp(&format!("{name}.lir"));
        fs::write(&lir_file, &lir).unwrap();
        let image = temp(&format!("{name}.elf"));
        let built = backend(&lir_file, &image);
        assert!(
            built.status.success(),
            "backend ELE {name}: {}\n{lir}",
            String::from_utf8_lossy(&built.stderr)
        );
        let bytes = fs::read(&image).unwrap();
        assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let expected =
                fs::read_to_string(root().join(format!("examples/{name}.expected"))).unwrap();
            let (status, stdout) = execute(&image);
            assert_eq!(stdout, expected, "{name}");
            assert_eq!(status, Some(0), "{name}");
        }
    }
}

#[test]
fn shape_512_bytes_reads_last_field() {
    let image = temp("native_cfg_wide_64.elf");
    let out = backend(&root().join("examples/native_cfg_wide_64.lir"), &image);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        let (status, stdout) = execute(&image);
        assert_eq!(status, Some(42));
        assert_eq!(stdout, "");
    }
}

#[test]
fn invalid_wide_shapes_and_duplicate_moves_are_rejected() {
    for (name, expected) in [
        ("native_cfg_wide_bad_type.lir", 66),
        ("native_cfg_wide_bad_count.lir", 65),
        ("native_cfg_wide_double_move.lir", 57),
        ("native_cfg_wide_too_many_fields.lir", 60),
        ("native_cfg_wide_too_many_args.lir", 64),
    ] {
        let out = backend(
            &root().join("examples").join(name),
            &temp("rejected.elf"),
        );
        assert_eq!(out.status.code(), Some(3), "{name}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains(&format!("rechazado (código {expected})")),
            "{name}: {stderr}"
        );
    }
}
