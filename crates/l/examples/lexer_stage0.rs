//! Stage 0 comparison for the ASCII fixtures in bench/lexer-file.ps1.
use project_l::lexer::{Kind, lex};
use std::{
    fs::File,
    io::{self, Read, Write},
    time::Instant,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args_os().nth(1).ok_or("missing input path")?;
    let start = Instant::now();
    let mut file = File::open(path)?;
    let open = start.elapsed();
    let start = Instant::now();
    let mut bytes = Vec::new();
    (&mut file)
        .take(16 * 1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    let read = start.elapsed();
    drop(file);
    if bytes.len() > 16 * 1024 * 1024 {
        return Err("fixture too large".into());
    }
    let start = Instant::now();
    let source = std::str::from_utf8(&bytes)?;
    let utf8 = start.elapsed();
    let start = Instant::now();
    let tokens = lex(source).map_err(|d| d.message)?;
    let scan = start.elapsed();
    let start = Instant::now();
    let line_offsets: Vec<_> = std::iter::once(0)
        .chain(source.match_indices('\n').map(|(i, _)| i + 1))
        .collect();
    let mut stdout = io::stdout().lock();
    for token in tokens {
        let offset = line_offsets[token.span.line - 1] + token.span.column - 1;
        let (name, len) = match token.kind {
            Kind::Word(word) => ("word", word.len()),
            Kind::Int(int) => ("int", int.to_string().len()),
            Kind::Sym(sym) => ("symbol", sym.len()),
            Kind::Newline => ("newline", 1),
            Kind::Eof => ("eof", 0),
            _ => return Err("token outside benchmark fixture subset".into()),
        };
        writeln!(stdout, "{name}:{offset}:{}", offset + len)?;
    }
    stdout.flush()?;
    let emit = start.elapsed();
    eprintln!(
        "open_ns={} read_ns={} utf8_ns={} scan_ns={} emit_ns={}",
        open.as_nanos(),
        read.as_nanos(),
        utf8.as_nanos(),
        scan.as_nanos(),
        emit.as_nanos()
    );
    Ok(())
}
