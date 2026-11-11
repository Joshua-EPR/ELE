pub mod async_desugar;
mod async_state;
pub mod backend;
pub mod cfg;
pub mod consteval;
pub mod drops;
pub mod effects;
pub mod exhaustive;
pub mod layout;
pub mod lexer;
pub mod linker;
pub mod lir;
pub mod lir_protocol;
mod loans;
pub use loans::{EscapeProjection, EscapeSummary, ReturnOrigin, escape_summaries};
pub mod modules;
pub mod native;
pub mod ownership;
pub mod parser;
pub mod sema;

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Span {
    pub line: usize,
    pub column: usize,
    /// Source file of the span: 0 for a lone source (or the prelude), k > 0
    /// for the k-th file read by [`modules::load_program_files`].
    pub file: u32,
}

impl Span {
    /// A position in the lone source (file 0).
    pub const fn at(line: usize, column: usize) -> Self {
        Self {
            line,
            column,
            file: 0,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Diagnostic {
    pub span: Span,
    pub message: String,
    pub code: &'static str,
    pub category: &'static str,
    pub file: Option<String>,
}

impl Diagnostic {
    pub fn new(span: Span, message: impl Into<String>) -> Self {
        Self {
            span,
            message: message.into(),
            code: "L0001",
            category: "semántica",
            file: None,
        }
    }
    pub fn classify(mut self, code: &'static str, category: &'static str) -> Self {
        self.code = code;
        self.category = category;
        self
    }
    pub fn with_file(mut self, file: impl Into<String>) -> Self {
        self.file = Some(file.into());
        self
    }
}

/// Lowers checked structured LIR to block-based LIR and verifies it. Every
/// program goes through this step, whatever backend builds it.
pub fn lower_to_cfg(program: &lir::Program) -> Result<cfg::Module, Diagnostic> {
    let mut module = cfg::lower(program);
    let ownership = drops::Ownership::new(
        &module.structs,
        &module.enums,
        &module.arrays,
        &module.lists,
    );
    drops::elaborate(&mut module, &ownership);
    cfg::verify(&module).map_err(cfg::VerifyError::into_diagnostic)?;
    loans::check(&module, &ownership)?;
    Ok(module)
}

/// Stack of the thread that runs the compiler's recursive passes. Their
/// depth is bounded by the nesting limits (128 levels in the parser and in
/// semantic analysis), but frames are large in unoptimized builds: a chain
/// of 30 additions already exceeded the 1 MiB main-thread stack of Windows.
/// The stack is reserved address space, committed only as it is used.
pub const COMPILER_STACK_BYTES: usize = 256 << 20;

/// Runs `f` on a thread with [`COMPILER_STACK_BYTES`] of stack and returns
/// its result; a panic inside `f` propagates to the caller.
pub fn with_compiler_stack<T: Send>(f: impl FnOnce() -> T + Send) -> T {
    std::thread::scope(|scope| {
        let worker = std::thread::Builder::new()
            .name("ele-compiler".into())
            .stack_size(COMPILER_STACK_BYTES)
            .spawn_scoped(scope, f)
            .expect("no se pudo crear el hilo del compilador");
        worker
            .join()
            .unwrap_or_else(|panic| std::panic::resume_unwind(panic))
    })
}

/// Front end + semantic analysis + CFG lowering/verification.
pub fn check(source: &str) -> Result<lir::Program, Diagnostic> {
    with_compiler_stack(|| {
        let tokens = lexer::lex(source)?;
        let ast = parser::parse(tokens)?;
        let program = sema::check(ast)?;
        lower_to_cfg(&program)?;
        Ok(program)
    })
}

/// Front end + semantic analysis + CFG lowering/verification for a file (including imports).
pub fn check_file(path: &std::path::Path) -> Result<lir::Program, Diagnostic> {
    with_compiler_stack(|| {
        let (ast, files) = modules::load_program_files(path)?;
        let attribute = |d| modules::attribute(d, &files);
        let program = sema::check(ast).map_err(attribute)?;
        lower_to_cfg(&program).map_err(attribute)?;
        Ok(program)
    })
}
