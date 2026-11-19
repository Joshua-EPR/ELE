pub mod borrow_cases;
pub mod drop_cases;

use std::{fs, path::PathBuf, process::Command};

/// Backends whose ELF64 output is only executed under
/// `cfg(all(target_os = "linux", target_arch = "x86_64"))` in the tests.
const ELF_EMITTERS: [&str; 2] = ["native_cfg_demo", "native_stack_aggregate_demo"];
/// Set to `1` to turn the skipped ELF64 execution into a test failure.
pub const REQUIRE_NATIVE_EXEC: &str = "ELE_REQUIRE_NATIVE_EXEC";

/// On hosts that cannot execute ELF64, the runtime half of every native test
/// is compiled out and the test still reports `ok`. Make that skip explicit:
/// announce it once per test binary on the real stderr (libtest captures only
/// the print macros, so this line stays visible without `--nocapture`), and
/// fail when the caller demands execution.
fn announce_skipped_native_execution(entry: &str) {
    if !ELF_EMITTERS.contains(&entry) || cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        return;
    }
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        use std::io::Write;
        let _ = writeln!(
            std::io::stderr(),
            "SKIP[native-exec]: this host is not Linux x86-64; ELF64 images from `{entry}` are \
             built and structurally checked but NOT executed, so their runtime assertions \
             did not run. Set {REQUIRE_NATIVE_EXEC}=1 to fail instead."
        );
    });
    assert!(
        std::env::var_os(REQUIRE_NATIVE_EXEC).is_none_or(|v| v != "1"),
        "{REQUIRE_NATIVE_EXEC}=1 but this host cannot execute the ELF64 images of `{entry}`"
    );
}

pub fn build(entry: &str, trace: bool) -> PathBuf {
    announce_skipped_native_execution(entry);
    // Tests of one binary run in parallel and may ask for the same entry;
    // two compilers writing the same output directory corrupt each other.
    static BUILDING: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _one_at_a_time = BUILDING
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let dir =
        root.join("target/stage1-tests")
            .join(entry)
            .join(if trace { "traced" } else { "normal" });
    fs::create_dir_all(&dir).unwrap();
    let source = root.join("compiler-l/src").join(format!("{entry}.l"));
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_l"));
    cmd.current_dir(&dir).arg("build").arg(source);
    // Stage 0's Cranelift backend only targets Windows x86-64. On other
    // hosts Stage 1 is built through the reference rustc backend so that the
    // same Stage 1 sources, and the ELF64 images they produce, are exercised
    // there too. Allocation tracing exists only in the Cranelift runtime, so
    // traced builds keep requesting it and fail loudly where it is missing.
    if cfg!(windows) || trace {
        cmd.args(["--backend", "cranelift"]);
    }
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
