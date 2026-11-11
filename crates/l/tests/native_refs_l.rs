//! `view`/`edit` reference parameters, Text queries (`byteLength`,
//! `byteAt`) and checked arithmetic (`/`, `%`, unary `-` and `!`) through
//! the ELE-written backend: `.l` source -> Stage 1 -> ELE-LIR -> x86-64 ->
//! ELF64. Every host checks acceptance, rejection and the image header;
//! Linux x86-64 also executes the images and compares their stdout byte for
//! byte with the output Stage 0 produced for the same sources.
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
    let dir = root().join("target/stage1-tests/native-refs");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}

/// Compiles a `.l` source to an ELF64 image using only Stage 1 components
/// and returns the image together with the LIR Stage 1 emitted.
fn compile(source: &Path, name: &str) -> (PathBuf, String) {
    let emitted = Command::new(sema())
        .arg(source)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        emitted.status.success(),
        "Stage 1: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    let lir_file = temp(&format!("{name}.lir"));
    fs::write(&lir_file, &lir).unwrap();
    let image = temp(&format!("{name}.elf"));
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "backend ELE: {}\n{lir}",
        String::from_utf8_lossy(&built.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert!(bytes.len() > 4096);
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    (image, lir)
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

fn rejected(fixture: &str, code: u32) {
    let out = Command::new(native())
        .arg(root().join("examples").join(fixture))
        .arg(temp("rejected.elf"))
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(3), "{fixture}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains(&format!("rechazado (código {code})")),
        "{fixture}: {stderr}"
    );
}

/// Canonical sources whose expected output is what Stage 0 printed.
#[test]
fn reference_text_and_arithmetic_programs_match_stage0() {
    for (name, lir_forms) in [
        (
            "native_refs_stage1",
            &[
                "var v0 ref s1",
                "ref p0 1",
                "i store p0.1.0",
                "var v0 ref t",
                "i print ref p0 0",
                "var v0 ref e0",
                "i unary",
                "i byteat",
            ][..],
        ),
        (
            "native_text_query_stage1",
            &["var v0 ref t", "i len", "i byteat", "i store p0 "][..],
        ),
        (
            "native_arith_stage1",
            &[" div ", " rem ", "unary v", " not "][..],
        ),
    ] {
        let (image, lir) = compile(&root().join(format!("examples/{name}.l")), name);
        for form in lir_forms {
            assert!(lir.contains(form), "{name}: {form}\n{lir}");
        }
        let _ = &image;
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let expected =
                fs::read_to_string(root().join(format!("examples/{name}.expected"))).unwrap();
            let (code, stdout) = execute(&image);
            assert_eq!(stdout, expected, "{name}");
            assert_eq!(code, Some(0), "{name}");
        }
    }
}

/// Run-time guards. Stage 0 stops every one of these with an error; the
/// native image exits 125 (arithmetic) or 127 (index) after the output that
/// precedes the failure, and never prints what follows it.
#[test]
fn arithmetic_and_index_failures_stop_with_their_status() {
    for (name, body, call, _status) in [
        ("div_zero", "a / b", "f(5, 0)", 125),
        ("rem_zero", "a % b", "f(5, 0)", 125),
        ("div_min", "a / b", "f(m, -1)", 125),
        ("rem_min", "a % b", "f(m, -1)", 125),
        ("neg_min", "-a + b", "f(m, 0)", 125),
        ("index_len", "a", "g(view t, 3)", 127),
        ("index_negative", "a", "g(view t, -1)", 127),
        ("index_last", "a", "g(view t, 2)", 0),
    ] {
        let source = temp(&format!("{name}.l"));
        fs::write(
            &source,
            format!(
                "flow f(a: Int, b: Int) => Int {{\n    give {body}\n}}\n\n\
                 flow g(t: view Text, i: Int) => Int {{\n    give t.byteAt(i)\n}}\n\n\
                 flow main() {{\n    hold m = -9223372036854775807 - 1\n    \
                 hold t = \"abc\"\n    print(1)\n    print({call})\n    print(2)\n}}\n"
            ),
        )
        .unwrap();
        let (image, _) = compile(&source, name);
        let _ = &image;
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(code, Some(_status), "{name}");
            let expected = if _status == 0 { "1\n99\n2\n" } else { "1\n" };
            assert_eq!(stdout, expected, "{name}");
        }
    }
}

#[test]
fn reference_fixtures_with_valid_loans_build() {
    for (fixture, _status, image_name) in [
        ("native_cfg_ref_store_ok.lir", 7, "store_ok.elf"),
        ("native_cfg_ref_local.lir", 1, "local_ref.elf"),
    ] {
        let image = temp(image_name);
        let out = Command::new(native())
            .arg(root().join("examples").join(fixture))
            .arg(&image)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{fixture}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(stdout, "");
            assert_eq!(code, Some(_status), "{fixture}");
        }
    }
}

#[test]
fn unsound_reference_forms_are_rejected() {
    // Local references require an explicit loan; malformed or missing loans
    // are covered by native_list_l::unsound_list_and_loan_lir_is_rejected.
    // A reference is never assigned, copied, returned or dropped.
    rejected("native_cfg_ref_as_dst.lir", 96);
    rejected("native_cfg_ref_as_value.lir", 34);
    rejected("native_cfg_ref_return.lir", 41);
    rejected("native_cfg_ref_returnref.lir", 44);
    rejected("native_cfg_ref_drop.lir", 95);
    // Moving a Text out of its referent would duplicate the buffer.
    rejected("native_cfg_ref_read_text.lir", 95);
    // Writing through a shared reference, directly or forwarded.
    rejected("native_cfg_ref_shared_write.lir", 98);
    rejected("native_cfg_ref_forward_shared.lir", 98);
    // Aliasing an exclusive reference, or moving a borrowed value.
    rejected("native_cfg_ref_alias.lir", 99);
    rejected("native_cfg_ref_move_alias.lir", 99);
    // Borrowing an uninitialized variable.
    rejected("native_cfg_ref_uninit.lir", 57);
    // A reference argument for a by-value parameter.
    rejected("native_cfg_call_ref_arg.lir", 54);
    // Ill-typed Text queries and unary operators.
    rejected("native_cfg_text_query_bad.lir", 97);
    rejected("native_cfg_text_byteat_bool.lir", 97);
    rejected("native_cfg_unary_bad.lir", 36);
}
