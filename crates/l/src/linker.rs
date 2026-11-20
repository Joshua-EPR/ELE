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

/// Prefer stable Visual Studio installations, but include Insiders if none
/// provides the native x64 linker. Without -prerelease, vswhere hides previews.
fn vswhere_arguments(include_prerelease: bool) -> Vec<&'static str> {
    let mut args = vec![
        "-latest",
        "-products",
        "*",
        "-requires",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "-property",
        "installationPath",
    ];
    if include_prerelease {
        args.insert(1, "-prerelease");
    }
    args
}

fn find_link_exe() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("L_LINKER") {
        return Ok(path.into());
    }
    let program_files = std::env::var_os("ProgramFiles(x86)")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(r"C:\Program Files (x86)"));
    let vswhere = program_files.join(r"Microsoft Visual Studio\Installer\vswhere.exe");

    let mut installation_without_linker = None;
    for include_prerelease in [false, true] {
        let output = Command::new(&vswhere)
            .args(vswhere_arguments(include_prerelease))
            .output()
            .map_err(|e| format!("no se encontró vswhere ({}): {e}", vswhere.display()))?;
        if !output.status.success() {
            return Err(format!(
                "vswhere falló ({}): {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        let install = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if install.is_empty() {
            continue;
        }
        let tools = PathBuf::from(install).join(r"VC\Tools\MSVC");
        if let Some(version) = newest(&tools, |p| p.join(r"bin\Hostx64\x64\link.exe").exists()) {
            return Ok(version.join(r"bin\Hostx64\x64\link.exe"));
        }
        installation_without_linker = Some(tools);
    }

    if let Some(tools) = installation_without_linker {
        return Err(format!(
            "no hay link.exe x64 en {}; verifique la instalación MSVC o defina L_LINKER",
            tools.display()
        ));
    }
    Err(
        "no se encontraron herramientas C++ de Visual Studio estables ni Insiders (link.exe); instale Build Tools o defina L_LINKER".into(),
    )
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
    command.arg("kernel32.lib");
    // The Stage 0 Win64 platform object uses BCryptGenRandom. The object
    // is embedded at build time as l_platform.obj and written to disk as
    // <module>.platform.obj before linking (see main.rs). It is currently
    // the only auxiliary object; add bcrypt only for this bootstrap path.
    if !objects.is_empty() {
        command.arg("bcrypt.lib");
    }
    command.args(libraries);
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

#[cfg(test)]
mod tests {
    use super::vswhere_arguments;

    #[test]
    fn vswhere_prefers_stable_but_can_discover_insiders() {
        let stable = vswhere_arguments(false);
        let with_insiders = vswhere_arguments(true);
        assert_eq!(stable[0], "-latest");
        assert!(!stable.contains(&"-prerelease"));
        assert_eq!(&with_insiders[..2], &["-latest", "-prerelease"]);
        assert_eq!(with_insiders.len(), stable.len() + 1);
        for args in [&stable, &with_insiders] {
            assert!(args.contains(&"Microsoft.VisualStudio.Component.VC.Tools.x86.x64"));
            assert!(args.contains(&"installationPath"));
        }
    }
}
