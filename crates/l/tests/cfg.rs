//! Block-based LIR: lowering shape and verifier (positive and negative).
use project_l::{
    Span,
    cfg::{
        self, Arg, BinOp, Block, Const, Func, Inst, InstKind, Module, Operand, Place, Proj, Rvalue,
        Terminator, VarTy, verify,
    },
    lir::Type,
};
use std::{fs, path::PathBuf};

fn lower(source: &str) -> Module {
    let ir = project_l::check(source).unwrap_or_else(|e| panic!("{e:?}"));
    project_l::lower_to_cfg(&ir).unwrap()
}

fn inst(kind: InstKind) -> Inst {
    Inst {
        kind,
        span: Span { line: 1, column: 1 },
    }
}

/// `fn main() { return }` plus one extra function under test.
fn module_with(func: Func) -> Module {
    let main = Func {
        name: "main".into(),
        params: Vec::new(),
        vars: Vec::new(),
        result: Type::Unit,
        borrow_return: None,
        view_return: None,
        blocks: vec![Block {
            insts: Vec::new(),
            term: Some(Terminator::Return(Operand::Const(Const::Unit))),
        }],
    };
    Module {
        structs: Vec::new(),
        enums: Vec::new(),
        arrays: Vec::new(),
        slices: Vec::new(),
        lists: Vec::new(),
        task_groups: Vec::new(),
        futures: Vec::new(),
        funcs: vec![main, func],
        main: 0,
    }
}

fn int_func(vars: Vec<VarTy>, blocks: Vec<Block>) -> Func {
    Func {
        name: "f".into(),
        params: vec![0],
        vars,
        result: Type::Int,
        borrow_return: None,
        view_return: None,
        blocks,
    }
}

#[test]
fn every_block_terminates_and_entry_is_first() {
    let m = lower(
        "fn f(n: Int) -> Int {\n var i = 0\n while i < n { i += 1 }\n return i\n}\nfn main() { print(f(3)) }",
    );
    let f = &m.funcs[0];
    assert_eq!(f.params.len(), 1);
    assert!(f.blocks.iter().all(|b| b.term.is_some()));
    // The loop has a conditional exit and a back edge to its header.
    let branches = f
        .blocks
        .iter()
        .filter(|b| matches!(b.term, Some(Terminator::Branch(..))))
        .count();
    assert!(branches >= 1);
    let back_edge = f
        .blocks
        .iter()
        .enumerate()
        .any(|(i, b)| matches!(b.term, Some(Terminator::Jump(t)) if t < i));
    assert!(back_edge, "{f:#?}");
}

#[test]
fn checked_arithmetic_and_short_circuit_are_explicit() {
    let m = lower("fn f(a: Int, b: Bool) -> Bool = a + 1 > 2 && b\nfn main() {}");
    let f = &m.funcs[0];
    let has_add = f
        .blocks
        .iter()
        .flat_map(|b| &b.insts)
        .any(|i| matches!(&i.kind, InstKind::Assign(_, Rvalue::Binary(BinOp::Add, ..))));
    assert!(has_add);
    // `&&` lowers to a branch, not to an operator.
    assert!(
        f.blocks
            .iter()
            .filter(|b| matches!(b.term, Some(Terminator::Branch(..))))
            .count()
            >= 1
    );
}

#[test]
fn structs_enums_and_match_have_memory_level_operations() {
    let m = lower(
        "struct P {\n x: Int\n}\nenum E {\n A\n B(Text)\n}\nimpl P {\n mut fn inc() { self.x += 1 }\n}\nfn main() {\n var p = P(x: 1)\n p.inc()\n let e = E.B(\"t\")\n match e { E.A => {}, E.B(t) => print(t) }\n}",
    );
    let main = &m.funcs[m.main];
    let insts: Vec<&InstKind> = main
        .blocks
        .iter()
        .flat_map(|b| &b.insts)
        .map(|i| &i.kind)
        .collect();
    assert!(
        insts
            .iter()
            .any(|k| matches!(k, InstKind::Assign(_, Rvalue::Struct(..))))
    );
    assert!(
        insts
            .iter()
            .any(|k| matches!(k, InstKind::Assign(_, Rvalue::Variant(_, 1, _))))
    );
    assert!(
        insts
            .iter()
            .any(|k| matches!(k, InstKind::Assign(_, Rvalue::Discriminant(_))))
    );
    // The Text payload binding only reads, so it borrows from the scrutinee.
    assert!(insts.iter().any(|k| matches!(
        k,
        InstKind::Assign(_, Rvalue::Ref(Place { proj, .. })) if proj == &vec![Proj::Payload(1, 0)]
    )));
    // The mut method receives an exclusive borrow of `p`.
    assert!(insts.iter().any(|k| matches!(
        k,
        InstKind::Assign(_, Rvalue::Call(_, args)) if matches!(args[0], Arg::Ref(_, true))
    )));
    let method = m.funcs.iter().find(|f| f.name == "P.inc").unwrap();
    assert!(matches!(
        method.vars[method.params[0]],
        VarTy::Ref(Type::Struct(0))
    ));
    assert!(
        method
            .blocks
            .iter()
            .flat_map(|b| &b.insts)
            .any(|i| matches!(i.kind, InstKind::Store(..)))
    );
}

#[test]
fn all_repository_programs_lower_and_verify() {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    let mut count = 0;
    for dir in [
        "examples",
        "ejemplos",
        "crates/l/tests/differential",
        "crates/l/tests/differential/unsupported",
    ] {
        for entry in fs::read_dir(root.join(dir)).unwrap().flatten() {
            let path = entry.path();
            if path.extension().is_none_or(|e| e != "l") {
                continue;
            }
            let source = fs::read_to_string(&path).unwrap();
            // `check` lowers and verifies; only semantic errors may fail it.
            if let Err(e) = project_l::check(&source) {
                assert_ne!(e.code, "L0007", "{}: {e:?}", path.display());
            } else {
                count += 1;
            }
        }
    }
    assert!(count >= 20, "{count}");
}

#[test]
fn verifier_accepts_a_well_formed_function() {
    // f(n) { v1 = n + 1; if v1 > 0 { v2 = v1 } else { v2 = 0 }; return v2 }
    let f = int_func(
        vec![VarTy::Value(Type::Int); 4],
        vec![
            Block {
                insts: vec![
                    inst(InstKind::Assign(
                        1,
                        Rvalue::Binary(BinOp::Add, Operand::Var(0), Operand::Const(Const::Int(1))),
                    )),
                    inst(InstKind::Assign(
                        3,
                        Rvalue::Use(Operand::Const(Const::Int(0))),
                    )),
                ],
                term: Some(Terminator::Jump(1)),
            },
            Block {
                insts: Vec::new(),
                term: Some(Terminator::Branch(Operand::Const(Const::Bool(true)), 2, 3)),
            },
            Block {
                insts: vec![inst(InstKind::Assign(2, Rvalue::Use(Operand::Var(1))))],
                term: Some(Terminator::Return(Operand::Var(2))),
            },
            Block {
                insts: vec![inst(InstKind::Assign(2, Rvalue::Use(Operand::Var(3))))],
                term: Some(Terminator::Return(Operand::Var(2))),
            },
        ],
    );
    verify(&module_with(f)).unwrap();
}

fn expect_error(f: Func, cause: &str) {
    let e = verify(&module_with(f)).expect_err(cause);
    assert!(e.message.contains(cause), "{e:?}");
    let d = e.into_diagnostic();
    assert_eq!((d.code, d.category), ("L0007", "lir"));
}

#[test]
fn verifier_rejects_malformed_functions() {
    let int = VarTy::Value(Type::Int);
    let ret0 = || Some(Terminator::Return(Operand::Var(0)));
    // Block without terminator.
    expect_error(
        int_func(
            vec![int],
            vec![Block {
                insts: Vec::new(),
                term: None,
            }],
        ),
        "sin terminador",
    );
    // Jump to a block that does not exist.
    expect_error(
        int_func(
            vec![int],
            vec![Block {
                insts: Vec::new(),
                term: Some(Terminator::Jump(7)),
            }],
        ),
        "bloque inexistente",
    );
    // Assigning a Bool to an Int variable.
    expect_error(
        int_func(
            vec![int, int],
            vec![Block {
                insts: vec![inst(InstKind::Assign(
                    1,
                    Rvalue::Use(Operand::Const(Const::Bool(true))),
                ))],
                term: ret0(),
            }],
        ),
        "asignación a v1",
    );
    // Branch on an Int.
    expect_error(
        int_func(
            vec![int],
            vec![
                Block {
                    insts: Vec::new(),
                    term: Some(Terminator::Branch(Operand::Var(0), 1, 1)),
                },
                Block {
                    insts: Vec::new(),
                    term: ret0(),
                },
            ],
        ),
        "condición de salto",
    );
    // Returning a Bool from an Int function.
    expect_error(
        int_func(
            vec![int],
            vec![Block {
                insts: Vec::new(),
                term: Some(Terminator::Return(Operand::Const(Const::Bool(false)))),
            }],
        ),
        "retorno",
    );
    // Arithmetic between Int and Bool.
    expect_error(
        int_func(
            vec![int, int],
            vec![Block {
                insts: vec![inst(InstKind::Assign(
                    1,
                    Rvalue::Binary(
                        BinOp::Add,
                        Operand::Var(0),
                        Operand::Const(Const::Bool(true)),
                    ),
                ))],
                term: ret0(),
            }],
        ),
        "operandos",
    );
    // Undeclared variable.
    expect_error(
        int_func(
            vec![int],
            vec![Block {
                insts: Vec::new(),
                term: Some(Terminator::Return(Operand::Var(9))),
            }],
        ),
        "variable inexistente",
    );
    // Call with the wrong number of arguments (callee 1 is `f` itself).
    expect_error(
        int_func(
            vec![int, int],
            vec![Block {
                insts: vec![inst(InstKind::Assign(1, Rvalue::Call(1, Vec::new())))],
                term: ret0(),
            }],
        ),
        "argumentos",
    );
    // Field projection on an Int.
    expect_error(
        int_func(
            vec![int, int],
            vec![Block {
                insts: vec![inst(InstKind::Assign(
                    1,
                    Rvalue::Read(Place {
                        var: 0,
                        proj: vec![Proj::Field(0)],
                    }),
                ))],
                term: ret0(),
            }],
        ),
        "proyección",
    );
    // Variable read on a path where it was never assigned.
    expect_error(
        int_func(
            vec![int, int],
            vec![
                Block {
                    insts: Vec::new(),
                    term: Some(Terminator::Branch(Operand::Const(Const::Bool(true)), 1, 2)),
                },
                Block {
                    insts: vec![inst(InstKind::Assign(1, Rvalue::Use(Operand::Var(0))))],
                    term: Some(Terminator::Jump(2)),
                },
                Block {
                    insts: Vec::new(),
                    term: Some(Terminator::Return(Operand::Var(1))),
                },
            ],
        ),
        "antes de asignarse",
    );
    // Printing a value that has no textual form.
    expect_error(
        int_func(
            vec![int],
            vec![Block {
                insts: vec![inst(InstKind::Print(Arg::Value(Operand::Const(
                    Const::Unit,
                ))))],
                term: ret0(),
            }],
        ),
        "no se puede formatear",
    );
}

#[test]
fn verifier_requires_main() {
    let mut m = module_with(int_func(
        vec![VarTy::Value(Type::Int)],
        vec![Block::default()],
    ));
    m.main = 5;
    assert!(cfg::verify(&m).unwrap_err().message.contains("main"));
}

// ------------------------------------------------------------ ownership/drops --

fn text_func(vars: Vec<VarTy>, blocks: Vec<Block>) -> Func {
    Func {
        name: "g".into(),
        params: Vec::new(),
        vars,
        result: Type::Unit,
        borrow_return: None,
        view_return: None,
        blocks,
    }
}
fn text_value() -> Rvalue {
    Rvalue::TextBuffer(4)
}
fn ret_unit() -> Option<Terminator> {
    Some(Terminator::Return(Operand::Const(Const::Unit)))
}

#[test]
fn ownership_verifier_rejects_unsafe_lir() {
    let text = VarTy::Value(Type::Text);
    let cases: Vec<(Vec<InstKind>, &str)> = vec![
        // Use after move.
        (
            vec![
                InstKind::Assign(0, text_value()),
                InstKind::Assign(1, Rvalue::Use(Operand::Var(0))),
                InstKind::Print(Arg::Value(Operand::Var(0))),
                InstKind::Drop(1, None),
            ],
            "uso tras movimiento",
        ),
        // Double free.
        (
            vec![
                InstKind::Assign(0, text_value()),
                InstKind::Drop(0, None),
                InstKind::Drop(0, None),
            ],
            "doble liberación",
        ),
        // Overwrite without releasing the previous value.
        (
            vec![
                InstKind::Assign(0, text_value()),
                InstKind::Assign(0, text_value()),
                InstKind::Drop(0, None),
            ],
            "fuga por sobrescritura",
        ),
        // Still owning a value at return.
        (vec![InstKind::Assign(0, text_value())], "al retornar: fuga"),
        // Drop of a value that was never assigned.
        (vec![InstKind::Drop(0, None)], "doble liberación"),
    ];
    for (insts, cause) in cases {
        let f = text_func(
            vec![text, text],
            vec![Block {
                insts: insts.into_iter().map(inst).collect(),
                term: ret_unit(),
            }],
        );
        let e = verify(&module_with(f)).expect_err(cause);
        assert!(e.message.contains(cause), "{cause}: {e:?}");
    }
    // A conditional move followed by a flag-guarded drop is accepted.
    let flag = VarTy::Value(Type::Bool);
    let f = text_func(
        vec![text, text, flag],
        vec![
            Block {
                insts: vec![
                    inst(InstKind::Assign(
                        2,
                        Rvalue::Use(Operand::Const(Const::Bool(false))),
                    )),
                    inst(InstKind::Assign(0, text_value())),
                    inst(InstKind::Assign(
                        2,
                        Rvalue::Use(Operand::Const(Const::Bool(true))),
                    )),
                ],
                term: Some(Terminator::Branch(Operand::Const(Const::Bool(true)), 1, 2)),
            },
            Block {
                insts: vec![
                    inst(InstKind::Assign(1, Rvalue::Use(Operand::Var(0)))),
                    inst(InstKind::Assign(
                        2,
                        Rvalue::Use(Operand::Const(Const::Bool(false))),
                    )),
                    inst(InstKind::Drop(1, None)),
                ],
                term: Some(Terminator::Jump(2)),
            },
            Block {
                insts: vec![inst(InstKind::Drop(0, Some(2)))],
                term: ret_unit(),
            },
        ],
    );
    verify(&module_with(f)).unwrap();
}

fn drops_of(f: &Func) -> (usize, usize) {
    let insts = f.blocks.iter().flat_map(|b| &b.insts);
    let mut plain = 0;
    let mut flagged = 0;
    for i in insts {
        match i.kind {
            InstKind::Drop(_, None) => plain += 1,
            InstKind::Drop(_, Some(_)) => flagged += 1,
            _ => {}
        }
    }
    (plain, flagged)
}

#[test]
fn elaboration_removes_drops_of_moved_values_and_flags_uncertain_ones() {
    // Moved on every path: no drop of `a` survives, only of `b`.
    let m = lower("fn main() {\n let n = 1\n let a = \"{n}\"\n let b = a\n print(b)\n}");
    assert_eq!(drops_of(&m.funcs[m.main]), (1, 0));
    // Moved only on one branch: the scope-end drop needs a flag.
    let m = lower(
        "fn f(t: Text) {}\nfn main() {\n let n = 1\n let a = \"{n}\"\n if n > 0 { f(a) }\n print(n)\n}",
    );
    let main = &m.funcs[m.main];
    assert_eq!(drops_of(main).1, 1, "{main:#?}");
    // Never moved: plain drop at scope end, no flag.
    let m = lower("fn main() {\n let n = 1\n let a = \"{n}\"\n print(a)\n}");
    assert_eq!(drops_of(&m.funcs[m.main]), (1, 0));
    // Static-only programs still get drops (a no-op at run time for cap == 0).
    let m = lower("fn main() {\n let a = \"x\"\n print(a)\n}");
    assert_eq!(drops_of(&m.funcs[m.main]), (1, 0));
    // A reassigned `var` drops its previous value before the store.
    let m = lower("fn main() {\n let n = 1\n var a = \"{n}\"\n a = \"{n}{n}\"\n print(a)\n}");
    let main = &m.funcs[m.main];
    let insts: Vec<&InstKind> = main
        .blocks
        .iter()
        .flat_map(|b| &b.insts)
        .map(|i| &i.kind)
        .collect();
    let pos = insts
        .iter()
        .position(|k| matches!(k, InstKind::Drop(_, None)))
        .unwrap();
    assert!(
        matches!(insts[pos + 1], InstKind::Assign(_, Rvalue::Use(_))),
        "{insts:#?}"
    );
    // Early return drops what the function still owns, then returns.
    let m = lower(
        "fn f(n: Int) -> Int {\n let a = \"{n}\"\n if n > 0 {\n  return 1\n }\n print(a)\n return 0\n}\nfn main() {}",
    );
    let f = &m.funcs[0];
    let returning: Vec<&Block> = f
        .blocks
        .iter()
        .filter(|b| matches!(b.term, Some(Terminator::Return(_))) && !b.insts.is_empty())
        .collect();
    assert!(
        returning
            .iter()
            .all(|b| b.insts.iter().any(|i| matches!(i.kind, InstKind::Drop(..))))
    );
}

#[test]
fn projected_drops_are_verified_and_conditional_per_field() {
    let source = "struct P { a: Text, b: Text }\nfn eat(t: Text) {}\nfn main() { let p = P(a: \"a\", b: \"b\")\n if true { eat(p.a) }\n print(0) }";
    let module = lower(source);
    let drops: Vec<_> = module.funcs[module.main]
        .blocks
        .iter()
        .flat_map(|b| &b.insts)
        .filter_map(|i| match &i.kind {
            InstKind::DropField(p, flag) => Some((p, flag)),
            _ => None,
        })
        .collect();
    assert_eq!(drops.len(), 2, "{drops:#?}");
    assert_eq!(drops.iter().filter(|(_, f)| f.is_some()).count(), 1);
    let mut module = lower(
        "struct P { a: Text, b: Text }\nfn main() { let p = P(a: \"a\", b: \"b\")\n let a = p.a\n print(a) }",
    );
    let block = module.funcs[module.main]
        .blocks
        .iter_mut()
        .find(|b| {
            b.insts
                .iter()
                .any(|i| matches!(i.kind, InstKind::DropField(..)))
        })
        .unwrap();
    let index = block
        .insts
        .iter()
        .position(|i| matches!(i.kind, InstKind::DropField(..)))
        .unwrap();
    let duplicate = block.insts[index].clone();
    block.insts.insert(index, duplicate);
    assert!(
        verify(&module).is_err(),
        "double projected drop must be rejected"
    );
}

#[test]
fn verifier_rejects_mismatched_async_resume_target() {
    let mut m = lower(
        r#"async fn main() {
    let t = "vivo"
    await yieldNow()
    print(t)
}"#,
    );
    let info = m
        .futures
        .iter()
        .find(|info| !info.owned_slots.is_empty())
        .unwrap();
    let poll = &mut m.funcs[info.poll];
    let suspend = poll
        .blocks
        .iter_mut()
        .find(|b| matches!(b.term, Some(Terminator::Suspend(_))))
        .unwrap();
    suspend.term = Some(Terminator::Suspend(1));
    let err = verify(&m).expect_err("se cambió el destino lógico sin cambiar el índice guardado");
    assert!(err.message.contains("índice guardado"), "{err:?}");
}

#[test]
fn verifier_rejects_reading_moved_async_text_after_resume() {
    let mut m = lower(
        r#"async fn main() {
    let texto = "vivo"
    let otro = texto
    await yieldNow()
    print(otro)
}"#,
    );
    let info = m
        .futures
        .iter()
        .find(|info| !info.owned_slots.is_empty())
        .unwrap();
    let fields: Vec<_> = m.structs[info.state]
        .fields
        .iter()
        .enumerate()
        .filter_map(|(i, (_, ty))| (*ty == Type::Enum(info.owned_slots[0].tag)).then_some(i))
        .collect();
    assert_eq!(fields.len(), 2);
    let poll = &mut m.funcs[info.poll];
    let state = poll.params[0];
    let mut replaced = false;
    for inst in poll.blocks.iter_mut().flat_map(|b| &mut b.insts) {
        if let InstKind::Print(Arg::Ref(place, _)) = &mut inst.kind
            && place.var == state
            && place.proj == [Proj::Field(fields[1]), Proj::Payload(1, 0)]
        {
            place.proj[0] = Proj::Field(fields[0]);
            replaced = true;
        }
    }
    assert!(replaced);
    let err = verify(&m).expect_err("se leyó una ranura que quedó vacía antes de suspender");
    assert!(
        err.message.contains("ranura propietaria no inicializada"),
        "{err:?}"
    );
}

#[test]
fn verifier_rejects_reading_a_moved_struct_field_after_resume() {
    let mut m = lower(
        r#"struct Datos {
    a: Text
    b: Text
}
async fn main() {
    let datos = Datos(a: "a", b: "b")
    let movido = datos.a
    await yieldNow()
    print(datos.b)
}"#,
    );
    let info = &m.futures[0];
    let field = info.owned_slots[0].field;
    let poll = &mut m.funcs[info.poll];
    let state = poll.params[0];
    let mut changed = false;
    for inst in poll.blocks.iter_mut().flat_map(|block| &mut block.insts) {
        if let InstKind::Print(Arg::Ref(place, _)) = &mut inst.kind
            && place.var == state
            && place.proj == [Proj::Field(field), Proj::Payload(1, 0), Proj::Field(1)]
        {
            place.proj[2] = Proj::Field(0);
            changed = true;
        }
    }
    assert!(changed);
    let err = verify(&m).expect_err("un campo movido no puede leerse tras reanudar");
    assert!(
        err.message.contains("campo propietario no inicializado"),
        "{err:?}"
    );
}

#[test]
fn verifier_checks_the_constructors_initial_ownership() {
    let mut m = lower(
        r#"async fn mostrar(texto: Text) {
    await yieldNow()
    print(texto)
}
fn main() {}"#,
    );
    let slot = &mut m.futures[0].owned_slots[0];
    assert!(slot.parameter);
    slot.parameter = false;
    let err = verify(&m).expect_err("la inicialización del constructor contradice la del poll");
    assert!(
        err.message.contains("el constructor no inicializa"),
        "{err:?}"
    );
}

#[test]
fn verifier_rejects_access_to_an_inactive_async_enum_payload() {
    let mut m = lower(
        r#"enum Par {
    A(Text)
    B(Text)
}
async fn main() {
    let p = Par.A("primero")
    await yieldNow()
    match p {
        Par.A(t) => print(t),
        Par.B(t) => print(t),
    }
}"#,
    );
    let info = &m.futures[0];
    let field = info.owned_slots[0].field;
    let poll = &mut m.funcs[info.poll];
    let state = poll.params[0];
    let changed = poll
        .blocks
        .iter_mut()
        .flat_map(|block| &mut block.insts)
        .find_map(|inst| match &mut inst.kind {
            InstKind::Assign(_, Rvalue::Ref(place))
                if place.var == state
                    && place.proj
                        == [Proj::Field(field), Proj::Payload(1, 0), Proj::Payload(0, 0)] =>
            {
                place.proj[2] = Proj::Payload(1, 0);
                Some(())
            }
            _ => None,
        });
    assert!(changed.is_some());
    let err = verify(&m).expect_err("un payload solo existe en su variante activa");
    assert!(
        err.message.contains("sin prueba de variante activa"),
        "{err:?}"
    );
}

#[test]
fn join_lowering_probes_two_distinct_slots_before_extracting_results() {
    let module = lower(
        r#"async fn f(n: Int) -> Int = n
async fn main() {
    let r = await join(spawn f(1), spawn f(2))
    print(r.first)
}"#,
    );
    let poll = module.funcs.iter().find(|f| f.name == "main$poll").unwrap();
    let probes: Vec<_> = poll
        .blocks
        .iter()
        .enumerate()
        .flat_map(|(block, b)| {
            b.insts.iter().filter_map(move |inst| match &inst.kind {
                InstKind::Assign(_, Rvalue::TaskReady(place)) => Some((block, place)),
                _ => None,
            })
        })
        .collect();
    let [(first_block, first), (second_block, second)] = &probes[..] else {
        panic!("join debe consultar ambos handles");
    };
    assert_eq!(first_block, second_block);
    assert_ne!(first, second);
    let extractions: Vec<_> = poll
        .blocks
        .iter()
        .enumerate()
        .flat_map(|(block, b)| {
            b.insts.iter().filter_map(move |inst| match &inst.kind {
                InstKind::Assign(_, Rvalue::TaskState(place)) => Some((block, place)),
                _ => None,
            })
        })
        .collect();
    let [(first_take, taken_first), (second_take, taken_second)] = &extractions[..] else {
        panic!("join debe transferir ambos resultados");
    };
    assert_eq!(first_take, second_take);
    assert_ne!(first_take, first_block);
    assert_eq!([*taken_first, *taken_second], [*first, *second]);
}

#[test]
fn join_all_registers_once_and_reads_only_the_counter_on_resume() {
    let m = lower(
        r#"async fn calcular(n: Int) -> Int = n
async fn main() {
    let xs = await joinAll(List[spawn calcular(1), spawn calcular(2)])
    print(xs[0])
}"#,
    );
    let f = m.funcs.iter().find(|f| f.name == "main$poll").unwrap();
    let blocks_with = |predicate: fn(&Rvalue) -> bool| {
        f.blocks
            .iter()
            .enumerate()
            .flat_map(|(id, block)| {
                block.insts.iter().filter_map(move |inst| match &inst.kind {
                    InstKind::Assign(_, rv) if predicate(rv) => Some(id),
                    _ => None,
                })
            })
            .collect::<Vec<_>>()
    };
    let register = blocks_with(|rv| matches!(rv, Rvalue::GroupRegister(_)));
    let counter = blocks_with(|rv| matches!(rv, Rvalue::GroupPending));
    let resumes: Vec<_> = f
        .blocks
        .iter()
        .filter_map(|b| match b.term {
            Some(Terminator::Suspend(resume)) => Some(resume),
            _ => None,
        })
        .collect();
    assert_eq!(register.len(), 1);
    assert_eq!(counter.len(), 1);
    assert_ne!(register, counter);
    assert_eq!(resumes, counter);
    assert!(blocks_with(|rv| matches!(rv, Rvalue::TaskReady(_))).is_empty());
}
