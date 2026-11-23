use crate::{
    Diagnostic, Span, lexer,
    parser::{self, Program},
};
use std::{
    collections::HashMap,
    fs,
    io::{self, Read},
    path::{Component, Path, PathBuf},
};

pub const MAX_MODULE_BYTES: usize = 16 * 1024 * 1024;
/// Maximum number of simultaneously active modules in an import chain.
/// This limits recursive stack use, not the total number of modules in a build.
pub const MAX_IMPORT_DEPTH: usize = 128;

/// Loads an entry source file and all of its imported dependencies transitively,
/// detecting cycles and resolving duplicate imports in deterministic topological order.
pub fn load_program(entry_path: &Path) -> Result<Program, Diagnostic> {
    load_program_files(entry_path).map(|(program, _)| program)
}

/// Like [`load_program`], and also returns the path of every file read, in
/// the order of their [`Span::file`] identifiers (identifier k is entry
/// k - 1). [`attribute`] names the file of a later diagnostic.
pub fn load_program_files(entry_path: &Path) -> Result<(Program, Vec<String>), Diagnostic> {
    let canonical_entry = fs::canonicalize(entry_path).map_err(|e| {
        Diagnostic::new(Span::default(), format!("{}: {e}", entry_path.display()))
            .with_file(entry_path.display().to_string())
            .classify("L0014", "módulos")
    })?;
    let working_dir = std::env::current_dir()
        .and_then(fs::canonicalize)
        .map_err(|e| {
            Diagnostic::new(Span::default(), format!("directorio de trabajo: {e}"))
                .classify("L0014", "módulos")
        })?;
    let module_root = if canonical_entry.starts_with(&working_dir) {
        working_dir
    } else {
        canonical_entry
            .parent()
            .unwrap_or(Path::new("."))
            .to_path_buf()
    };

    let mut loaded_modules = Vec::new();
    // Canonical module path -> stable Span::file ID (entry source is 1).
    // One index replaces both the visited set and O(n) path scans per import.
    let mut file_ids = HashMap::new();
    let mut loading_stack = Vec::new();
    let mut files = Vec::new();

    load_module_recursive(
        &canonical_entry,
        Span::default(),
        &mut loaded_modules,
        &mut file_ids,
        &mut loading_stack,
        &mut files,
        &module_root,
    )
    .map_err(|mut d| {
        // Errors of the entry file itself name it as the caller did.
        if d.file.as_deref() == Some(shown(&canonical_entry).as_str()) {
            d.file = Some(entry_path.display().to_string());
        }
        d
    })?;

    // Merge in topological order (dependencies appear first, entry file appears last)
    let mut merged = Program {
        imports: Vec::new(),
        functions: Vec::new(),
        constants: Vec::new(),
        structs: Vec::new(),
        enums: Vec::new(),
        traits: Vec::new(),
        impls: Vec::new(),
    };

    for (_, prog) in loaded_modules {
        merged.imports.extend(prog.imports);
        merged.functions.extend(prog.functions);
        merged.constants.extend(prog.constants);
        merged.structs.extend(prog.structs);
        merged.enums.extend(prog.enums);
        merged.traits.extend(prog.traits);
        merged.impls.extend(prog.impls);
    }

    // The entry file is read first; name it as the caller did.
    if let Some(entry) = files.first_mut() {
        *entry = entry_path.display().to_string();
    }
    Ok((merged, files))
}

/// Names the file of a diagnostic produced after loading (semantic analysis,
/// lowering, verification) from the file identifier of its span. Diagnostics
/// that already name a file, and spans of file 0, are returned unchanged.
pub fn attribute(diagnostic: Diagnostic, files: &[String]) -> Diagnostic {
    if diagnostic.file.is_some() || diagnostic.span.file == 0 {
        return diagnostic;
    }
    match files.get(diagnostic.span.file as usize - 1) {
        Some(path) => {
            let path = path.clone();
            diagnostic.with_file(path)
        }
        None => diagnostic,
    }
}

fn load_module_recursive(
    canonical_path: &Path,
    import_span: Span,
    loaded_modules: &mut Vec<(PathBuf, Program)>,
    file_ids: &mut HashMap<PathBuf, u32>,
    loading_stack: &mut Vec<PathBuf>,
    files: &mut Vec<String>,
    module_root: &Path,
) -> Result<(), Diagnostic> {
    // Cycle detection
    if loading_stack
        .iter()
        .any(|path| path.as_path() == canonical_path)
    {
        let mut chain: Vec<String> = loading_stack
            .iter()
            .map(|p| {
                p.file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string()
            })
            .collect();
        chain.push(
            canonical_path
                .file_stem()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string(),
        );
        return Err(Diagnostic::new(
            import_span,
            format!("ciclo de dependencias detectado: {}", chain.join(" -> ")),
        )
        .with_file(shown(canonical_path))
        .classify("L0014", "módulos"));
    }

    // Deduplication check
    if file_ids.contains_key(canonical_path) {
        return Ok(());
    }

    // Every new import adds a stack frame. Reject deep acyclic chains before
    // recursing further; a wide graph with many modules remains supported.
    // Prefer the importing source as the diagnostic file because import_span
    // refers to the 'take' declaration there, not the target module.
    if loading_stack.len() >= MAX_IMPORT_DEPTH {
        let importer = loading_stack
            .last()
            .map_or(canonical_path, PathBuf::as_path);
        return Err(Diagnostic::new(
            import_span,
            format!("profundidad de imports excede el límite de {MAX_IMPORT_DEPTH} módulos"),
        )
        .with_file(shown(importer))
        .classify("L0014", "módulos"));
    }

    loading_stack.push(canonical_path.to_path_buf());

    let io_error = |e: io::Error| {
        Diagnostic::new(import_span, format!("{}: {e}", canonical_path.display()))
            .with_file(shown(canonical_path))
            .classify("L0014", "módulos")
    };
    let oversized = || {
        Diagnostic::new(
            import_span,
            format!(
                "{}: archivo excede límite de 16 MiB",
                canonical_path.display()
            ),
        )
        .with_file(shown(canonical_path))
        .classify("L0014", "módulos")
    };

    // Check the metadata first to avoid loading a known oversized file.
    // Still bound the actual read: metadata is not reliable for every file
    // type and the file can grow between this check and the read.
    let file = fs::File::open(canonical_path).map_err(io_error)?;
    if file.metadata().map_err(io_error)?.len() > MAX_MODULE_BYTES as u64 {
        return Err(oversized());
    }
    let mut bytes = Vec::new();
    file.take(MAX_MODULE_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    if bytes.len() > MAX_MODULE_BYTES {
        return Err(oversized());
    }
    // Validate UTF-8 only after checking the byte limit; a truncated
    // multibyte sequence in an oversized file must not mask the size error.
    let source = String::from_utf8(bytes)
        .map_err(|e| io_error(io::Error::new(io::ErrorKind::InvalidData, e)))?;

    files.push(shown(canonical_path));
    let file_id = u32::try_from(files.len()).map_err(|_| {
        Diagnostic::new(import_span, "demasiados módulos en el programa")
            .with_file(shown(canonical_path))
            .classify("L0014", "módulos")
    })?;
    let tokens =
        lexer::lex_file(&source, file_id).map_err(|d| d.with_file(shown(canonical_path)))?;
    let mut prog = parser::parse(tokens).map_err(|d| d.with_file(shown(canonical_path)))?;
    // Register before walking imports. Cycles are still checked first via
    // loading_stack, while diamond dependencies reuse the original file ID.
    file_ids.insert(canonical_path.to_path_buf(), file_id);

    // Resolve dependencies relative to current module's directory
    let dir = canonical_path.parent().unwrap_or(Path::new("."));
    for imp in &mut prog.imports {
        if imp.path == "std.io.print" {
            continue;
        }

        let rel_path = if imp.is_file_path {
            let mut path = PathBuf::from(&imp.path);
            if path.extension().is_none() {
                path.set_extension("l");
            }
            path
        } else {
            PathBuf::from(imp.path.replace('.', "/") + ".l")
        };
        if rel_path.is_absolute()
            || rel_path
                .components()
                .any(|component| matches!(component, Component::Prefix(_) | Component::RootDir))
        {
            return Err(import_error(
                imp.span,
                canonical_path,
                format!("la ruta de módulo debe ser relativa: {}", imp.path),
            ));
        }
        let candidate = dir.join(&rel_path);
        if !is_within_root(&candidate, module_root) {
            return Err(import_error(
                imp.span,
                canonical_path,
                format!("módulo fuera del árbol del proyecto: {}", imp.path),
            ));
        }
        if !candidate.exists() {
            return Err(import_error(
                imp.span,
                canonical_path,
                format!(
                    "módulo no encontrado: {} (buscado en '{}')",
                    imp.path,
                    candidate.display()
                ),
            ));
        }

        let canonical_candidate = fs::canonicalize(&candidate).map_err(|e| {
            import_error(
                imp.span,
                canonical_path,
                format!("{}: {e}", candidate.display()),
            )
        })?;
        if !canonical_candidate.starts_with(module_root) {
            return Err(import_error(
                imp.span,
                canonical_path,
                format!("módulo fuera del árbol del proyecto: {}", imp.path),
            ));
        }

        load_module_recursive(
            &canonical_candidate,
            imp.span,
            loaded_modules,
            file_ids,
            loading_stack,
            files,
            module_root,
        )?;
        // Keep the canonical identity of the directly imported module.
        // The merged AST otherwise loses the link between import and file ID.
        imp.target_file = Some(*file_ids.get(&canonical_candidate).ok_or_else(|| {
            Diagnostic::new(imp.span, "módulo cargado sin identificador de archivo")
                .with_file(shown(canonical_path))
                .classify("L0014", "módulos")
        })?);
    }

    loading_stack.pop();
    // file_ids already tracks successfully parsed modules.
    loaded_modules.push((canonical_path.to_path_buf(), prog));

    Ok(())
}

fn import_error(span: Span, file: &Path, message: String) -> Diagnostic {
    Diagnostic::new(span, message)
        .with_file(shown(file))
        .classify("L0014", "módulos")
}

fn is_within_root(candidate: &Path, root: &Path) -> bool {
    let Ok(relative) = candidate.strip_prefix(root) else {
        return false;
    };
    let mut depth = 0usize;
    for component in relative.components() {
        match component {
            Component::Normal(_) => depth += 1,
            Component::ParentDir if depth > 0 => depth -= 1,
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => return false,
        }
    }
    true
}

/// How a module path appears in diagnostics: the canonical path without the
/// Windows verbatim prefix (`\\?\C:\...` is shown as `C:\...`).
fn shown(path: &Path) -> String {
    let text = path.display().to_string();
    match text.strip_prefix(r"\\?\") {
        Some(rest) if rest.as_bytes().get(1) == Some(&b':') => rest.to_string(),
        _ => text,
    }
}
