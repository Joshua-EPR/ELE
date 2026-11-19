//! Executes ELF64 images emitted by the ELE-written backend and, when
//! `strace` is available, checks the balance of their heap: every buffer the
//! runtime maps (mmap, mremap) is unmapped exactly once (munmap).
//!
//! Images run natively on Linux x86-64, and on Windows through WSL when
//! `ELE_TEST_WSL_DISTRO` names a distribution (e.g. `Ubuntu`). Elsewhere
//! `execute` returns `None` and the caller only checks the image.
#![allow(dead_code)]

use std::{collections::BTreeSet, fs, path::Path, process::Command};

pub struct ElfRun {
    pub code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    /// `None` when `strace` is not installed on the executing host.
    pub heap: Option<HeapTrace>,
}

/// Heap system calls of one run, matched by address.
#[derive(Debug)]
pub struct HeapTrace {
    pub maps: usize,
    pub unmaps: usize,
    pub remaps: usize,
    /// munmap/mremap of an address that is not currently mapped: a double
    /// or invalid release.
    pub bad_releases: Vec<String>,
    /// Buffers still mapped at exit.
    pub leaked: usize,
}

impl HeapTrace {
    pub fn assert_balanced(&self, what: &str) {
        assert!(
            self.bad_releases.is_empty(),
            "{what}: release of an unmapped buffer {:?}",
            self.bad_releases
        );
        assert_eq!(self.leaked, 0, "{what}: leaked buffers ({self:?})");
        assert_eq!(self.maps, self.unmaps, "{what}: {self:?}");
    }
}

/// The return value of a traced call; strace pads it with spaces, as in
/// `munmap(0x7f00, 4096)      = 0`.
fn result_of(line: &str) -> Option<&str> {
    let (call, value) = line.rsplit_once(" = ")?;
    call.trim_end()
        .ends_with(')')
        .then(|| value.split_whitespace().next().unwrap_or(""))
}

fn first_argument(line: &str) -> Option<&str> {
    let open = line.find('(')?;
    let rest = &line[open + 1..];
    Some(rest.split([',', ')']).next()?.trim())
}

pub fn parse_heap_trace(trace: &str) -> HeapTrace {
    let mut live = BTreeSet::new();
    let mut heap = HeapTrace {
        maps: 0,
        unmaps: 0,
        remaps: 0,
        bad_releases: Vec::new(),
        leaked: 0,
    };
    for raw in trace.lines() {
        // With -f every line starts with the pid.
        let line = raw.trim_start_matches(|c: char| c.is_ascii_digit()).trim();
        if line.starts_with("mmap(") {
            let address = result_of(line).unwrap_or("?");
            if address.starts_with("0x") {
                heap.maps += 1;
                live.insert(address.to_string());
            }
        } else if line.starts_with("mremap(") {
            heap.remaps += 1;
            let old = first_argument(line).unwrap_or("?").to_string();
            let new = result_of(line).unwrap_or("?").to_string();
            if new.starts_with("0x") {
                if !live.remove(&old) {
                    heap.bad_releases.push(raw.to_string());
                }
                live.insert(new);
            }
        } else if line.starts_with("munmap(") {
            heap.unmaps += 1;
            let address = first_argument(line).unwrap_or("?").to_string();
            if result_of(line) != Some("0") || !live.remove(&address) {
                heap.bad_releases.push(raw.to_string());
            }
        }
    }
    heap.leaked = live.len();
    heap
}

/// Runs `image` with `args` inside `work` (a fresh directory owned by the
/// caller). Returns `None` when this host cannot execute ELF64.
pub fn execute(image: &Path, work: &Path, args: &[&str]) -> Option<ElfRun> {
    let program = work.join("prog");
    let trace = work.join("heap.trace");
    fs::copy(image, &program).unwrap();
    let _ = fs::remove_file(&trace);
    let script = "cd \"$1\" && shift && chmod 700 prog && \
                  if command -v strace >/dev/null 2>&1; then \
                  exec strace -f -qq -e trace=mmap,munmap,mremap -o heap.trace ./prog \"$@\"; \
                  else exec ./prog \"$@\"; fi";
    let output = if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
        Command::new("sh")
            .args(["-c", script, "sh"])
            .arg(work)
            .args(args)
            .output()
            .unwrap()
    } else if cfg!(windows) {
        let distro = std::env::var("ELE_TEST_WSL_DISTRO").ok()?;
        // C:\a\b -> /mnt/c/a/b, without `..` components or a `\\?\` prefix.
        let canonical = work.canonicalize().unwrap();
        let windows = canonical
            .to_string_lossy()
            .trim_start_matches(r"\\?\")
            .replace('\\', "/");
        let (drive, rest) = windows.split_once(":/").expect("absolute Windows path");
        let linux = format!("/mnt/{}/{rest}", drive.to_ascii_lowercase());
        // One launch at a time per test binary, and a retry when wsl.exe
        // itself fails (status -1, e.g. "the operation timed out" while the
        // VM is busy): a Linux exit status is always 0..=255, so -1 never
        // comes from the image.
        static WSL: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _one_at_a_time = WSL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let mut attempt = 0;
        loop {
            let _ = fs::remove_file(&trace);
            let output = Command::new("wsl")
                .args(["-d", &distro, "--exec", "sh", "-c", script, "sh", &linux])
                .args(args)
                .output()
                .unwrap();
            attempt += 1;
            if output.status.code() != Some(-1) || attempt == 3 {
                break output;
            }
        }
    } else {
        return None;
    };
    let heap = fs::read_to_string(&trace)
        .ok()
        .map(|text| parse_heap_trace(&text));
    if heap.is_none() {
        use std::io::Write;
        let _ = writeln!(
            std::io::stderr(),
            "SKIP[heap-balance]: strace is not available; {} ran without heap tracing",
            image.display()
        );
    }
    Some(ElfRun {
        code: output.status.code(),
        stdout: String::from_utf8(output.stdout).unwrap(),
        stderr: String::from_utf8(output.stderr).unwrap(),
        heap,
    })
}
