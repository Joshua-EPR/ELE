//! Native conformance corpus (`tests/native_corpus`) enforced through cargo
//! while Stage 0 still exists.
//!
//! The corpus itself needs only an ELE compiler binary: `run.ps1` (PE32+ on
//! Windows) and `run.sh` (ELF64 on Linux) compile every case with
//! `<driver> build <file.l> --target pe|elf --output <path>`, run it and
//! compare stdout bytes, exit statuses and reject diagnostics. This test only
//! builds the ELE-written driver (`compiler-l/src/main_driver.l`) with Stage 0
//! and hands it to those same runners, so the scripts that will outlive
//! Stage 0 are what CI exercises:
//!
//! * PE32+: on Windows, `run.ps1` with the Stage-0-built driver.
//! * ELF64: on Linux x86-64, `run.sh` with the Stage-0-built (Linux) driver;
//!   on Windows with `ELE_TEST_WSL_DISTRO` set, the driver first rebuilds
//!   itself as an ELF64 image and `run.sh` runs inside that WSL distro.
//!   Hosts that cannot execute ELF64 print an explicit NOT RUN line and fail
//!   when `ELE_REQUIRE_NATIVE_EXEC=1`.
//!
//! A meta test feeds the runner deliberately wrong expectations to prove it
//! fails on stdout, exit status, diagnostic and XPASS mismatches.
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

fn corpus() -> PathBuf {
    root().join("tests/native_corpus")
}

fn driver() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_driver", false))
}

fn work(name: &str) -> PathBuf {
    let dir = root()
        .join("target/stage1-tests/native-corpus")
        .join(format!("{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn report(output: &Output) -> String {
    format!(
        "status: {:?}\n--- stdout\n{}\n--- stderr\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// Runs the runner of this host's native format over `corpus_dir`.
fn run_native_runner(compiler: &Path, corpus_dir: &Path) -> Option<Output> {
    if cfg!(windows) {
        return Some(
            Command::new("powershell")
                .args([
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                ])
                .arg("-File")
                .arg(corpus().join("run.ps1"))
                .arg(compiler)
                .arg("-Corpus")
                .arg(corpus_dir)
                .output()
                .expect("failed to start powershell"),
        );
    }
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        return Some(
            Command::new("sh")
                .arg(corpus().join("run.sh"))
                .arg(compiler)
                .env("ELE_CORPUS_DIR", corpus_dir)
                .output()
                .expect("failed to start sh"),
        );
    }
    None
}

fn not_run(what: &str) {
    use std::io::Write;
    let _ = writeln!(
        std::io::stderr(),
        "NOT RUN[native-corpus]: {what}; set ELE_TEST_WSL_DISTRO on Windows or run on Linux x86-64"
    );
    assert!(
        std::env::var_os(stage1_support::REQUIRE_NATIVE_EXEC).is_none_or(|v| v != "1"),
        "{}=1 but {what}",
        stage1_support::REQUIRE_NATIVE_EXEC
    );
}

fn wsl_path(path: &Path) -> String {
    let canonical = path.canonicalize().unwrap();
    let windows = canonical
        .to_string_lossy()
        .trim_start_matches(r"\\?\")
        .replace('\\', "/");
    let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
    format!("/mnt/{}/{rest}", drive.to_ascii_lowercase())
}

fn summary_line(output: &Output) -> String {
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .find(|line| line.starts_with("target="))
        .unwrap_or("<no summary>")
        .to_string()
}

#[test]
fn corpus_passes_on_pe() {
    if !cfg!(windows) {
        eprintln!("NOT RUN[native-corpus]: PE32+ images execute only on Windows");
        return;
    }
    let output = run_native_runner(driver(), &corpus()).unwrap();
    assert!(output.status.success(), "{}", report(&output));
    eprintln!("native corpus PE: {}", summary_line(&output));
}

#[test]
fn corpus_passes_on_elf() {
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        let output = run_native_runner(driver(), &corpus()).unwrap();
        assert!(output.status.success(), "{}", report(&output));
        eprintln!("native corpus ELF: {}", summary_line(&output));
        return;
    }
    let distro = match std::env::var("ELE_TEST_WSL_DISTRO") {
        Ok(distro) if cfg!(windows) => distro,
        _ => {
            not_run("the ELF64 corpus cannot run on this host");
            return;
        }
    };
    // The Stage-0-built driver rebuilds itself as an ELF64 driver, which then
    // compiles and runs every case inside the WSL distribution.
    let dir = work("elf-driver");
    let elf_driver = dir.join("ele-driver.elf");
    let built = Command::new(driver())
        .current_dir(root())
        .arg("build")
        .arg(root().join("compiler-l/src/main_driver.l"))
        .args(["--target", "elf", "--output"])
        .arg(&elf_driver)
        .output()
        .unwrap();
    assert!(built.status.success(), "{}", report(&built));
    let output = Command::new("wsl")
        .args(["-d", &distro, "--exec", "sh", "-c"])
        .arg("chmod 755 \"$1\" && exec sh \"$2\" \"$1\"")
        .arg("sh")
        .arg(wsl_path(&elf_driver))
        .arg(wsl_path(&corpus().join("run.sh")))
        .output()
        .unwrap();
    assert!(output.status.success(), "{}", report(&output));
    eprintln!("native corpus ELF (WSL): {}", summary_line(&output));
}

/// Copies one corpus case (and its expectation files) into `dir`.
fn copy_case(dir: &Path, sub: &str, name: &str, extensions: &[&str]) {
    let from = corpus().join(sub);
    let to = dir.join(sub);
    fs::create_dir_all(&to).unwrap();
    for ext in extensions {
        fs::copy(
            from.join(format!("{name}.{ext}")),
            to.join(format!("{name}.{ext}")),
        )
        .unwrap();
    }
}

fn row<'a>(output: &'a str, case: &str) -> &'a str {
    output
        .lines()
        .find(|line| line.split_whitespace().next() == Some(case))
        .unwrap_or_else(|| panic!("no row for {case}:\n{output}"))
}

#[test]
fn runner_fails_on_wrong_expectations() {
    // Mutated expectations: one byte of stdout (LF written as CRLF, which a
    // normalizing runner would hide), the exit status and a diagnostic.
    let dir = work("meta-mutated");
    copy_case(&dir, "", "hello", &["l", "stdout", "exit"]);
    copy_case(&dir, "", "exit_code_give", &["l", "stdout", "exit"]);
    copy_case(&dir, "", "text_bytes", &["l", "stdout", "exit"]);
    copy_case(&dir, "reject", "use_after_move", &["l", "diag"]);
    copy_case(&dir, "reject", "wrong_arity", &["l", "diag"]);
    fs::write(dir.join("exit_code_give.exit"), "43\n").unwrap();
    let stdout = fs::read_to_string(dir.join("text_bytes.stdout")).unwrap();
    fs::write(
        dir.join("text_bytes.stdout"),
        stdout.replacen('\n', "\r\n", 1),
    )
    .unwrap();
    fs::write(dir.join("reject/wrong_arity.diag"), "error[L9999]\n").unwrap();
    let Some(output) = run_native_runner(driver(), &dir) else {
        not_run("no native runner for this host");
        return;
    };
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    assert_eq!(output.status.code(), Some(1), "{}", report(&output));
    assert!(row(&text, "hello").contains("PASS"), "{text}");
    assert!(
        row(&text, "reject/use_after_move").contains("PASS"),
        "{text}"
    );
    let exit_row = row(&text, "exit_code_give");
    assert!(
        exit_row.contains("FAIL") && exit_row.contains("expected 43"),
        "{text}"
    );
    let stdout_row = row(&text, "text_bytes");
    assert!(
        stdout_row.contains("FAIL") && stdout_row.contains("differ"),
        "{text}"
    );
    let diag_row = row(&text, "reject/wrong_arity");
    assert!(
        diag_row.contains("FAIL") && diag_row.contains("L9999"),
        "{text}"
    );
    assert!(text.contains("pass=2 fail=3 xfail=0 xpass=0"), "{text}");
}

#[test]
fn runner_fails_when_a_known_gap_passes() {
    let dir = work("meta-xpass");
    copy_case(&dir, "", "hello", &["l", "stdout", "exit"]);
    copy_case(&dir, "", "exit_code_give", &["l", "stdout", "exit"]);
    fs::write(dir.join("exit_code_give.exit"), "43\n").unwrap();
    fs::write(
        dir.join("known_gaps.txt"),
        "hello all\nexit_code_give all\n",
    )
    .unwrap();
    let Some(output) = run_native_runner(driver(), &dir) else {
        not_run("no native runner for this host");
        return;
    };
    let text = String::from_utf8_lossy(&output.stdout).to_string();
    assert_eq!(output.status.code(), Some(1), "{}", report(&output));
    assert!(row(&text, "hello").contains("XPASS"), "{text}");
    assert!(row(&text, "exit_code_give").contains("XFAIL"), "{text}");

    // A gap list naming a case that does not exist is a layout error.
    fs::write(dir.join("known_gaps.txt"), "no_such_case all\n").unwrap();
    let output = run_native_runner(driver(), &dir).unwrap();
    assert_eq!(output.status.code(), Some(2), "{}", report(&output));
    // So is a source without expectations.
    fs::write(dir.join("known_gaps.txt"), "").unwrap();
    fs::write(
        dir.join("orphan.l"),
        "flow main() => Int {\n    give 0\n}\n",
    )
    .unwrap();
    let output = run_native_runner(driver(), &dir).unwrap();
    assert_eq!(output.status.code(), Some(2), "{}", report(&output));
}

/// The corpus is compared byte for byte, so no file may carry CR bytes (an
/// autocrlf checkout would break the expectations), every exit status must
/// be a portable process status and every known gap must be documented.
#[test]
fn corpus_files_are_well_formed() {
    let mut positive = 0;
    let mut reject = 0;
    for sub in ["", "reject", "modules"] {
        for entry in fs::read_dir(corpus().join(sub)).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                continue;
            }
            let name = path.file_name().unwrap().to_string_lossy().to_string();
            let bytes = fs::read(&path).unwrap();
            assert!(!bytes.contains(&b'\r'), "{sub}/{name} contains CR bytes");
            let Some(stem) = name.strip_suffix(".l") else {
                continue;
            };
            let dir = corpus().join(sub);
            match sub {
                "" => {
                    positive += 1;
                    let code: i64 = fs::read_to_string(dir.join(format!("{stem}.exit")))
                        .unwrap_or_else(|_| panic!("{stem}.exit missing"))
                        .trim()
                        .parse()
                        .unwrap();
                    assert!((0..=255).contains(&code), "{stem}.exit: {code}");
                    assert!(dir.join(format!("{stem}.stdout")).is_file(), "{stem}");
                }
                "reject" => {
                    reject += 1;
                    let diag = fs::read_to_string(dir.join(format!("{stem}.diag")))
                        .unwrap_or_else(|_| panic!("reject/{stem}.diag missing"));
                    assert!(
                        diag.lines().any(|l| l.contains("error[")),
                        "reject/{stem}.diag must name an error code"
                    );
                }
                _ => {}
            }
        }
    }
    assert!(positive >= 30, "only {positive} positive cases");
    assert!(reject >= 10, "only {reject} reject cases");
    let documented = fs::read_to_string(corpus().join("KNOWN_GAPS.md")).unwrap();
    let gaps = fs::read_to_string(corpus().join("known_gaps.txt")).unwrap();
    for line in gaps.lines() {
        let line = line.split('#').next().unwrap().trim();
        let Some(case) = line.split_whitespace().next() else {
            continue;
        };
        assert!(
            documented.contains(&format!("`{case}`")),
            "known gap {case} is not documented in KNOWN_GAPS.md"
        );
    }
}
