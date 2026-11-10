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

/// Front end + semantic analysis + CFG lowering/verification.
pub fn check(source: &str) -> Result<lir::Program, Diagnostic> {
    let tokens = lexer::lex(source)?;
    let ast = parser::parse(tokens)?;
    let program = sema::check(ast)?;
    lower_to_cfg(&program)?;
    Ok(program)
}

/// Front end + semantic analysis + CFG lowering/verification for a file (including imports).
pub fn check_file(path: &std::path::Path) -> Result<lir::Program, Diagnostic> {
    let ast = modules::load_program(path)?;
    let program = sema::check(ast)?;
    lower_to_cfg(&program)?;
    Ok(program)
}
