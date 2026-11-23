//! `textFromBytes` through the autonomous driver: `tests/std/text_from_bytes.l`
//! as PE32+ (run on Windows) and ELF64 (run on Linux, or WSL with
//! `ELE_TEST_WSL_DISTRO`), and its compile-time argument checks.
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

fn driver() -> &'static Path {
    static B: OnceLock<PathBuf> = OnceLock::new();
    B.get_or_init(|| stage1_support::build("main_driver", false))
}

fn work(name: &str) -> PathBuf {
    let dir = root()
        .join("target/stage1-tests/text-from-bytes")
        .join(name);
    if dir.exists() {
        fs::remove_dir_all(&dir).unwrap();
    }
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn build(source: &Path, target: &str, output: &Path) -> Output {
    Command::new(driver())
        .arg("build")
        .arg(source)
        .args(["--target", target, "--output"])
        .arg(output)
        .output()
        .expect("failed to run the autonomous driver")
}

fn execute_elf(image: &Path, dir: &Path) -> Option<Output> {
    let program = dir.join("prog_elf");
    fs::copy(image, &program).unwrap();
    let script = "cd \"$1\" && chmod 700 prog_elf && exec ./prog_elf";
    if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        return Some(
            Command::new("sh")
                .args(["-c", script, "sh"])
                .arg(dir)
                .output()
                .unwrap(),
        );
    }
    if !cfg!(windows) {
        return None;
    }
    let distro = std::env::var("ELE_TEST_WSL_DISTRO").ok()?;
    let canonical = dir.canonicalize().unwrap();
    let windows = canonical
        .to_string_lossy()
        .trim_start_matches(r"\\?\")
        .replace('\\', "/");
    let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
    let linux = format!("/mnt/{}/{rest}", drive.to_ascii_lowercase());
    Some(
        Command::new("wsl")
            .args(["-d", &distro, "--exec", "sh", "-c", script, "sh", &linux])
            .output()
            .unwrap(),
    )
}

fn assert_ok(run: &Output) {
    assert!(
        run.status.success(),
        "text_from_bytes failed with {:?} (the exit code names the check): {}",
        run.status.code(),
        String::from_utf8_lossy(&run.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&run.stdout).trim(),
        "text-from-bytes-ok"
    );
}

#[test]
fn text_from_bytes_pe64() {
    let dir = work("pe64");
    let exe = dir.join("text_from_bytes.exe");
    let out = build(&root().join("tests/std/text_from_bytes.l"), "pe", &exe);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    #[cfg(windows)]
    assert_ok(&Command::new(&exe).output().unwrap());
}

#[test]
fn text_from_bytes_elf64() {
    let dir = work("elf64");
    let elf = dir.join("text_from_bytes.elf");
    let out = build(&root().join("tests/std/text_from_bytes.l"), "elf", &elf);
    assert!(
        out.status.success(),
        "build failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    if let Some(run) = execute_elf(&elf, &dir) {
        assert_ok(&run);
    }
}

#[test]
fn text_from_bytes_rejects_wrong_arguments() {
    let dir = work("invalid");
    let cases = [
        (
            "flow main() => Int {\n    hold t = \"x\"\n    choose textFromBytes(t, 1) {\n        Ok(s): { give 0 },\n        Err(e): { give e },\n    }\n}\n",
            "textFromBytes requiere",
        ),
        (
            "flow main() => Int {\n    hold b: List of[Int] = List[65]\n    choose textFromBytes(b) {\n        Ok(s): { give 0 },\n        Err(e): { give e },\n    }\n}\n",
            "textFromBytes requiere",
        ),
    ];
    for (k, (source, fragment)) in cases.iter().enumerate() {
        let src = dir.join(format!("case{k}.l"));
        fs::write(&src, source).unwrap();
        let exe = dir.join(format!("case{k}.exe"));
        let out = build(&src, "pe", &exe);
        let all = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        assert!(!out.status.success(), "case {k} compiled");
        assert!(!exe.exists(), "case {k} wrote an executable");
        assert!(all.contains(fragment), "case {k}: {all}");
    }
}
