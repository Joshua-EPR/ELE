use crate::{
    Diagnostic, Span, lexer,
    parser::{self, Program},
};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

pub const MAX_MODULE_BYTES: usize = 16 * 1024 * 1024;

/// Loads an entry source file and all of its imported dependencies transitively,
/// detecting cycles and resolving duplicate imports in deterministic topological order.
pub fn load_program(entry_path: &Path) -> Result<Program, Diagnostic> {
    let canonical_entry = fs::canonicalize(entry_path).map_err(|e| {
        Diagnostic::new(Span::default(), format!("{}: {e}", entry_path.display()))
            .with_file(entry_path.display().to_string())
            .classify("L0014", "módulos")
    })?;

    let mut loaded_modules = Vec::new();
    let mut loaded_paths = HashSet::new();
    let mut loading_stack = Vec::new();

    load_module_recursive(
        &canonical_entry,
        Span::default(),
        &mut loaded_modules,
        &mut loaded_paths,
        &mut loading_stack,
    )?;

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

    Ok(merged)
}

fn load_module_recursive(
    canonical_path: &Path,
    import_span: Span,
    loaded_modules: &mut Vec<(PathBuf, Program)>,
    loaded_paths: &mut HashSet<PathBuf>,
    loading_stack: &mut Vec<PathBuf>,
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
        .with_file(canonical_path.display().to_string())
        .classify("L0014", "módulos"));
    }

    // Deduplication check
    if loaded_paths.contains(canonical_path) {
        return Ok(());
    }

    loading_stack.push(canonical_path.to_path_buf());

    let source = fs::read_to_string(canonical_path).map_err(|e| {
        Diagnostic::new(import_span, format!("{}: {e}", canonical_path.display()))
            .with_file(canonical_path.display().to_string())
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
        .with_file(canonical_path.display().to_string())
        .classify("L0014", "módulos"));
    }

    let tokens =
        lexer::lex(&source).map_err(|d| d.with_file(canonical_path.display().to_string()))?;
    let prog =
        parser::parse(tokens).map_err(|d| d.with_file(canonical_path.display().to_string()))?;

    // Resolve dependencies relative to current module's directory
    let dir = canonical_path.parent().unwrap_or(Path::new("."));
    for imp in &prog.imports {
        if imp.path == "std.io.print" {
            continue;
        }

        let rel_parts = imp.path.replace('.', "/") + ".l";
        let candidate = dir.join(&rel_parts);
        if !candidate.exists() {
            return Err(Diagnostic::new(
                imp.span,
                format!(
                    "módulo no encontrado: {} (buscado en '{}')",
                    imp.path,
                    candidate.display()
                ),
            )
            .with_file(canonical_path.display().to_string())
            .classify("L0014", "módulos"));
        }

        let canonical_candidate = fs::canonicalize(&candidate).map_err(|e| {
            Diagnostic::new(imp.span, format!("{}: {e}", candidate.display()))
                .with_file(canonical_path.display().to_string())
                .classify("L0014", "módulos")
        })?;

        load_module_recursive(
            &canonical_candidate,
            imp.span,
            loaded_modules,
            loaded_paths,
            loading_stack,
        )?;
    }

    loading_stack.pop();
    loaded_paths.insert(canonical_path.to_path_buf());
    loaded_modules.push((canonical_path.to_path_buf(), prog));

    Ok(())
}
