//! Links objects produced by the native backend into executables using the
//! system linker. First platform: Windows x86-64 with MSVC `link.exe` and the
//! Windows SDK `kernel32.lib`; no C runtime and no Rust code are linked.
//!
//! Overrides: `L_LINKER` (path to link.exe) and `L_LIBPATH` (`;`-separated
//! directories containing kernel32.lib).
use std::{
    path::{Path, PathBuf},
    process::Command,
};

pub struct Toolchain {
    pub linker: PathBuf,
    pub libpaths: Vec<PathBuf>,
}

/// Highest-versioned subdirectory of `dir` (versions like `14.44.35207`).
fn newest(dir: &Path, accept: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let mut candidates: Vec<(Vec<u64>, PathBuf)> = std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| accept(p))
        .filter_map(|p| {
            let version = p
                .file_name()?
                .to_str()?
                .split('.')
                .map(|n| n.parse().ok())
                .collect::<Option<Vec<u64>>>()?;
            Some((version, p))
        })
        .collect();
    candidates.sort();
    candidates.pop().map(|(_, p)| p)
}

fn find_link_exe() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("L_LINKER") {
        return Ok(path.into());
    }
    let program_files = std::env::var_os("ProgramFiles(x86)")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Program Files (x86)"));
    let vswhere = program_files.join(r"Microsoft Visual Studio\Installer\vswhere.exe");
    let output = Command::new(&vswhere)
        .args([
            "-latest",
            "-products",
            "*",
            "-requires",
            "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
            "-property",
            "installationPath",
        ])
        .output()
        .map_err(|e| format!("no se encontró vswhere ({}): {e}", vswhere.display()))?;
    let install = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if install.is_empty() {
        return Err("no se encontraron herramientas C++ de Visual Studio (link.exe); instale Build Tools o defina L_LINKER".into());
    }
    let tools = PathBuf::from(install).join(r"VC\Tools\MSVC");
    let version = newest(&tools, |p| p.join(r"bin\Hostx64\x64\link.exe").exists())
        .ok_or_else(|| format!("no hay link.exe x64 en {}", tools.display()))?;
    Ok(version.join(r"bin\Hostx64\x64\link.exe"))
}

fn find_kernel32() -> Result<Vec<PathBuf>, String> {
    if let Some(paths) = std::env::var_os("L_LIBPATH") {
        return Ok(std::env::split_paths(&paths).collect());
    }
    let program_files = std::env::var_os("ProgramFiles(x86)")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Program Files (x86)"));
    let kits = program_files.join(r"Windows Kits\10\Lib");
    let version = newest(&kits, |p| p.join(r"um\x64\kernel32.lib").exists()).ok_or_else(|| {
        format!(
            "no se encontró kernel32.lib del Windows SDK en {}; instálelo o defina L_LIBPATH",
            kits.display()
        )
    })?;
    Ok(vec![version.join(r"um\x64")])
}

pub fn find() -> Result<Toolchain, String> {
    if !cfg!(all(windows, target_arch = "x86_64")) {
        return Err("el enlazado nativo solo está implementado para Windows x86-64".into());
    }
    Ok(Toolchain {
        linker: find_link_exe()?,
        libpaths: find_kernel32()?,
    })
}

/// Links `object` into `executable` with entry point `l_start`.
pub fn link(toolchain: &Toolchain, object: &Path, executable: &Path) -> Result<(), String> {
    link_with_libraries(toolchain, object, executable, &[])
}

pub fn link_with_libraries(
    toolchain: &Toolchain,
    object: &Path,
    executable: &Path,
    libraries: &[&str],
) -> Result<(), String> {
    link_with_objects(toolchain, object, executable, libraries, &[])
}

pub fn link_with_objects(
    toolchain: &Toolchain,
    object: &Path,
    executable: &Path,
    libraries: &[&str],
    objects: &[&Path],
) -> Result<(), String> {
    let mut command = Command::new(&toolchain.linker);
    command.args([
        "/NOLOGO",
        "/NODEFAULTLIB",
        "/ENTRY:l_start",
        "/SUBSYSTEM:CONSOLE",
    ]);
    command.arg(format!("/OUT:{}", executable.display()));
    command.arg(object).args(objects);
    command.arg("kernel32.lib").args(libraries);
    for dir in &toolchain.libpaths {
        command.arg(format!("/LIBPATH:{}", dir.display()));
    }
    let output = command
        .output()
        .map_err(|e| format!("no se pudo ejecutar {}: {e}", toolchain.linker.display()))?;
    if !output.status.success() {
        return Err(format!(
            "falló el enlazado nativo:\n{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(())
}
