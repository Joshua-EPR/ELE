use std::{env, path::PathBuf, process::Command};

fn main() {
    let source = "src/native/platform_object.rs";
    println!("cargo:rerun-if-changed={source}");
    println!("cargo:rerun-if-changed=src/platform_contract.inc.rs");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows")
        || env::var("CARGO_CFG_TARGET_ARCH").as_deref() != Ok("x86_64")
    {
        return;
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("l_platform.obj");
    let status = Command::new(env::var_os("RUSTC").unwrap())
        .args([
            "--crate-name",
            "l_platform",
            "--crate-type=lib",
            "--edition=2024",
            "--emit=obj",
            "-Cpanic=abort",
            "-Copt-level=2",
            "--target",
            &env::var("TARGET").unwrap(),
            source,
            "-o",
        ])
        .arg(out)
        .status()
        .expect("could not start rustc for the Win64 platform object");
    assert!(
        status.success(),
        "could not build the Win64 platform object"
    );
}
