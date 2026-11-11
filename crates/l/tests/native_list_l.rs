//! `List of[T]` and local loans through the ELE-written backend: literals,
//! push with buffer growth, reserve, capacity, checked indexing, lists of
//! Text, of shapes and of lists, lists in shape fields, `each` over owning
//! elements (the loop variable is a reference) and `view`/`edit` locals.
//! `.l` source -> Stage 1 -> ELE-LIR -> x86-64 -> ELF64. Every host checks
//! acceptance, rejection and the image header; Linux x86-64 also executes the
//! images and compares their stdout byte for byte with the output Stage 0
//! produced for the same sources.
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
    let dir = root().join("target/stage1-tests/native-list");
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
fn lists_and_local_loans_match_stage0() {
    for (name, forms) in [
        (
            "native_list_int_stage1",
            &[
                "list l0 i",
                "list l1 b",
                "i listlit v",
                "i listpush p0 v",
                "i listreserve p",
                "i cap v",
                "i store p0[v",
                "i read v",
                "i dropfield p",
            ][..],
        ),
        (
            "native_list_owned_stage1",
            &[" t\n", "i listpush p0.0 v", "i print ref p", "i drop v"][..],
        ),
        (
            "native_loans_stage1",
            &["i loan v", " 0 @", " 1 @", "i print ref p"][..],
        ),
        (
            "native_list_replace_stage1",
            &["i store p", "[v", "i drop v"][..],
        ),
    ] {
        let emitted = Command::new(sema())
            .arg(root().join(format!("examples/{name}.l")))
            .arg("--emit-lir")
            .output()
            .unwrap();
        assert!(
            emitted.status.success(),
            "Stage 1: {}",
            String::from_utf8_lossy(&emitted.stderr)
        );
        let lir = String::from_utf8(emitted.stdout).unwrap();
        for form in forms {
            assert!(lir.contains(form), "{name}: {form}\n{lir}");
        }
        let lir_file = temp(&format!("{name}.lir"));
        fs::write(&lir_file, &lir).unwrap();
        let image = temp(&format!("{name}.elf"));
        let built = backend(&lir_file, &image);
        assert!(
            built.status.success(),
            "backend ELE: {}\n{lir}",
            String::from_utf8_lossy(&built.stderr)
        );
        let bytes = fs::read(&image).unwrap();
        assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
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

/// Hand-written LIR that the backend accepts. The exit status is the value
/// read back, or the trap of the run-time check: 127 for an index out of
/// range (negative ones too) and 123 for a negative reservation.
#[test]
fn accepted_list_fixtures_run_and_trap() {
    for (fixture, _status) in [
        ("native_cfg_list_index_ok", 2),
        ("native_cfg_list_elem_ref_ok", 42),
        ("native_cfg_loan_ok", 42),
        ("native_cfg_list_index_oob", 127),
        ("native_cfg_list_index_negative", 127),
        ("native_cfg_list_reserve_negative", 123),
        ("native_cfg_list_elem_store_owned", 0),
    ] {
        let image = temp(&format!("{fixture}.elf"));
        let out = backend(&root().join(format!("examples/{fixture}.lir")), &image);
        assert!(
            out.status.success(),
            "{fixture}: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
        {
            let (code, stdout) = execute(&image);
            assert_eq!(stdout, "", "{fixture}");
            assert_eq!(code, Some(_status), "{fixture}");
        }
    }
}

#[test]
fn unsound_list_and_loan_lir_is_rejected() {
    for (fixture, code) in [
        // Ownership of the list itself.
        ("native_cfg_list_leak.lir", 59),
        ("native_cfg_list_overwrite.lir", 59),
        ("native_cfg_list_double_drop.lir", 57),
        ("native_cfg_list_use_after_move.lir", 57),
        ("native_cfg_list_index_uninit.lir", 57),
        // An element that owns memory cannot be copied out.
        ("native_cfg_list_elem_move.lir", 103),
        ("native_cfg_list_dropfield_index.lir", 92),
        // Types and shape of the instructions.
        ("native_cfg_list_push_type.lir", 102),
        ("native_cfg_list_push_self.lir", 104),
        ("native_cfg_list_elem_store_root.lir", 104),
        ("native_cfg_list_bad_decl.lir", 100),
        ("native_cfg_list_index_nonlist.lir", 33),
        ("native_cfg_list_index_bool.lir", 33),
        // References: growth needs `edit`; a list and one of its elements
        // cannot be passed together when one of them is exclusive.
        ("native_cfg_list_shared_push.lir", 98),
        ("native_cfg_list_alias.lir", 99),
        // Local loans: dead after the root grows, moves, is dropped or is
        // loaned exclusively; one loan per reference; writes need `edit`.
        ("native_cfg_loan_after_push.lir", 57),
        ("native_cfg_loan_after_move.lir", 57),
        ("native_cfg_loan_after_drop.lir", 57),
        ("native_cfg_loan_exclusive_kills.lir", 57),
        ("native_cfg_loan_undefined.lir", 57),
        ("native_cfg_loan_shared_write.lir", 98),
        ("native_cfg_loan_dropfield.lir", 95),
        ("native_cfg_loan_not_ref.lir", 96),
        ("native_cfg_loan_twice.lir", 96),
    ] {
        let out = backend(
            &root().join("examples").join(fixture),
            &temp("rejected.elf"),
        );
        assert_eq!(out.status.code(), Some(3), "{fixture}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains(&format!("rechazado (código {code})")),
            "{fixture}: {stderr}"
        );
    }
}

/// Stage 1 binds the variable of `each` over owning elements as a reference:
/// the body cannot move the element out nor grow the collection, as in
/// Stage 0. A live element loan also forbids replacing its owner. Before,
/// Stage 1 copied the `each` element and emitted LIR owning Text twice.
#[test]
fn stage1_rejects_invalid_list_loans() {
    for (name, source, code) in [
        (
            "each_move",
            "flow main() {\n    hold ts: List of[Text] = List[\"a{1}\", \"b{2}\"]\n    change otra: List of[Text] = List[]\n    each t among ts {\n        otra@push(t)\n    }\n    print(otra.length)\n}\n",
            "L0005",
        ),
        (
            "each_grow",
            "flow main() {\n    change ts: List of[Text] = List[\"a{1}\", \"b{2}\"]\n    each t among ts {\n        ts@push(\"x\")\n        print(t)\n    }\n}\n",
            "L0012",
        ),
        (
            "overwrite_loan",
            "flow main() {\n    change xs: List of[Text] = List[\"old\"]\n    hold r = view xs[0]\n    xs[0] = \"new\"\n    print(r)\n}\n",
            "L0012",
        ),
    ] {
        let file = temp(&format!("{name}.l"));
        fs::write(&file, source).unwrap();
        let out = Command::new(sema())
            .arg(&file)
            .arg("--emit-lir")
            .output()
            .unwrap();
        assert!(!out.status.success(), "{name}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains(code), "{name}: {stderr}");
        assert!(out.stdout.is_empty(), "{name}: no LIR after an error");
    }
}

/// `view xs[i]` and `edit xs[i]` loan the element, not the whole list.
#[test]
fn stage1_loans_the_indexed_element() {
    let file = temp("loan_element.l");
    fs::write(
        &file,
        "shape Ficha {\n    clave: Text\n    peso: Int\n}\nshape Mesa {\n    fichas: List of[Ficha]\n    total: Int\n}\nflow engordar(m: edit Mesa, i: Int, extra: Int) {\n    hold f = edit m.fichas[i]\n    f.peso += extra\n}\nflow main() { }\n",
    )
    .unwrap();
    let out = Command::new(sema())
        .arg(&file)
        .arg("--emit-lir")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let lir = String::from_utf8(out.stdout).unwrap();
    assert!(lir.contains("i loan v3 p0.0[v1] 1"), "{lir}");
}
