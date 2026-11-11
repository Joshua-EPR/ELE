use project_l::{backend, linker, native};
use std::{
    path::{Path, PathBuf},
    process::{Command, ExitCode},
};

const HELP: &str = "ELE 0.1.0
l check|build|run <archivo.l> [--backend rustc|cranelift] [--emit-ast|--emit-ir|--emit-cfg]
l build-lir|run-lir <archivo.lir> [--trace-alloc]
  Backend provisional: compila con Cranelift la LIR que emite Stage 1
  (sema-l archivo.l --emit-lir). No ejecuta el frontend Rust.
Backends:
  rustc      (predeterminado, provisional) transpila la LIR a Rust y llama a rustc.
  cranelift  genera código máquina con Cranelift y enlaza con el enlazador del sistema;
             no usa rustc. Subconjunto: Int, Bool, Text, control de flujo, match sobre
             Int/Bool/Text, funciones, interpolación con liberación determinista y print.
             Lo demás se rechaza con un error claro.
Instrumentación (solo cranelift, para pruebas):
  --trace-alloc          cuenta reservas/liberaciones, valida cada liberación y el heap
  --alloc-fail-after N   hace fallar la reserva N+1 (prueba de memoria insuficiente)";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Backend {
    Rustc,
    Cranelift,
}

fn run() -> Result<u8, String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str).unwrap_or("--help");
    if command == "--help" {
        println!("{HELP}");
        return Ok(0);
    }
    if command == "--version" {
        println!("l 0.1.0");
        return Ok(0);
    }
    if command == "build-lir" || command == "run-lir" {
        return run_lir(&args, command == "run-lir");
    }
    if !["check", "build", "run"].contains(&command) {
        return Err(format!("comando no implementado: {command}"));
    }
    let file = args.get(1).ok_or("falta ruta del archivo .l")?;
    let mut backend = Backend::Rustc;
    let mut emit = Vec::new();
    let mut options = native::Options::default();
    let mut rest = args[2..].iter();
    while let Some(flag) = rest.next() {
        match flag.as_str() {
            "--emit-ast" | "--emit-ir" | "--emit-cfg" => emit.push(flag.as_str()),
            "--trace-alloc" => options.trace_alloc = true,
            "--alloc-fail-after" => {
                let n = rest
                    .next()
                    .and_then(|n| n.parse().ok())
                    .ok_or("--alloc-fail-after requiere un número")?;
                options.fail_alloc_after = Some(n);
            }
            "--backend" => {
                backend = match rest.next().map(String::as_str) {
                    Some("rustc") => Backend::Rustc,
                    Some("cranelift") => Backend::Cranelift,
                    Some(other) => return Err(format!("backend desconocido: {other}")),
                    None => return Err("falta el nombre del backend tras --backend".into()),
                }
            }
            _ => return Err(format!("opción desconocida: {flag}")),
        }
    }
    // A diagnostic names the module its span comes from; the entry file is
    // only the fallback for spans without one (the prelude).
    let report_in = |files: &[String], e: project_l::Diagnostic| {
        let e = project_l::modules::attribute(e, files);
        let f = e.file.as_deref().unwrap_or(file);
        format!(
            "{f}:{}:{}: {} [{}]: {}",
            e.span.line, e.span.column, e.code, e.category, e.message
        )
    };
    let (ast, files) =
        project_l::modules::load_program_files(Path::new(file)).map_err(|e| report_in(&[], e))?;
    let report = |e: project_l::Diagnostic| report_in(&files, e);
    if emit.contains(&"--emit-ast") {
        println!("{ast:#?}");
    }
    let ir = project_l::sema::check(ast).map_err(report)?;
    if emit.contains(&"--emit-ir") {
        println!("{ir:#?}");
    }
    let cfg = project_l::lower_to_cfg(&ir).map_err(report)?;
    if emit.contains(&"--emit-cfg") {
        println!("{cfg:#?}");
    }
    if backend != Backend::Cranelift && (options.trace_alloc || options.fail_alloc_after.is_some())
    {
        return Err(
            "--trace-alloc y --alloc-fail-after solo se aplican a --backend cranelift".into(),
        );
    }
    if backend == Backend::Cranelift {
        // Reject unsupported programs at check time too, before any build.
        native::check_supported(&cfg).map_err(report)?;
    }
    if command == "check" {
        println!("OK: {file}");
        return Ok(0);
    }
    let stem = Path::new(file)
        .file_stem()
        .ok_or("nombre de archivo inválido")?;
    let executable = match backend {
        Backend::Rustc => build_rustc(&ir, stem)?,
        Backend::Cranelift => build_cranelift(&cfg, stem, options).map_err(|e| match e {
            BuildError::Diagnostic(d) => report(d),
            BuildError::Other(s) => s,
        })?,
    };
    if command == "build" {
        println!("Build: {}", executable.display());
        return Ok(0);
    }
    let executable = executable.canonicalize().map_err(|e| e.to_string())?;
    let status = Command::new(executable)
        .status()
        .map_err(|e| format!("falló ejecución: {e}"))?;
    Ok(if status.success() {
        0
    } else {
        status
            .code()
            .and_then(|c| u8::try_from(c).ok())
            .filter(|c| *c != 0)
            .unwrap_or(1)
    })
}

/// Provisional backend: ELE LIR (written by Stage 1) -> Cranelift.
fn run_lir(args: &[String], run: bool) -> Result<u8, String> {
    let file = args.get(1).ok_or("falta ruta del archivo .lir")?;
    let mut options = native::Options::default();
    let mut rest = args[2..].iter();
    while let Some(flag) = rest.next() {
        match flag.as_str() {
            "--trace-alloc" => options.trace_alloc = true,
            "--alloc-fail-after" => {
                let n = rest
                    .next()
                    .and_then(|n| n.parse().ok())
                    .ok_or("--alloc-fail-after requiere un número")?;
                options.fail_alloc_after = Some(n);
            }
            _ => return Err(format!("opción desconocida: {flag}")),
        }
    }
    let size = std::fs::metadata(file)
        .map_err(|e| format!("{file}: {e}"))?
        .len();
    if size > project_l::lir_protocol::MAX_INPUT as u64 {
        return Err(format!("{file}: el módulo LIR excede el tamaño máximo"));
    }
    let bytes = std::fs::read(file).map_err(|e| format!("{file}: {e}"))?;
    let text = String::from_utf8(bytes).map_err(|_| format!("{file}: UTF-8 inválido"))?;
    let report = |e: project_l::Diagnostic| {
        format!(
            "{file}:{}:{}: {} [{}]: {}",
            e.span.line, e.span.column, e.code, e.category, e.message
        )
    };
    let cfg = project_l::lir_protocol::parse(&text).map_err(|e| report(e.into_diagnostic()))?;
    project_l::lir_protocol::validate(&cfg).map_err(report)?;
    native::check_supported(&cfg).map_err(report)?;
    let stem = Path::new(file)
        .file_stem()
        .ok_or("nombre de archivo inválido")?;
    let executable = build_cranelift(&cfg, stem, options).map_err(|e| match e {
        BuildError::Diagnostic(d) => report(d),
        BuildError::Other(s) => s,
    })?;
    if !run {
        println!("Build: {}", executable.display());
        return Ok(0);
    }
    let executable = executable.canonicalize().map_err(|e| e.to_string())?;
    let status = Command::new(executable)
        .status()
        .map_err(|e| format!("falló ejecución: {e}"))?;
    Ok(if status.success() {
        0
    } else {
        status
            .code()
            .and_then(|c| u8::try_from(c).ok())
            .filter(|c| *c != 0)
            .unwrap_or(1)
    })
}

enum BuildError {
    Diagnostic(project_l::Diagnostic),
    Other(String),
}

/// Native backend: object file from Cranelift, linked by the system linker.
fn build_cranelift(
    cfg: &project_l::cfg::Module,
    stem: &std::ffi::OsStr,
    options: native::Options,
) -> Result<PathBuf, BuildError> {
    let object = native::compile(cfg, options).map_err(BuildError::Diagnostic)?;
    let dir = PathBuf::from("target")
        .join("cranelift")
        .join(target_lexicon::Triple::host().to_string());
    std::fs::create_dir_all(&dir).map_err(|e| BuildError::Other(e.to_string()))?;
    let object_path = dir.join(stem).with_extension("obj");
    let executable = dir
        .join(stem)
        .with_extension(std::env::consts::EXE_EXTENSION);
    std::fs::write(&object_path, object).map_err(|e| BuildError::Other(e.to_string()))?;
    let toolchain = linker::find().map_err(BuildError::Other)?;
    let mut libraries = Vec::new();
    if native::uses_timers(cfg) {
        libraries.push("mincore.lib");
    }
    let platform_path = object_path.with_extension("platform.obj");
    let mut objects = Vec::new();
    if native::uses_platform(cfg) {
        std::fs::write(&platform_path, native::platform_object())
            .map_err(|e| BuildError::Other(e.to_string()))?;
        objects.push(platform_path.as_path());
        libraries.push("shell32.lib");
    }
    linker::link_with_objects(&toolchain, &object_path, &executable, &libraries, &objects)
        .map_err(BuildError::Other)?;
    Ok(executable)
}

/// Provisional backend: LIR → Rust source → rustc.
fn build_rustc(ir: &project_l::lir::Program, stem: &std::ffi::OsStr) -> Result<PathBuf, String> {
    let version = Command::new("rustc")
        .arg("-vV")
        .output()
        .map_err(|e| format!("no se pudo ejecutar rustc: {e}"))?;
    if !version.status.success() {
        return Err("rustc -vV falló".into());
    }
    let version = String::from_utf8_lossy(&version.stdout);
    let host = version
        .lines()
        .find_map(|l| l.strip_prefix("host: "))
        .ok_or("rustc no informó target host")?;
    let dir = PathBuf::from("target").join(host).join("debug");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let generated = dir.join(stem).with_extension("l.rs");
    let executable = dir
        .join(stem)
        .with_extension(std::env::consts::EXE_EXTENSION);
    std::fs::write(&generated, backend::emit(ir)).map_err(|e| e.to_string())?;
    let status = Command::new("rustc")
        .arg(&generated)
        .args([
            "--crate-name",
            "l_program",
            "--edition=2024",
            "-C",
            "overflow-checks=yes",
            "-C",
            "panic=abort",
            "-C",
            "opt-level=0",
            "-o",
        ])
        .arg(&executable)
        .status()
        .map_err(|e| format!("rustc no disponible: {e}"))?;
    if !status.success() {
        return Err("falló compilación/enlace nativo; no se ejecutó ningún binario".into());
    }
    Ok(executable)
}

fn main() -> ExitCode {
    match project_l::with_compiler_stack(run) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("{e}");
            ExitCode::FAILURE
        }
    }
}
