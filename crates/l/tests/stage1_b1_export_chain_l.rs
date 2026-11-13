//! Verify the Stage 1 cross-module exports consumed by sema_lower.l,
//! drops_plan.l, stmt.l and loans_check.l, using the real ELE sources.
//! Each exported symbol must resolve from another module while a
//! neighbouring private helper of the same module is still rejected.
mod stage1_support;

use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    sync::OnceLock,
};

fn root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn sema() -> &'static Path {
    static EXE: OnceLock<PathBuf> = OnceLock::new();
    EXE.get_or_init(|| stage1_support::build("main_sema", false))
}

fn prepare_modules() -> PathBuf {
    static DIR: OnceLock<PathBuf> = OnceLock::new();
    DIR.get_or_init(|| {
        let dir = root().join("target/stage1-tests/b1-export-chain");
        fs::create_dir_all(&dir).unwrap();
        for entry in fs::read_dir(root().join("compiler-l/src")).unwrap() {
            let file = entry.unwrap().path();
            if file.extension().is_some_and(|ext| ext == "l") {
                fs::copy(&file, dir.join(file.file_name().unwrap())).unwrap();
            }
        }
        dir
    })
    .clone()
}

fn check(dir: &Path, name: &str, source: &str, expected: bool) -> String {
    let file = dir.join(format!("{name}.l"));
    fs::write(&file, source).unwrap();
    let result = Command::new(sema())
        .arg(file)
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr).into_owned();
    assert_eq!(result.status.success(), expected, "{name}: {stderr}");
    stderr
}

fn assert_consumer(dir: &Path, consumer: &str, import: &str, call: &str) {
    let text = fs::read_to_string(dir.join(consumer)).unwrap();
    assert!(text.contains(&format!("import {import}")), "{consumer}");
    assert!(text.contains(call), "{consumer} no longer uses {call}");
}

fn assert_private(dir: &Path, name: &str, source: &str) {
    let private = check(dir, name, source, false);
    assert!(private.contains("error[L0001]"), "{private}");
    assert!(private.contains(&format!("{name}.l:")), "{private}");
}

fn assert_verifier_internal_private(dir: &Path, name: &str) {
    let stderr = check(
        dir,
        name,
        "import lir_verify\nflow probe() => Int { give lirVerifyInst() }\n",
        false,
    );
    assert!(
        stderr.lines().any(|line| {
            line.contains(&format!("{name}.l:2:")) && line.contains("error[L0001]")
        }),
        "{stderr}"
    );
}

#[test]
fn b1_lir_emit_and_arg_are_public_but_verifier_internal_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "sema_lower.l", "lir_build", "lirEmit(");
    assert_consumer(&dir, "sema_lower.l", "lir_build", "lirArg(");

    let public = check(
        &dir,
        "public_lir_emit",
        "import lir_build\nfn probe(l: &mut LirFn) -> Int {\n    lirEmit(&mut l, 0, 0, 0, 0, 0, 0, 0)\n    return lirArg(&mut l, false, 0, false)\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_verifier_internal_private(&dir, "private_lir_verify_inst_after_emit");
}

#[test]
fn b1_flow_apply_and_uninit_are_public_but_moved_state_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "drops_plan.l", "ownership_l", "flowApply(");
    assert_consumer(&dir, "drops_plan.l", "ownership_l", "FLOW_UNINIT");

    let public = check(
        &dir,
        "public_flow_apply",
        "import flow_cfg\nimport ownership_l\nfn probe(graph: &FlowGraph, state: &mut List<Int>, ev: &FlowEvent) -> Bool {\n    state.push(FLOW_UNINIT)\n    return flowApply(graph, &mut state, ev, false)\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_flow_moved",
        "import flow_cfg\nimport ownership_l\nfn probe() -> Int { return FLOW_MOVED }\n",
    );
}

#[test]
fn b1_parse_expr_is_public_but_primary_expr_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "stmt.l", "expr", "parseExpr(");

    let public = check(
        &dir,
        "public_parse_expr",
        "import expr\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int { return parseExpr(&mut tree, source, &mut cursor, tokens, 0, 0, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_parse_primary_expr",
        "import expr\nfn probe(tree: &mut AstTree, source: &Text, cursor: &mut TokenCursor, tokens: &List<LexToken>) -> Int { return parsePrimaryExpr(&mut tree, source, &mut cursor, tokens, 0, 0) }\n",
    );
}

#[test]
fn b1_loan_overlap_and_mutability_are_public_but_param_root_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "loans_check.l", "flow_cfg", "loanOverlaps(");
    assert_consumer(&dir, "loans_check.l", "loans_l", "loanIsMut(");

    let public = check(
        &dir,
        "public_loan_overlaps",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanOverlaps(graph, 0, 1) || loanIsMut(graph, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_loan_rooted_at_params",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanRootedAtParams(graph, 0) }\n",
    );
}

#[test]
fn b1_lir_const_and_place_helpers_are_public_but_verifier_internal_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "sema_lower.l", "lir_build", "lirConst(");
    assert_consumer(&dir, "sema_lower.l", "lir_build", "lirPlaceVar(");
    assert_consumer(&dir, "lir_finish.l", "lir_build", "lirPathVar(");

    let public = check(
        &dir,
        "public_lir_const",
        "import lir_build\nfn probe(l: &mut LirFn) -> Int {\n    let c = lirConst(&mut l, 0, 1, 0, 0)\n    let slot = lirPathVar(l, 0)\n    return lirPlaceVar(&mut l, slot) + c\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_verifier_internal_private(&dir, "private_lir_verify_inst_after_const");
}

#[test]
fn b1_loan_positions_and_place_are_public_but_param_root_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "drops_dump.l", "loans_l", "loanLineAt(");
    assert_consumer(&dir, "drops_dump.l", "loans_l", "loanColAt(");
    assert_consumer(&dir, "loans_check.l", "loans_l", "loanPlaceOf(");

    let public = check(
        &dir,
        "public_loan_place_of",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &mut FlowGraph, source: &Text) -> Int {\n    let line = loanLineAt(source, 0)\n    let col = loanColAt(source, 0)\n    return loanPlaceOf(&mut graph, 0) + line + col\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_loan_rooted_at_params_again",
        "import flow_cfg\nimport loans_l\nfn probe(graph: &FlowGraph) -> Bool { return loanRootedAtParams(graph, 0) }\n",
    );
}

#[test]
fn b1_drop_op_kinds_are_public_but_drop_flag_search_stays_private() {
    let dir = prepare_modules();
    assert_consumer(&dir, "drops_verify.l", "drops_plan", "DROP_OP_REF");
    assert_consumer(&dir, "drops_verify.l", "drops_plan", "DROP_OP_DROP");
    assert_consumer(&dir, "lir_finish.l", "drops_plan", "DROP_OP_COND");

    let public = check(
        &dir,
        "public_drop_op_kinds",
        "import drops_plan\nfn probe() -> Int { return DROP_OP_DROP + DROP_OP_COND + DROP_OP_SET + DROP_OP_CLEAR + DROP_OP_REF }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_private(
        &dir,
        "private_drop_releases",
        "import flow_cfg\nimport drops_plan\nfn probe(graph: &FlowGraph) -> Bool { return dropReleases(graph, 0, 0) }\n",
    );
}

#[test]
fn b1_lir_unsupported_marker_is_public_for_actual_consumers() {
    let dir = prepare_modules();
    for consumer in [
        "sema_stmt.l",
        "sema_collection_ops.l",
        "sema_builtin_union.l",
        "sema_match_coverage.l",
        "sema_ops.l",
        "stmt_lower.l",
    ] {
        assert_consumer(&dir, consumer, "lir_build", "lirMarkUnsupported(");
    }

    let public = check(
        &dir,
        "public_lir_unsupported",
        "import lir_build\nfn probe(l: &mut LirFn) -> Int { lirMarkUnsupported(&mut l, 7); return 0 }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    // Do not freeze lirBlocks as private here: other real lowerers invoke
    // it and a later B1 export must be tested independently.
}

#[test]
fn b1_lir_blocks_is_public_for_actual_consumers_but_verifier_internal_stays_private() {
    let dir = prepare_modules();
    for consumer in ["lir_finish.l", "sema_ops.l", "stmt_lower.l"] {
        assert_consumer(&dir, consumer, "lir_build", "lirBlocks(");
    }

    let public = check(
        &dir,
        "public_lir_blocks",
        "import lir_build\nflow probe(l: edit LirFn) => Int { lirBlocks(edit l, 1) give 0 }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_verifier_internal_private(&dir, "private_lir_verify_inst_after_blocks");
}

#[test]
fn b1_lir_index_place_is_public_for_collection_lowering_but_verifier_internals_stay_private() {
    let dir = prepare_modules();
    for consumer in ["sema_collection_ops.l", "sema_stmt.l"] {
        assert_consumer(&dir, consumer, "lir_build", "lirPlaceIndex(");
    }

    let public = check(
        &dir,
        "public_lir_place_index",
        "import lir_build\nflow probe(l: edit LirFn) => Int { give lirPlaceIndex(edit l, 0, 0) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_verifier_internal_private(&dir, "private_lir_verify_inst_after_index");
}

#[test]
fn b1_lir_type_compatibility_is_public_for_verifier_but_instruction_walker_stays_private() {
    let dir = prepare_modules();
    for consumer in ["lir_verify.l", "lir_verify_helpers.l"] {
        assert_consumer(&dir, consumer, "lir_build", "lirTypesCompat(");
    }

    let public = check(
        &dir,
        "public_lir_types_compat",
        "import lir_build\nflow probe(types: view TypeTable, lm: view LirModule) => Bool { give lirTypesCompat(types, lm, 1, 1) }\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_verifier_internal_private(&dir, "private_lir_verify_inst_after_types_compat");
}

#[test]
fn b1_verifier_core_exports_only_helpers_used_by_verifier_modules() {
    let dir = prepare_modules();
    for (symbol, consumers) in [
        ("LIR_TY_ERR", &["lir_verify.l"][..]),
        ("lirVarOk(", &["lir_verify.l", "lir_verify_helpers.l"][..]),
        (
            "lirOperandType(",
            &["lir_verify.l", "lir_verify_helpers.l"][..],
        ),
        ("lirStructOf(", &["lir_verify.l"][..]),
        ("lirPlaceType(", &["lir_verify.l"][..]),
        ("lirUse(", &["lir_verify.l", "lir_verify_helpers.l"][..]),
        ("lirArgType(", &["lir_verify.l", "lir_verify_helpers.l"][..]),
        ("lirPrintable(", &["lir_verify.l"][..]),
        (
            "lirArgDefined(",
            &["lir_verify.l", "lir_verify_helpers.l"][..],
        ),
    ] {
        for consumer in consumers {
            assert_consumer(&dir, consumer, "lir_verify_core", symbol);
        }
    }

    let public = check(
        &dir,
        "public_lir_verifier_core",
        "import lir_verify_core\nfn probe(v: &mut LirVerifier, l: &LirFn, types: &TypeTable, lm: &LirModule) -> Bool {\n    let ty = lirArgType(l, types, lm, 0)\n    let place_ty = lirPlaceType(l, types, lm, 0)\n    let struct_id = lirStructOf(types, lm, ty)\n    let operand_ty = lirOperandType(l, 0)\n    let ok = lirVarOk(l, 0) && lirPrintable(ty) && lirUse(&mut v, l, 0, false) && lirArgDefined(&mut v, l, 0, false)\n    return ok && ty != LIR_TY_ERR && place_ty == operand_ty && struct_id >= 0\n}\n",
        true,
    );
    assert!(public.is_empty(), "{public}");

    assert_verifier_internal_private(&dir, "private_lir_verify_inst_after_core");
}

#[test]
fn b1_lir_finish_checks_ownership_after_internal_exports() {
    let dir = prepare_modules();
    let result = Command::new(sema())
        .arg(dir.join("lir_finish.l"))
        .arg("--check-ownership")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&result.stderr);
    assert!(result.status.success(), "{stderr}");
    assert!(stderr.is_empty(), "{stderr}");
}

#[test]
fn b1_lir_verifier_modules_check_ownership_after_internal_exports() {
    let dir = prepare_modules();
    for module in ["lir_verify_helpers.l", "lir_verify.l"] {
        let result = Command::new(sema())
            .arg(dir.join(module))
            .arg("--check-ownership")
            .output()
            .unwrap();
        let stderr = String::from_utf8_lossy(&result.stderr);
        assert!(result.status.success(), "{module}: {stderr}");
        assert!(stderr.is_empty(), "{module}: {stderr}");
    }
}

#[test]
fn b1_verifier_helpers_reject_out_of_bounds_ids_without_panicking() {
    // Execute real Stage 1 verifier helpers through the Stage 0 bootstrap.
    // Invalid argument/place/root IDs must be rejected, even with check=false;
    // a too-short defined-state table must not cause an out-of-bounds access.
    let dir = prepare_modules();
    let entry = dir.join("b1_verifier_helper_runtime.l");
    fs::write(
        &entry,
        r#"take lir_build
take lir_verify_core
take sema_types

flow main() => Int {
    change l: LirFn = lirFnNew()
    // Keep generic empty-list element types explicit across the module
    // boundary. These are five distinct owned buffers, moved into v.
    change defined: List of[Bool] = List[]
    change table: List of[Bool] = List[]
    change seen: List of[Bool] = List[]
    change pending: List of[Bool] = List[]
    change queue: List of[Int] = List[]
    change v: LirVerifier = LirVerifier(
        defined: defined,
        table: table,
        seen: seen,
        pending: pending,
        queue: queue,
        status: 0
    )

    when lirArgDefined(edit v, view l, -1, false) { give 1 }
    when lirArgDefined(edit v, view l, 0, true) { give 2 }
    when lirUse(edit v, view l, 0, true) { give 3 }
    when lirUse(edit v, view l, LIR_NONE, false) { give 15 }
    when lirUse(edit v, view l, -1, false) { give 16 }
    hold constant = lirConst(edit l, LIR_CONST_INT, 42, 0, 0)
    when !lirUse(edit v, view l, constant, true) { give 17 }
    hold malformed = lirConst(edit l, 99, 0, 0, 0)
    when lirOperandType(view l, malformed) != LIR_TY_ERR { give 18 }
    when lirUse(edit v, view l, malformed, false) { give 27 }
    hold malformed_arg = lirArg(edit l, false, malformed, false)
    when lirArgDefined(edit v, view l, malformed_arg, false) { give 28 }
    hold invalid_value_arg = lirArg(edit l, false, LIR_NONE, false)
    when lirArgDefined(edit v, view l, invalid_value_arg, false) { give 19 }

    hold slot = lirVar(edit l, 1, false)
    when lirUse(edit v, view l, slot, true) { give 4 }
    when !lirUse(edit v, view l, slot, false) { give 5 }

    hold missing_place_arg = lirArg(edit l, true, 99, false)
    when lirArgDefined(edit v, view l, missing_place_arg, false) { give 6 }
    hold wrong_root_place = lirPlaceVar(edit l, 99)
    hold wrong_root_arg = lirArg(edit l, true, wrong_root_place, false)
    when lirArgDefined(edit v, view l, wrong_root_arg, true) { give 7 }

    hold place = lirPlaceVar(edit l, slot)
    hold ref_arg = lirArg(edit l, true, place, false)
    when lirArgDefined(edit v, view l, ref_arg, true) { give 8 }
    when !lirArgDefined(edit v, view l, ref_arg, false) { give 9 }
    hold value_arg = lirArg(edit l, false, slot, false)
    when lirArgDefined(edit v, view l, value_arg, true) { give 10 }
    when !lirArgDefined(edit v, view l, value_arg, false) { give 11 }

    v.defined.push(true)
    when !lirUse(edit v, view l, slot, true) { give 12 }
    when !lirArgDefined(edit v, view l, ref_arg, true) { give 13 }
    when !lirArgDefined(edit v, view l, value_arg, true) { give 14 }

    change types = typeTableNew()
    hold struct_ty = semTypeAdd(edit types, SemTypeKind.Struct, -1, -1, -1, 42)
    change lm = lirModuleNew()
    lm.st_decl.push(42)
    hold struct_slot = lirVar(edit l, struct_ty, false)
    hold struct_place = lirPlaceVar(edit l, struct_slot)
    hold field_place = lirPlaceField(edit l, struct_place, 0)
    when lirPlaceType(view l, view types, view lm, field_place) != LIR_TY_ERR { give 20 }

    lm.st_first.push(0)
    lm.st_count.push(1)
    when lirPlaceType(view l, view types, view lm, field_place) != LIR_TY_ERR { give 21 }
    lm.field_ty.push(1)
    when lirPlaceType(view l, view types, view lm, field_place) != 1 { give 22 }

    lm.st_count[0] = 2
    when lirPlaceType(view l, view types, view lm, field_place) != LIR_TY_ERR { give 23 }
    lm.st_count[0] = 1
    lm.field_ty[0] = 999
    when lirPlaceType(view l, view types, view lm, field_place) != LIR_TY_ERR { give 24 }
    lm.field_ty[0] = 1
    lm.st_first[0] = -1
    when lirPlaceType(view l, view types, view lm, field_place) != LIR_TY_ERR { give 25 }
    lm.st_first[0] = 0
    when lirPlaceType(view l, view types, view lm, field_place) != 1 { give 26 }
    give 42
}
"#,
    )
    .unwrap();

    let build_dir = root().join("target/stage1-tests/b1-verifier-helper-runtime");
    fs::create_dir_all(&build_dir).unwrap();
    let mut build = Command::new(env!("CARGO_BIN_EXE_l"));
    build.current_dir(&build_dir).arg("build").arg(&entry);
    if cfg!(windows) {
        build.args(["--backend", "cranelift"]);
    }
    let built = build.output().unwrap();
    let numbered_fixture = fs::read_to_string(&entry)
        .unwrap()
        .lines()
        .enumerate()
        .map(|(i, line)| format!("{:>3}: {line}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        built.status.success(),
        "Stage 0 fixture failed at {}:\n{}\nstdout:\n{}\nstderr:\n{}",
        entry.display(),
        numbered_fixture,
        String::from_utf8_lossy(&built.stdout),
        String::from_utf8_lossy(&built.stderr)
    );
    let stdout = String::from_utf8_lossy(&built.stdout);
    let exe = stdout
        .lines()
        .find_map(|line| line.strip_prefix("Build: "))
        .expect("Stage 0 did not report the executable");
    let result = Command::new(build_dir.join(exe)).output().unwrap();
    assert_eq!(
        result.status.code(),
        Some(42),
        "verifier guards: {}{}",
        String::from_utf8_lossy(&result.stdout),
        String::from_utf8_lossy(&result.stderr)
    );
}
