//! Stage 1 drop elaboration (written in L, `sema-l --drop-plan`) compared
//! with Stage 0 (`drops::elaborate` on the block LIR).
//!
//! Both plans are executed on every control-flow path up to a bounded
//! number of branch decisions: the Stage 1 plan from its text dump, the
//! Stage 0 CFG instruction by instruction. Drop flags are simulated in both.
//! The sequence of released places (parameter `P<i>` or definition
//! `S<line>:<col>`, plus struct field indices) must be identical on every
//! path. Stage 1 only plans the drops; it does not generate code for them.
mod stage1_support;

use project_l::cfg::{Func, InstKind, Operand, Proj, Rvalue, Terminator, VarTy};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn sema_exe() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn case_file(name: &str, source: &str) -> PathBuf {
    let file = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/stage1-tests/drops")
        .join(format!("{name}.l"));
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, source).unwrap();
    file
}

/// Runs the native Stage 1 driver with an empty PATH.
fn run_stage1(name: &str, source: &str, flag: &str) -> (Option<i32>, String, String) {
    let output = Command::new(sema_exe())
        .arg(case_file(name, source))
        .arg(flag)
        .env("PATH", "")
        .output()
        .unwrap();
    (
        output.status.code(),
        String::from_utf8_lossy(&output.stdout).to_string(),
        String::from_utf8_lossy(&output.stderr).to_string(),
    )
}

struct Block1 {
    next: (i64, i64),
    reached: bool,
    ops: Vec<(String, String, i64)>,
}

struct Plan1 {
    name: String,
    blocks: Vec<Block1>,
}

fn name_at(source: &str, at: &str) -> String {
    let (line, col) = at.split_once(':').unwrap();
    let text = source
        .lines()
        .nth(line.parse::<usize>().unwrap() - 1)
        .unwrap();
    text.chars()
        .skip(col.parse::<usize>().unwrap() - 1)
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect()
}

fn parse_plans(source: &str, dump: &str) -> Vec<Plan1> {
    let mut plans: Vec<Plan1> = Vec::new();
    for line in dump.lines() {
        let words: Vec<&str> = line.split_whitespace().collect();
        match words.first().copied() {
            Some("DropPlan") => plans.push(Plan1 {
                name: name_at(source, words[1].strip_prefix("fn=").unwrap()),
                blocks: Vec::new(),
            }),
            Some("B") => plans.last_mut().unwrap().blocks.push(Block1 {
                next: (words[2].parse().unwrap(), words[3].parse().unwrap()),
                reached: words[4] == "1",
                ops: Vec::new(),
            }),
            Some("O") => {
                let block = plans.last_mut().unwrap().blocks.last_mut().unwrap();
                block.ops.push((
                    words[1].to_string(),
                    words[2].to_string(),
                    words[3].parse().unwrap(),
                ));
            }
            _ => {}
        }
    }
    plans
}

/// Outcome of one bounded execution: released places and whether it
/// stopped because it needed one more branch decision.
#[derive(Debug, PartialEq)]
struct Run {
    drops: Vec<String>,
    needs_more: bool,
}

const STEP_LIMIT: usize = 20_000;

fn run_plan1(plan: &Plan1, decisions: &[bool]) -> Run {
    let mut flags: HashMap<i64, bool> = HashMap::new();
    let mut drops = Vec::new();
    let mut used = 0;
    let mut block = 0usize;
    for _ in 0..STEP_LIMIT {
        let b = &plan.blocks[block];
        assert!(
            b.reached,
            "{}: unreachable block {block} executed",
            plan.name
        );
        for (kind, place, flag) in &b.ops {
            match kind.as_str() {
                "drop" | "ref" => drops.push(place.clone()),
                "cdrop" => {
                    if flags.get(flag).copied().unwrap_or(false) {
                        drops.push(place.clone());
                    }
                }
                "set" => {
                    flags.insert(*flag, true);
                }
                "clear" => {
                    flags.insert(*flag, false);
                }
                other => panic!("unknown op {other}"),
            }
        }
        block = match b.next {
            (-1, _) => {
                return Run {
                    drops,
                    needs_more: false,
                };
            }
            (a, -1) => a as usize,
            (a, c) => {
                let Some(&take) = decisions.get(used) else {
                    return Run {
                        drops,
                        needs_more: true,
                    };
                };
                used += 1;
                if take { a as usize } else { c as usize }
            }
        };
    }
    panic!("{}: step limit", plan.name)
}

struct Stage0<'a> {
    func: &'a Func,
    names: Vec<String>,
    ownership: project_l::drops::Ownership,
}

impl<'a> Stage0<'a> {
    fn new(func: &'a Func, module: &project_l::cfg::Module) -> Self {
        let mut names = vec![String::new(); func.vars.len()];
        for (i, p) in func.params.iter().enumerate() {
            names[*p] = format!("P{i}");
        }
        for block in &func.blocks {
            for inst in &block.insts {
                if let InstKind::Assign(v, _) = &inst.kind
                    && names[*v].is_empty()
                {
                    names[*v] = format!("S{}:{}", inst.span.line, inst.span.column);
                }
            }
        }
        let ownership = project_l::drops::Ownership::new(
            &module.structs,
            &module.enums,
            &module.arrays,
            &module.lists,
        );
        Stage0 {
            func,
            names,
            ownership,
        }
    }

    fn place(&self, var: usize, proj: &[Proj]) -> String {
        let mut out = self.names[var].clone();
        for p in proj {
            match p {
                Proj::Field(i) => out.push_str(&format!(".{i}")),
                other => panic!("unexpected projection {other:?}"),
            }
        }
        out
    }

    fn run(&self, decisions: &[bool]) -> Run {
        let mut flags: HashMap<usize, bool> = HashMap::new();
        let mut drops = Vec::new();
        let mut used = 0;
        let mut block = 0usize;
        let on = |flags: &HashMap<usize, bool>, f: &Option<usize>| match f {
            None => true,
            Some(f) => flags.get(f).copied().unwrap_or(false),
        };
        for _ in 0..STEP_LIMIT {
            let b = &self.func.blocks[block];
            for inst in &b.insts {
                match &inst.kind {
                    InstKind::Assign(
                        v,
                        Rvalue::Use(Operand::Const(project_l::cfg::Const::Bool(x))),
                    ) => {
                        flags.insert(*v, *x);
                    }
                    InstKind::Drop(v, f) if on(&flags, f) => drops.push(self.place(*v, &[])),
                    InstKind::DropField(p, f) if on(&flags, f) => {
                        drops.push(self.place(p.var, &p.proj))
                    }
                    // Storing through a reference root releases the old
                    // referent in the backend (native.rs); Stage 1 makes it
                    // an explicit `ref` operation.
                    InstKind::Store(p, _)
                        if p.proj.is_empty()
                            && matches!(self.func.vars[p.var], VarTy::Ref(t) if self.ownership.needs_drop(t)) =>
                    {
                        drops.push(self.place(p.var, &[]))
                    }
                    _ => {}
                }
            }
            block = match b.term.as_ref().unwrap() {
                Terminator::Jump(next) => *next,
                Terminator::Branch(_, a, c) => {
                    let Some(&take) = decisions.get(used) else {
                        return Run {
                            drops,
                            needs_more: true,
                        };
                    };
                    used += 1;
                    if take { *a } else { *c }
                }
                _ => {
                    return Run {
                        drops,
                        needs_more: false,
                    };
                }
            };
        }
        panic!("{}: step limit", self.func.name)
    }
}

const MAX_DECISIONS: usize = 7;

/// Compares both plans of every function on all paths with up to
/// MAX_DECISIONS branch decisions. Returns the number of paths compared.
fn compare(name: &str, source: &str) -> usize {
    let (code, stdout, stderr) = run_stage1(name, source, "--drop-plan");
    assert_eq!(code, Some(0), "{name}: {stderr}");
    let program = project_l::check(source).unwrap_or_else(|d| panic!("{name}: {d:?}"));
    let module = project_l::lower_to_cfg(&program).unwrap();
    let mut paths = 0;
    for plan in parse_plans(source, &stdout) {
        let func = module
            .funcs
            .iter()
            .find(|f| f.name == plan.name)
            .unwrap_or_else(|| panic!("{name}: no Stage 0 function {}", plan.name));
        let stage0 = Stage0::new(func, &module);
        let mut pending = vec![Vec::<bool>::new()];
        while let Some(decisions) = pending.pop() {
            let one = run_plan1(&plan, &decisions);
            let zero = stage0.run(&decisions);
            assert_eq!(
                one, zero,
                "{name}::{} on path {decisions:?}\n{stdout}",
                plan.name
            );
            paths += 1;
            if one.needs_more && decisions.len() < MAX_DECISIONS {
                for take in [true, false] {
                    let mut next = decisions.clone();
                    next.push(take);
                    pending.push(next);
                }
            }
        }
    }
    paths
}

use stage1_support::drop_cases::{DROP_CASES, PRELUDE};

#[test]
fn stage1_drop_plans_match_stage0_on_every_path() {
    let mut paths = 0;
    for (name, body) in DROP_CASES {
        paths += compare(name, &format!("{PRELUDE}{body}\nfn main() {{}}"));
    }
    println!("drop cases: {} programs, {paths} paths", DROP_CASES.len());
    assert!(paths > 300, "only {paths} paths compared");
}

#[test]
fn stage1_drop_plans_match_stage0_on_the_borrow_corpus() {
    let mut programs = 0;
    let mut paths = 0;
    for (name, source, stage1, _) in stage1_support::borrow_cases::CASES {
        if *stage1 == "OK" {
            paths += compare(&format!("borrow_{name}"), source);
            programs += 1;
        }
    }
    println!("borrow corpus: {programs} programs, {paths} paths");
    assert!(programs > 70, "{programs}");
}

/// Moves of an outer value inside a loop: Stage 0 rejects them (L0005,
/// "podría repetirse"), Stage 1 accepts them when the value is reinitialized
/// before the next use, so only the Stage 1 verifier can judge the plan.
const STAGE1_ONLY: &[(&str, &str)] = &[
    (
        "while_move_reinit",
        "fn f(c: Bool) { var t = \"a\"\n while c { take(t);\n t = \"b\" }\n print(t)\n}",
    ),
    (
        "loop_break_maybe_moved",
        "fn f(c: Bool) { var t = \"a\"
 while c { take(t);
 t = \"b\"
 if c { take(t);
 break } }
}",
    ),
];

#[test]
fn stage1_plans_flags_for_loop_moves_that_stage0_rejects() {
    for (name, body) in STAGE1_ONLY {
        let source = format!(
            "{PRELUDE}{body}
fn main() {{}}"
        );
        let (code, stdout, stderr) = run_stage1(name, &source, "--drop-plan");
        assert_eq!(code, Some(0), "{name}: {stderr}");
        let conditional = stdout.contains("O cdrop ");
        assert_eq!(
            conditional,
            *name == "loop_break_maybe_moved",
            "{name}: {stdout}"
        );
        let stage0 = project_l::check(&source).expect_err(name);
        assert_eq!(stage0.code, "L0005", "{name}: {stage0:?}");
    }
}

#[test]
fn verifier_rejects_corrupted_plans_as_internal_errors() {
    // Each fault corrupts a correct plan in one way (drops_verify.l).
    let source = format!(
        "{PRELUDE}struct U {{ n: Text, c: Text }}\nfn f(k: Bool) {{ var u = U(n: \"a\", c: \"b\")\n u.c = \"z\"\n if k {{ take(u.n); }}\n u = U(n: \"x\", c: \"y\")\n}}\nfn main() {{}}"
    );
    let (code, _, stderr) = run_stage1("fault_none", &source, "--check-ownership");
    assert_eq!(code, Some(0), "{stderr}");
    for (fault, rule) in [(1, 2), (2, 7), (3, 2), (4, 3), (5, 4), (6, 1), (7, 1)] {
        let (code, stdout, stderr) = run_stage1(
            &format!("fault_{fault}"),
            &source,
            &format!("--drop-fault={fault}"),
        );
        assert_eq!(code, Some(1), "fault {fault}: {stdout}{stderr}");
        assert!(
            stderr.contains("error[ICE]")
                && stderr.contains(&format!("plan de drops inválido (regla {rule})")),
            "fault {fault}: {stderr}"
        );
    }
}

#[test]
fn unsafe_programs_stay_rejected_with_user_diagnostics() {
    let cases = [
        (
            "read_after_move",
            "fn f() { let a = \"x\"\n take(a);\n print(a)\n}",
            "L0005",
        ),
        (
            "read_maybe_moved",
            "fn f(c: Bool) { let a = \"x\"\n if c { take(a); }\n print(a)\n}",
            "L0005",
        ),
        (
            "aggregate_partly_moved",
            "struct U { n: Text, c: Text }\nfn g(u: U) -> Int = 1\nfn f() { let u = U(n: \"a\", c: \"b\")\n take(u.n);\n print(g(u))\n}",
            "L0005",
        ),
        (
            "move_while_borrowed",
            "fn f() { let a = \"x\"\n let r = &a\n take(a);\n print(r)\n}",
            "L0012",
        ),
        (
            "dangling_return",
            "fn f() -> &Text { let a = \"x\"\n return &a\n}",
            "L0013",
        ),
        (
            "write_owner_while_borrowed",
            "fn f() { var a = \"x\"\n let r = &a\n a = \"y\"\n print(r)\n}",
            "L0012",
        ),
    ];
    for (name, body, code) in cases {
        let source = format!("{PRELUDE}{body}\nfn main() {{}}");
        let (status, _, stderr) = run_stage1(name, &source, "--drop-plan");
        assert_eq!(status, Some(1), "{name}: {stderr}");
        assert!(
            stderr.contains(&format!("error[{code}]")),
            "{name}: {stderr}"
        );
        assert!(!stderr.contains("ICE"), "{name}: {stderr}");
        let stage0 = project_l::check(&source).expect_err(name);
        assert_eq!(stage0.code, code, "{name}: {stage0:?}");
    }
}

#[test]
fn drop_elaboration_scales_and_frees_its_memory() {
    use std::fmt::Write as _;
    // 1 000 owned locals over nested scopes, a loop and an early return.
    let mut source = String::from("fn take(t: Text) -> Int = 1\nfn f(c: Bool) {\n");
    for i in 0..1000 {
        if i % 100 == 0 {
            source.push_str("{\n");
        }
        writeln!(source, "var v{i} = \"x\"").unwrap();
        if i % 10 == 0 {
            writeln!(source, "if c {{ take(v{i}); }}").unwrap();
        }
        if i % 100 == 99 {
            source.push_str("if c { return }\n}\n");
        }
    }
    source.push_str("}\nfn main() {}\n");
    let (code, stdout, stderr) = run_stage1("drop_scale", &source, "--check-ownership");
    assert_eq!(code, Some(0), "{stderr}");
    assert!(stdout.contains("flags=100"), "{stdout}");

    let traced = stage1_support::build("main_sema", true);
    let output = Command::new(traced)
        .arg(case_file("drop_trace", &source))
        .arg("--drop-plan")
        .output()
        .unwrap();
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(output.status.success(), "{stderr}");
    stage1_support::assert_heap(&stderr);
}
