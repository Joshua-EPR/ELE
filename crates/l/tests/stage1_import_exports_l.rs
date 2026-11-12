//! Verify actual compiler modules resolve only exported cross-module
//! helpers, without weakening module privacy or ownership checks.
mod stage1_support;

use std::{
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

#[test]
fn ownership_and_lir_verifier_imported_helpers_are_public() {
    for file in ["ownership_l.l", "lir_verify_core.l"] {
        let source = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../compiler-l/src")
            .join(file);
        let result = Command::new(sema())
            .arg(&source)
            .arg("--check-ownership")
            .output()
            .unwrap();
        assert_eq!(
            result.status.code(),
            Some(0),
            "{file}: {}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
}
