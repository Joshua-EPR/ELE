pub mod borrow_cases;
pub mod drop_cases;

use std::{fs, path::PathBuf, process::Command};

pub fn build(entry: &str, trace: bool) -> PathBuf {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let dir =
        root.join("target/stage1-tests")
            .join(entry)
            .join(if trace { "traced" } else { "normal" });
    fs::create_dir_all(&dir).unwrap();
    let source = root.join("compiler-l/src").join(format!("{entry}.l"));
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_l"));
    cmd.current_dir(&dir)
        .arg("build")
        .arg(source)
        .args(["--backend", "cranelift"]);
    if trace {
        cmd.arg("--trace-alloc");
    }
    let output = cmd.output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    dir.join(
        stdout
            .lines()
            .find_map(|line| line.strip_prefix("Build: "))
            .unwrap(),
    )
}

#[allow(dead_code)]
pub fn assert_heap(stderr: &str) {
    let (_, trace) = stderr.rsplit_once("l-alloc: ").expect(stderr);
    let field = |key: &str| -> u64 {
        trace
            .split_whitespace()
            .find_map(|word| word.strip_prefix(key))
            .unwrap_or_else(|| panic!("missing {key}: {trace}"))
            .parse()
            .unwrap()
    };
    assert!(field("allocs=") > 0, "{trace}");
    assert_eq!(field("allocs="), field("frees="), "{trace}");
    assert_eq!(field("file_opens="), field("file_closes="), "{trace}");
    assert_eq!(field("heap_ok="), 1, "{trace}");
}
