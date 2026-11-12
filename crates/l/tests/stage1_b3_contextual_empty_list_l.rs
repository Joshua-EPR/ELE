//! B3: an empty `List[]` takes its element type from the context where it
//! is written: a constructor field, a by-value parameter, the function
//! result (`give`/`return`), the place of an assignment or the element type
//! of an enclosing typed literal. Each context belongs to the literal it is
//! set for only; a nested literal gets its own context or none. Without a
//! context the literal stays outside ELE-LIR (L0016), and a context never
//! hides an element of the wrong type.
//! `.l` -> Stage 1 -> ELE-LIR -> Stage 0 protocol reader and `run-lir`, and
//! -> ELE backend -> ELF64 (executed on Linux x86-64), compared with Stage 0.
mod stage1_support;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
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
    let dir = root().join("target/stage1-tests/b3-contextual-empty-list");
    fs::create_dir_all(&dir).unwrap();
    dir.join(name)
}
fn emit(name: &str, source: &str) -> Output {
    let file = temp(&format!("{name}.l"));
    fs::write(&file, source).unwrap();
    Command::new(sema())
        .arg(&file)
        .arg("--emit-lir")
        .output()
        .unwrap()
}
fn stage0(command: &str, file: &Path) -> Output {
    Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(file.parent().unwrap())
        .arg(command)
        .arg(file)
        .output()
        .unwrap()
}

const VERTICAL: &str = "shape Bag {
    nums: List of[Int]
    names: List of[Text]
}

flow fresh() -> List of[Int] {
    give List[]
}

flow total(xs: List of[Int]) -> Int {
    change sum = 0
    each x among xs {
        sum = sum + x
    }
    give sum
}

flow count(xs: List of[Text]) -> Int {
    give xs.length
}

flow main() {
    change bag = Bag(nums: List[], names: List[])
    bag.nums.push(3)
    bag.nums.push(4)
    bag.names.push(\"ana\")
    bag.names.push(\"bo\")
    print(bag.nums.length)
    print(bag.nums[0] + bag.nums[1])
    print(bag.names[1])
    print(total(List[]))
    change more = fresh()
    more.push(5)
    print(more[0])
    more = List[]
    print(more.length)
    hold nested = Bag(nums: List[count(List[])], names: List[])
    print(nested.nums[0])
    hold grid: List of[List of[Int]] = List[List[], List[]]
    print(grid.length)
}
";

/// Shape fields, call argument, result and assignment contexts, plus a
/// literal nested in another context: Stage 1 emits the registered
/// `listlit` form, the Stage 0 reader accepts it, and both the LIR run by
/// Stage 0 and the ELF64 of the ELE backend print what Stage 0 prints.
#[test]
fn contextual_empty_lists_lower_and_match_stage0() {
    let emitted = emit("vertical", VERTICAL);
    assert!(
        emitted.status.success(),
        "Stage 1: {}",
        String::from_utf8_lossy(&emitted.stderr)
    );
    let lir = String::from_utf8(emitted.stdout).unwrap();
    for form in [
        "list l0 i\n",
        "list l1 t\n",
        "i listlit v0 l0 0 @7:10",
        "i struct v2 s0 2 v0 v1",
        // The literal nested in a `List of[Int]` field is a `count`
        // argument: it gets `List of[Text]` from the parameter, not `Int`.
        "list l2 l0\n",
    ] {
        assert!(lir.contains(form), "{form}\n{lir}");
    }
    let module = project_l::lir_protocol::parse(&lir).unwrap();
    project_l::lir_protocol::validate(&module).unwrap();

    let source = temp("vertical.l");
    let expected = stage0("run", &source);
    assert!(expected.status.success(), "{expected:?}");
    let expected = String::from_utf8(expected.stdout).unwrap();
    assert_eq!(expected, "2\n7\nbo\n0\n5\n0\n0\n2\n");

    let lir_file = temp("vertical.lir");
    fs::write(&lir_file, &lir).unwrap();
    let ran = stage0("run-lir", &lir_file);
    assert!(ran.status.success(), "{ran:?}");
    assert_eq!(String::from_utf8(ran.stdout).unwrap(), expected);

    let image = temp("vertical.elf");
    let built = Command::new(native())
        .arg(&lir_file)
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "backend ELE: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let bytes = fs::read(&image).unwrap();
    assert_eq!(&bytes[..7], b"\x7fELF\x02\x01\x01");
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&image).unwrap().permissions();
        permissions.set_mode(0o700);
        fs::set_permissions(&image, permissions).unwrap();
        let run = Command::new(&image).output().unwrap();
        assert!(run.stderr.is_empty());
        assert_eq!(run.status.code(), Some(0));
        assert_eq!(String::from_utf8(run.stdout).unwrap(), expected);
    }
}

/// Without a context `List[]` has no element type and stays outside
/// ELE-LIR; a context never accepts elements of another type.
#[test]
fn empty_list_without_or_against_context_is_rejected() {
    for (name, source, code) in [
        (
            "no_context_let",
            "flow main() {\n    change xs = List[]\n    print(xs.length)\n}\n",
            "L0016",
        ),
        (
            // Method arguments carry no list context.
            "no_context_method_arg",
            "flow main() {\n    change grid: List of[List of[Int]] = List[]\n    grid.push(List[])\n    print(grid.length)\n}\n",
            "L0016",
        ),
        (
            "field_elem_mismatch",
            "shape Bag {\n    nums: List of[Int]\n}\nflow main() {\n    hold b = Bag(nums: List[\"x\"])\n    print(b.nums.length)\n}\n",
            "L0003",
        ),
        (
            "arg_elem_mismatch",
            "flow n(xs: List of[Int]) -> Int {\n    give xs.length\n}\nflow main() {\n    print(n(List[\"x\"]))\n}\n",
            "L0003",
        ),
        (
            "result_elem_mismatch",
            "flow e() -> List of[Text] {\n    give List[1]\n}\nflow main() {\n    hold xs = e()\n    print(xs.length)\n}\n",
            "L0003",
        ),
        (
            "assign_elem_mismatch",
            "flow main() {\n    change xs: List of[Int] = List[]\n    xs = List[true]\n    print(xs.length)\n}\n",
            "L0003",
        ),
        (
            "field_not_a_list",
            "shape Bag {\n    n: Int\n}\nflow main() {\n    hold b = Bag(n: List[])\n    print(b.n)\n}\n",
            "L0004",
        ),
        (
            "param_not_a_list",
            "flow n(x: Int) -> Int {\n    give x\n}\nflow main() {\n    print(n(List[]))\n}\n",
            "L0004",
        ),
    ] {
        let out = emit(name, source);
        assert!(!out.status.success(), "{name}");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(stderr.contains(code), "{name}: {stderr}");
        assert!(out.stdout.is_empty(), "{name}: no LIR after an error");
    }
}
