use crate::{
    Diagnostic, Span, lexer,
    parser::{self, Program},
};
use std::{
    collections::HashSet,
    fs,
    path::{Component, Path, PathBuf},
};

pub const MAX_MODULE_BYTES: usize = 16 * 1024 * 1024;

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
    let mut loaded_paths = HashSet::new();
    let mut loading_stack = Vec::new();
    let mut files = Vec::new();

    load_module_recursive(
        &canonical_entry,
        Span::default(),
        &mut loaded_modules,
        &mut loaded_paths,
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
    loaded_paths: &mut HashSet<PathBuf>,
    loading_stack: &mut Vec<PathBuf>,
    files: &mut Vec<String>,
    module_root: &Path,
) -> Result<(), Diagnostic> {
    // Cycle detection
    if loading_stack.contains(&canonical_path.to_path_buf()) {
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
    if loaded_paths.contains(canonical_path) {
        return Ok(());
    }

    loading_stack.push(canonical_path.to_path_buf());

    let source = fs::read_to_string(canonical_path).map_err(|e| {
        Diagnostic::new(import_span, format!("{}: {e}", canonical_path.display()))
            .with_file(shown(canonical_path))
            .classify("L0014", "módulos")
    })?;

    if source.len() > MAX_MODULE_BYTES {
        return Err(Diagnostic::new(
            import_span,
            format!(
                "{}: archivo excede límite de 16 MiB",
                canonical_path.display()
            ),
        )
        .with_file(shown(canonical_path))
        .classify("L0014", "módulos"));
    }

    files.push(shown(canonical_path));
    let file_id = u32::try_from(files.len()).map_err(|_| {
        Diagnostic::new(import_span, "demasiados módulos en el programa")
            .with_file(shown(canonical_path))
            .classify("L0014", "módulos")
    })?;
    let tokens =
        lexer::lex_file(&source, file_id).map_err(|d| d.with_file(shown(canonical_path)))?;
    let prog = parser::parse(tokens).map_err(|d| d.with_file(shown(canonical_path)))?;

    // Resolve dependencies relative to current module's directory
    let dir = canonical_path.parent().unwrap_or(Path::new("."));
    for imp in &prog.imports {
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
            loaded_paths,
            loading_stack,
            files,
            module_root,
        )?;
    }

    loading_stack.pop();
    loaded_paths.insert(canonical_path.to_path_buf());
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
