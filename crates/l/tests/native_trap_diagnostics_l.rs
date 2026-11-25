//! Run-time trap diagnostics of the ELE-written backend
//! (`compiler-l/src/codegen/native_trap.l`).
//!
//! A program built by the ELE driver (`main_driver build`) that fails a
//! run-time check must write one line to standard error, in the format of
//! Stage 0 (`ELE <line>:<col>: <message>`), and keep the exit status of the
//! check: 125 arithmetic (overflow, division or remainder by zero), 126
//! inactive enum variant, 127 index out of range. Output printed before the
//! failure is kept. PE32+ images run on Windows; ELF64 images run on Linux
//! x86-64 or through WSL with `ELE_TEST_WSL_DISTRO`.
//!
//! The positions are the ` @line:col` suffixes Stage 1 writes into the LIR.
//! For arithmetic they coincide with Stage 0, which the tests check against
//! the Cranelift build of the same source. For an index Stage 1 records the
//! start of the indexed expression where Stage 0 points at the `[` or `@`.
#[path = "stage1_support/elf_exec.rs"]
mod elf_exec;
mod image_support;
#[allow(dead_code)]
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

const ARITH: &str = ": overflow entero o división/resto por cero\n";
const INDEX: &str = ": índice fuera de rango\n";
const VARIANT: &str = ": acceso a variante enum inactiva\n";

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn driver() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build_self_executing("main_driver"))
}

fn native() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build_self_executing("native_cfg_demo"))
}

fn work(name: &str) -> PathBuf {
    let dir = root()
        .join("target/stage1-tests/trap-diagnostics")
        .join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// Builds `source` with the driver for `target` (`pe` or `elf`).
fn build(dir: &Path, source: &str, target: &str) -> PathBuf {
    let src = dir.join("prog.l");
    fs::write(&src, source).unwrap();
    let image = dir.join(format!("prog.{target}"));
    let out = Command::new(driver())
        .arg("build")
        .arg(&src)
        .args(["--target", target, "--output"])
        .arg(&image)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "driver build ({target}): {}",
        String::from_utf8_lossy(&out.stderr)
    );
    image
}

struct Run {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

fn run_pe(image: &Path) -> Option<Run> {
    if !cfg!(all(windows, target_arch = "x86_64")) {
        return None;
    }
    let exe = image.with_extension("exe");
    fs::copy(image, &exe).unwrap();
    let out = Command::new(&exe).output().unwrap();
    Some(Run {
        code: out.status.code(),
        stdout: String::from_utf8(out.stdout).unwrap(),
        stderr: String::from_utf8(out.stderr).unwrap(),
    })
}

fn run_elf(image: &Path, dir: &Path) -> Option<Run> {
    let run_dir = dir.join("elf-run");
    fs::create_dir_all(&run_dir).unwrap();
    match elf_exec::execute(image, &run_dir, &[]) {
        Some(run) => Some(Run {
            code: run.code,
            stdout: run.stdout,
            stderr: run.stderr,
        }),
        None => {
            image_support::not_run(&image.display().to_string(), "no ELF64 host");
            None
        }
    }
}

/// Builds and runs `source` on both targets and checks the exact streams.
fn check(name: &str, source: &str, stdout: &str, stderr: &str, code: i32) {
    for target in ["pe", "elf"] {
        let dir = work(&format!("{name}-{target}"));
        let image = build(&dir, source, target);
        let run = if target == "pe" {
            run_pe(&image)
        } else {
            run_elf(&image, &dir)
        };
        if let Some(run) = run {
            assert_eq!(run.stderr, stderr, "{name} [{target}] stderr");
            assert_eq!(run.stdout, stdout, "{name} [{target}] stdout");
            assert_eq!(run.code, Some(code), "{name} [{target}] exit status");
        }
    }
}

/// Stage 0 (Cranelift) diagnostic for the same source. The Cranelift
/// backend only targets Windows x86-64 (L0008 elsewhere).
fn stage0_stderr(name: &str, source: &str) -> Option<String> {
    if !cfg!(all(windows, target_arch = "x86_64")) {
        return None;
    }
    let dir = work(&format!("{name}-stage0"));
    let src = dir.join("prog.l");
    fs::write(&src, source).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_l"))
        .current_dir(&dir)
        .arg("build")
        .arg(&src)
        .args(["--backend", "cranelift"])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "Stage 0 build: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let built = String::from_utf8_lossy(&out.stdout).to_string();
    let path = built
        .lines()
        .find_map(|l| l.strip_prefix("Build: "))
        .expect("Stage 0 reports the built image");
    let run = Command::new(dir.join(path.trim())).output().unwrap();
    Some(String::from_utf8(run.stderr).unwrap())
}

const OVERFLOW: &str = "flow grow(n: Int) => Int {
    give n * 4611686018427387904
}

flow main() => Int {
    print(\"antes\")
    hold big = grow(4)
    print(big)
    give 0
}
";

const DIVISION: &str = "flow split(a: Int, b: Int) => Int {
    give a / b
}

flow main() => Int {
    print(\"antes\")
    print(split(7, 0))
    give 0
}
";

const REMAINDER: &str = "flow rest(a: Int, b: Int) => Int {
    give a % b
}

flow main() => Int {
    print(rest(7, 2))
    print(rest(7, 0))
    give 0
}
";

const LIST_INDEX: &str = "flow main() => Int {
    change xs: List of[Int] = List[]
    xs@push(1)
    xs@push(2)
    print(\"antes\")
    hold i = xs.length + 1
    print(xs[i])
    give 0
}
";

const LIST_STORE_INDEX: &str = "flow main() => Int {
    change xs: List of[Int] = List[]
    xs@push(1)
    hold i = xs.length + 1
    xs[i] = 2
    give 0
}
";

const BYTE_AT: &str = "flow main() => Int {
    hold t = \"abc\"
    print(\"antes\")
    print(t@byteAt(5))
    give 0
}
";

#[test]
fn overflow_reports_position_and_exits_125() {
    let expected = format!("ELE 2:10{ARITH}");
    check("overflow", OVERFLOW, "antes\n", &expected, 125);
    if let Some(stage0) = stage0_stderr("overflow", OVERFLOW) {
        assert_eq!(stage0, expected, "same diagnostic as Stage 0");
    }
}

#[test]
fn division_by_zero_reports_position_and_exits_125() {
    let expected = format!("ELE 2:10{ARITH}");
    check("division", DIVISION, "antes\n", &expected, 125);
    if let Some(stage0) = stage0_stderr("division", DIVISION) {
        assert_eq!(stage0, expected, "same diagnostic as Stage 0");
    }
}

#[test]
fn remainder_by_zero_reports_position_and_exits_125() {
    let expected = format!("ELE 2:10{ARITH}");
    check("remainder", REMAINDER, "1\n", &expected, 125);
}

#[test]
fn list_index_out_of_range_reports_position_and_exits_127() {
    let expected = format!("ELE 7:13{INDEX}");
    check("list-index", LIST_INDEX, "antes\n", &expected, 127);
    if let Some(stage0) = stage0_stderr("list-index", LIST_INDEX) {
        assert_eq!(stage0, expected, "same diagnostic as Stage 0");
    }
}

#[test]
fn list_store_index_out_of_range_reports_position_and_exits_127() {
    let expected = format!("ELE 5:7{INDEX}");
    check("list-store-index", LIST_STORE_INDEX, "", &expected, 127);
    if let Some(stage0) = stage0_stderr("list-store-index", LIST_STORE_INDEX) {
        assert_eq!(stage0, expected, "same diagnostic as Stage 0");
    }
}

#[test]
fn byte_at_out_of_range_reports_position_and_exits_127() {
    let expected = format!("ELE 4:12{INDEX}");
    check("byte-at", BYTE_AT, "antes\n", &expected, 127);
    if let Some(stage0) = stage0_stderr("byte-at", BYTE_AT) {
        assert_eq!(stage0, expected, "same diagnostic as Stage 0");
    }
}

/// A program without run-time checks carries no reporter: nothing is
/// written to stderr and no diagnostic text is in the image.
#[test]
fn program_without_checks_has_no_trap_reporter() {
    let source = "flow main() => Int {\n    print(\"hola\")\n    give 0\n}\n";
    for target in ["pe", "elf"] {
        let dir = work(&format!("no-checks-{target}"));
        let image = build(&dir, source, target);
        let bytes = fs::read(&image).unwrap();
        for message in [ARITH, INDEX, VARIANT] {
            assert!(
                !bytes
                    .windows(message.len())
                    .any(|w| w == message.as_bytes()),
                "[{target}] unexpected trap message {message:?}"
            );
        }
    }
    check("no-checks", source, "hola\n", "", 0);
}

/// The inactive-variant check (126) through hand-written LIR: without a
/// position the line is `ELE: <message>`, as Stage 0's unlocated panics;
/// with ` @line:col` on the record the position is reported.
#[test]
fn inactive_variant_reports_and_exits_126() {
    let fixture =
        fs::read_to_string(root().join("examples/native_cfg_enum_payload_wrong_active.lir"))
            .unwrap()
            .replace("\r\n", "\n");
    let record = "i payload v1 p0 e0 1\n";
    assert!(fixture.contains(record));
    let located = fixture.replace(record, "i payload v1 p0 e0 1 @3:14\n");
    for (name, lir, expected) in [
        (
            "variant-unlocated",
            fixture.as_str(),
            format!("ELE{VARIANT}"),
        ),
        (
            "variant-located",
            located.as_str(),
            format!("ELE 3:14{VARIANT}"),
        ),
    ] {
        for pe in [true, false] {
            let dir = work(&format!("{name}-{}", if pe { "pe" } else { "elf" }));
            let input = dir.join("prog.lir");
            fs::write(&input, lir).unwrap();
            let image = dir.join(if pe { "prog.pe" } else { "prog.elf" });
            let mut cmd = Command::new(native());
            cmd.arg(&input).arg(&image);
            if pe {
                cmd.arg("--pe64");
            }
            let out = cmd.output().unwrap();
            assert!(
                out.status.success(),
                "{name}: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            let run = if pe {
                run_pe(&image)
            } else {
                run_elf(&image, &dir)
            };
            if let Some(run) = run {
                assert_eq!(run.stderr, expected, "{name} stderr");
                assert_eq!(run.stdout, "", "{name} stdout");
                assert_eq!(run.code, Some(126), "{name} exit status");
            }
        }
    }
}
