//! Automatic self-coverage of `compiler-l/src` by Stage 1.
//!
//! Every `.l` source of the ELE-written compiler is fed, as an independent
//! entry, through the four Stage 1 phases:
//!
//! 1. parser: `main_parser <file>`
//! 2. semantics and ownership: `main_sema <file> --check-ownership`
//! 3. LIR and its verifier: `main_sema <file> --emit-lir`
//! 4. ELE native backend: `native_cfg_demo <lir> <elf>` must exit 0 and
//!    write an ELF64 image.
//!
//! A phase only runs when the previous one passed. The highest phase reached
//! by each file is compared with the versioned baseline
//! `docs/self_coverage_baseline.tsv`:
//!
//! * a file that reaches a LOWER phase than its baseline is a regression;
//! * a file that reaches a HIGHER phase than its baseline (or a file added
//!   or removed) must be recorded by regenerating the baseline, so progress
//!   made elsewhere is never lost silently.
//!
//! Regenerate with `ELE_UPDATE_SELF_COVERAGE=1 cargo test -p project-l
//! --test self_coverage`. The full matrix, with the first diagnostic of the
//! failing phase, is written to `target/stage1-tests/self-coverage/matrix.md`
//! using paths relative to the repository root.
mod stage1_support;

use std::{
    collections::BTreeMap,
    fmt::Write as _,
    fs::{self, File},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};

const BASELINE: &str = "docs/self_coverage_baseline.tsv";
const UPDATE_VAR: &str = "ELE_UPDATE_SELF_COVERAGE";
const RUNS: &str = "target/stage1-tests/self-coverage/runs";
const PHASE_TIMEOUT: Duration = Duration::from_secs(180);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
enum Phase {
    None,
    Parser,
    Sema,
    Lir,
    Backend,
}

impl Phase {
    const ALL: [Phase; 5] = [
        Phase::None,
        Phase::Parser,
        Phase::Sema,
        Phase::Lir,
        Phase::Backend,
    ];

    fn key(self) -> &'static str {
        match self {
            Phase::None => "ninguna",
            Phase::Parser => "parser",
            Phase::Sema => "semantica",
            Phase::Lir => "lir",
            Phase::Backend => "backend",
        }
    }

    fn parse(text: &str) -> Option<Phase> {
        Phase::ALL.into_iter().find(|phase| phase.key() == text)
    }
}

/// Outcome of one phase for one file.
enum Step {
    Passed,
    Failed(String),
    NotRun,
}

struct Row {
    file: String,
    steps: [Step; 4],
}

impl Row {
    fn reached(&self) -> Phase {
        let passed = self
            .steps
            .iter()
            .take_while(|step| matches!(step, Step::Passed))
            .count();
        Phase::ALL[passed]
    }
}

fn root() -> PathBuf {
    // Not canonicalized: on Windows that yields a verbatim (`\\?\`) path.
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Repository-relative, `/`-separated rendering of diagnostics so that the
/// matrix is identical between checkouts and hosts.
fn normalize(text: &str, root: &Path) -> String {
    let mut text = text.replace('\\', "/");
    let full = root.to_string_lossy().replace('\\', "/");
    let short = full.trim_start_matches("//?/").to_string();
    for prefix in [full, short] {
        text = text.replace(&format!("{prefix}/"), "");
    }
    text
}

fn first_line(bytes: &[u8], code: Option<i32>, root: &Path) -> String {
    let text = String::from_utf8_lossy(bytes);
    let line = text
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| normalize(line, root))
        .unwrap_or_else(|| match code {
            Some(code) => format!("salida {code} sin diagnóstico"),
            None => "terminado por una señal, sin diagnóstico".to_string(),
        });
    let mut short: String = line.chars().take(220).collect();
    if short.len() < line.len() {
        short.push('…');
    }
    short.replace('|', "\\|").replace('`', "'")
}

/// Runs `exe args` from the repository root with stdout redirected to
/// `stdout_path`; returns the step outcome. Output goes to files, so large
/// LIR dumps cannot dead-lock a pipe, and a hung phase is killed.
fn run(exe: &Path, args: &[&str], stdout_path: &Path, root: &Path) -> Step {
    let stderr_path = stdout_path.with_extension("stderr");
    let mut child = Command::new(exe)
        .args(args)
        .current_dir(root)
        .stdin(Stdio::null())
        .stdout(File::create(stdout_path).unwrap())
        .stderr(File::create(&stderr_path).unwrap())
        .spawn()
        .unwrap_or_else(|err| panic!("cannot start {}: {err}", exe.display()));
    let start = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if start.elapsed() > PHASE_TIMEOUT {
            let _ = child.kill();
            let _ = child.wait();
            return Step::Failed(format!("tiempo agotado tras {} s", PHASE_TIMEOUT.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    if status.success() {
        Step::Passed
    } else {
        let stderr = fs::read(&stderr_path).unwrap_or_default();
        Step::Failed(first_line(&stderr, status.code(), root))
    }
}

struct Tools {
    parser: PathBuf,
    sema: PathBuf,
    native: PathBuf,
}

fn measure(file: &str, tools: &Tools, work: &Path, root: &Path) -> Row {
    let source = format!("compiler-l/src/{file}");
    let stem = work.join(file.replace('/', "__"));
    let scratch = stem.with_extension("out");
    let lir = stem.with_extension("lir");
    let elf = stem.with_extension("elf");
    let _ = fs::remove_file(&elf);
    let mut steps = [Step::NotRun, Step::NotRun, Step::NotRun, Step::NotRun];
    steps[0] = run(&tools.parser, &[&source], &scratch, root);
    if matches!(steps[0], Step::Passed) {
        steps[1] = run(&tools.sema, &[&source, "--check-ownership"], &scratch, root);
    }
    if matches!(steps[1], Step::Passed) {
        steps[2] = run(&tools.sema, &[&source, "--emit-lir"], &lir, root);
    }
    if matches!(steps[2], Step::Passed) {
        // Relative to the repository root (the working directory).
        let lir_arg = format!("{RUNS}/{}", file_name(&lir));
        let elf_arg = format!("{RUNS}/{}", file_name(&elf));
        steps[3] = match run(&tools.native, &[&lir_arg, &elf_arg], &scratch, root) {
            Step::Passed => match fs::read(&elf) {
                Ok(image) if image.starts_with(b"\x7fELF\x02\x01\x01") => Step::Passed,
                Ok(_) => Step::Failed("la salida no es una imagen ELF64 little-endian".into()),
                Err(_) => Step::Failed("salida 0 sin imagen ELF64 escrita".into()),
            },
            other => other,
        };
    }
    Row {
        file: file.to_string(),
        steps,
    }
}

fn file_name(path: &Path) -> String {
    path.file_name().unwrap().to_string_lossy().into_owned()
}

fn sources(dir: &Path, prefix: &str, out: &mut Vec<String>) {
    for entry in fs::read_dir(dir).unwrap() {
        let entry = entry.unwrap();
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        if path.is_dir() {
            sources(&path, &format!("{prefix}{name}/"), out);
        } else if name.ends_with(".l") {
            out.push(format!("{prefix}{name}"));
        }
    }
}

fn host() -> String {
    // Mirrors stage1_support::build: Cranelift on Windows, rustc elsewhere.
    let backend = if cfg!(windows) { "cranelift" } else { "rustc" };
    format!(
        "{}-{} (Stage 1 construido con el backend {backend} de Stage 0)",
        std::env::consts::OS,
        std::env::consts::ARCH
    )
}

fn render_matrix(rows: &[Row], counts: &[usize; 4]) -> String {
    let total = rows.len();
    let mut md = String::new();
    md.push_str("# Autocobertura de `compiler-l/src` (generada)\n\n");
    md.push_str("Generada por `crates/l/tests/self_coverage.rs`; no editar a mano.\n\n");
    let _ = writeln!(md, "Host: {}.\n", host());
    let _ = writeln!(
        md,
        "Resultado: {}/{total} parser, {}/{total} semántica y ownership, \
         {}/{total} LIR verificada, {}/{total} backend ELE (ELF64).",
        counts[0], counts[1], counts[2], counts[3]
    );
    md.push_str(
        "Son recuentos de archivos invocados como entradas independientes, \
         no porcentajes de funcionalidad.\n\n",
    );
    md.push_str("| Fuente | Fase máxima | Parser | Semántica y ownership | LIR y verificador | Backend ELE / ELF64 |\n");
    md.push_str("| --- | --- | --- | --- | --- | --- |\n");
    for row in rows {
        let cells: Vec<String> = row
            .steps
            .iter()
            .map(|step| match step {
                Step::Passed => "Sí".to_string(),
                Step::Failed(why) => format!("No ({why})"),
                Step::NotRun => "No ejecutado".to_string(),
            })
            .collect();
        let _ = writeln!(
            md,
            "| `{}` | {} | {} |",
            row.file,
            row.reached().key(),
            cells.join(" | ")
        );
    }
    md
}

fn render_baseline(rows: &[Row]) -> String {
    let mut tsv = String::new();
    tsv.push_str("# Línea base de autocobertura de compiler-l/src por Stage 1.\n");
    tsv.push_str("# Generada por crates/l/tests/self_coverage.rs; regenerar con\n");
    tsv.push_str("#   ELE_UPDATE_SELF_COVERAGE=1 cargo test -p project-l --test self_coverage\n");
    tsv.push_str("# Fases en orden: ninguna < parser < semantica < lir < backend.\n");
    tsv.push_str("archivo\tfase_maxima\n");
    for row in rows {
        let _ = writeln!(tsv, "{}\t{}", row.file, row.reached().key());
    }
    tsv
}

fn parse_baseline(text: &str) -> BTreeMap<String, Phase> {
    let mut map = BTreeMap::new();
    for (index, line) in text.lines().enumerate() {
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with('#') || line == "archivo\tfase_maxima" {
            continue;
        }
        let (file, phase) = line
            .split_once('\t')
            .unwrap_or_else(|| panic!("{BASELINE}:{}: fila sin tabulador: {line:?}", index + 1));
        let phase = Phase::parse(phase.trim())
            .unwrap_or_else(|| panic!("{BASELINE}:{}: fase desconocida {phase:?}", index + 1));
        assert!(
            map.insert(file.to_string(), phase).is_none(),
            "{BASELINE}:{}: archivo repetido {file}",
            index + 1
        );
    }
    map
}

fn require_nonempty_baseline(baseline: &BTreeMap<String, Phase>) {
    assert!(
        !baseline.is_empty(),
        "{BASELINE} no contiene fuentes: se rechaza una referencia vacía"
    );
}

#[test]
fn empty_baseline_cannot_be_used_to_approve_all_sources() {
    let empty = BTreeMap::new();
    assert!(std::panic::catch_unwind(|| require_nonempty_baseline(&empty)).is_err());
}

// A maintenance mode must never turn an observed coverage regression into
// a new approved baseline. Only improvements (and explicit source changes)
// may be recorded by ELE_UPDATE_SELF_COVERAGE.
fn reject_regressive_baseline_update(regressions: &[String]) {
    assert!(
        regressions.is_empty(),
        "No se puede actualizar {BASELINE}: regresiones detectadas:\n  {}",
        regressions.join("\n  ")
    );
}

#[test]
fn baseline_update_refuses_regressions() {
    reject_regressive_baseline_update(&[]);
    let backward = vec!["lexer.l: lir -> semantica".to_string()];
    assert!(
        std::panic::catch_unwind(|| reject_regressive_baseline_update(&backward)).is_err(),
        "no se debe aceptar un retroceso en modo actualización"
    );
}

#[test]
fn stage1_self_coverage_matches_versioned_baseline() {
    let root = root();
    let mut files = Vec::new();
    sources(&root.join("compiler-l/src"), "", &mut files);
    files.sort();
    assert!(
        !files.is_empty(),
        "no se encontraron fuentes .l en compiler-l/src"
    );

    // A failed build panics inside stage1_support::build with Stage 0's
    // diagnostic: a host that cannot build Stage 1 fails loudly instead of
    // reporting an empty matrix.
    let tools = Tools {
        parser: stage1_support::build("main_parser", false),
        sema: stage1_support::build("main_sema", false),
        native: stage1_support::build("native_cfg_demo", false),
    };
    let work = root.join("target/stage1-tests/self-coverage");
    let runs = root.join(RUNS);
    let _ = fs::remove_dir_all(&runs);
    fs::create_dir_all(&runs).unwrap();

    let slots: Vec<Mutex<Option<Row>>> = files.iter().map(|_| Mutex::new(None)).collect();
    let next = AtomicUsize::new(0);
    let workers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .clamp(1, 4);
    std::thread::scope(|scope| {
        for _ in 0..workers {
            scope.spawn(|| {
                loop {
                    let index = next.fetch_add(1, Ordering::SeqCst);
                    let Some(file) = files.get(index) else { break };
                    let row = measure(file, &tools, &runs, &root);
                    *slots[index].lock().unwrap() = Some(row);
                }
            });
        }
    });
    let rows: Vec<Row> = slots
        .into_iter()
        .map(|slot| slot.into_inner().unwrap().unwrap())
        .collect();

    let mut counts = [0usize; 4];
    for row in &rows {
        for (count, step) in counts.iter_mut().zip(&row.steps) {
            if matches!(step, Step::Passed) {
                *count += 1;
            }
        }
    }
    let matrix = work.join("matrix.md");
    fs::write(&matrix, render_matrix(&rows, &counts)).unwrap();
    let total = rows.len();
    println!(
        "self-coverage on {}: parser {}/{total}, semantica {}/{total}, lir {}/{total}, backend {}/{total}; matrix: target/stage1-tests/self-coverage/matrix.md",
        host(),
        counts[0],
        counts[1],
        counts[2],
        counts[3]
    );

    let baseline_path = root.join(BASELINE);
    let updating = std::env::var_os(UPDATE_VAR).is_some_and(|value| value == "1");
    // A missing/unreadable baseline must never be treated as an empty one:
    // update mode could otherwise silently approve every source as "new".
    let baseline_text = fs::read_to_string(&baseline_path)
        .unwrap_or_else(|err| panic!("No se puede leer {BASELINE}: {err}"));
    let baseline = parse_baseline(&baseline_text);
    require_nonempty_baseline(&baseline);

    let mut regressions = Vec::new();
    let mut improvements = Vec::new();
    let mut added = Vec::new();
    for row in &rows {
        let now = row.reached();
        match baseline.get(&row.file) {
            None => added.push(format!("{} ({})", row.file, now.key())),
            Some(&before) if now < before => {
                regressions.push(format!("{}: {} -> {}", row.file, before.key(), now.key()))
            }
            Some(&before) if now > before => {
                improvements.push(format!("{}: {} -> {}", row.file, before.key(), now.key()))
            }
            Some(_) => {}
        }
    }
    let removed: Vec<String> = baseline
        .keys()
        .filter(|file| !files.contains(file))
        .cloned()
        .collect();

    if updating {
        // Updating the baseline may record genuine progress, but it must
        // NEVER normalize a regression into the new golden matrix.
        reject_regressive_baseline_update(&regressions);
        fs::write(&baseline_path, render_baseline(&rows)).unwrap();
        println!(
            "{BASELINE} regenerada ({total} archivos). Mejoras: {improvements:?}; nuevos: {added:?}; eliminados: {removed:?}"
        );
        return;
    }

    let mut report = String::new();
    if !regressions.is_empty() {
        let _ = writeln!(
            report,
            "REGRESIÓN de autocobertura ({} archivos retroceden respecto de {BASELINE}):\n  {}",
            regressions.len(),
            regressions.join("\n  ")
        );
    }
    if !improvements.is_empty() || !added.is_empty() || !removed.is_empty() {
        let _ = writeln!(
            report,
            "La autocobertura cambió sin actualizar {BASELINE}.\n  mejoras: {improvements:?}\n  nuevos: {added:?}\n  eliminados: {removed:?}\n\
             Registre el progreso regenerando la línea base y versionándola:\n  \
             {UPDATE_VAR}=1 cargo test -p project-l --test self_coverage"
        );
    }
    assert!(
        report.is_empty(),
        "{report}Matriz completa: target/stage1-tests/self-coverage/matrix.md"
    );
}
