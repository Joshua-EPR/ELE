take tokens
take ast
take sema_types
take symbols
take flow_cfg
take drops_plan
take lir_build
take lir_finish
take lir_verify
take lir_emit
take lir_write
take lir_builtin_union
take lir_patch
take sema_context
take sema_drop

// Module level of the ELE LIR: index tables, signatures, struct layouts,
// the protocol header, and the per-function finish (splice the drop plan,
// verify, serialize). Only `sema-l --emit-lir` finishes and writes LIR.

expose flow semaLirSetup(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    each f among 0..tree.fields.length { ctx.lir_field_local@push(-1) }
    change functions = 0
    change structs = 0
    each d among 0..tree.declarations.length {
        ctx.lir_func_index@push(-1)
        ctx.lir_struct_index@push(-1)
        hold decl = view tree.declarations[d]
        choose decl.kind {
            AstDeclKind.Function : {
                ctx.lir_func_index[d] = functions
                hold main_name = "main"
                when symbolNameEqualsText(source, decl.a, decl.b, main_name) { ctx.lir_main = functions }
                functions += 1
            }
            AstDeclKind.Struct : {
                ctx.current_module = semaDeclModule(ctx, d)
                ctx.lir_struct_index[d] = structs
                each f among decl.c..(decl.c + decl.d) { ctx.lir_field_local[f] = f - decl.c }
                ctx.lir_module.st_first@push(ctx.lir_module.field_ty.length)
                ctx.lir_module.st_count@push(decl.d)
                ctx.lir_module.st_decl@push(d)
                each f among decl.c..(decl.c + decl.d) {
                    hold ty = semaFieldType(edit ctx, source, tree, f)
                    ctx.lir_module.field_ty@push(ty)
                }
                structs += 1
            }
            AstDeclKind.Enum : {
                ctx.current_module = semaDeclModule(ctx, d)
                ctx.lir_module.en_decl@push(d)
                ctx.lir_module.en_builtin@push(-1)
                ctx.lir_module.en_first@push(ctx.lir_module.variant_payload.length)
                ctx.lir_module.en_count@push(decl.d)
                change has_payload = false
                each v among decl.c..(decl.c + decl.d) {
                    hold n = tree.variants[v].payload_count
                    ctx.lir_module.variant_payload@push(n)
                    change payload_ty = 6
                    when n > 0 {
                        payload_ty = semaResolveAstType(edit ctx, source, tree, tree.extra[tree.variants[v].first_payload_index])
                        has_payload = true
                    }
                    ctx.lir_module.variant_type@push(payload_ty)
                }
                when !has_payload { ctx.lir_module.unit_enums@push(d) }
            }
            _ : {}
        }
    }
    each d among 0..tree.declarations.length {
        hold decl = view tree.declarations[d]
        choose decl.kind {
            AstDeclKind.Function : { semaLirSignature(edit ctx, source, tree, d) }
            _ : {}
        }
    }
    // Signatures have resolved their concrete generic types. Newly inferred
    // Option/Result types are additionally registered as expressions lower.
    each t among 8..ctx.types.types.length {
        lirBuiltinRegister(edit ctx.lir_module, view ctx.types, t)
    }
    each t among 8..ctx.types.types.length {
        choose ctx.types.types[t].kind {
            SemTypeKind.List : {
                hold elem = ctx.types.types[t].elem_type
                change found = false
                each k among 0..ctx.lir_module.list_elem.length {
                    when ctx.lir_module.list_elem[k] == elem { found = true }
                }
                when !found {
                    ctx.lir_module.list_elem@push(elem)
                }
            }
            _ : {}
        }
    }
}

expose flow semaLirComplete(ctx: edit SemaContext, source: view Text, tree: view AstTree) {
    when !ctx.emit_lir || ctx.errors.length > 0 { give }
    // Determine header function count before taking a mutable loan of ctx.
    hold function_count = ctx.lir_module.fn_first.length
    semaLirHeader(edit ctx, source, tree, function_count)
}

flow semaLirSignature(ctx: edit SemaContext, source: view Text, tree: view AstTree, d: Int) {
    ctx.current_module = semaDeclModule(ctx, d)
    hold decl = view tree.declarations[d]
    ctx.lir_module.fn_first@push(ctx.lir_module.param_ty.length)
    ctx.lir_module.fn_count@push(decl.e)
    ctx.lir_module.fn_decl@push(d)
    each p among 0..decl.e {
        hold ty = semaResolveAstType(edit ctx, source, tree, tree.params[decl.d + p].type_id)
        hold elem = semaRefElem(ctx, ty)
        when elem >= 0 {
            ctx.lir_module.param_ty@push(elem)
        } otherwise {
            ctx.lir_module.param_ty@push(ty)
        }
        ctx.lir_module.param_ref@push(elem >= 0)
        ctx.lir_module.param_mut@push(semaIsMutRef(ctx, ty))
    }
    change ret = 6
    when decl.f >= 0 { ret = semaResolveAstType(edit ctx, source, tree, decl.f) }
    hold elem = semaRefElem(ctx, ret)
    ctx.lir_module.fn_ret_ref@push(elem >= 0)
    ctx.lir_module.fn_ret_mut@push(semaIsMutRef(ctx, ret))
    when elem >= 0 { ret = elem }
    ctx.lir_module.fn_ret@push(ret)
}

flow semaLirHeader(ctx: edit SemaContext, source: view Text, tree: view AstTree, functions: Int) {
    hold structs = ctx.lir_module.st_decl.length
    hold enums = ctx.lir_module.en_decl.length
    hold lists = ctx.lir_module.list_elem.length
    hold main = ctx.lir_main
    ctx.lir_lines@push("ELE-LIR 1")
    change header = "module structs {structs}"
    when enums > 0 { header = "{header} enums {enums}" }
    when lists > 0 { header = "{header} lists {lists}" }
    ctx.lir_lines@push("{header} funcs {functions} main f{main}")
    each k among 0..structs {
        hold decl = view tree.declarations[ctx.lir_module.st_decl[k]]
        hold name = lirSpanText(source, decl.a, decl.b)
        hold count = decl.d
        ctx.lir_lines@push("struct s{k} {name} fields {count}")
        each f among decl.c..(decl.c + decl.d) {
            hold field_name = lirSpanText(source, tree.fields[f].name_start, tree.fields[f].name_end)
            hold ty = lirTypeCode(view ctx.types, view ctx.lir_module, ctx.lir_module.field_ty[ctx.lir_module.st_first[k] + f - decl.c])
            ctx.lir_lines@push("field {field_name} {ty}")
        }
    }
    each k among 0..enums {
        when ctx.lir_module.en_builtin[k] >= 0 {
            hold first_variant = ctx.lir_module.en_first[k]
            hold first_code = lirTypeCode(view ctx.types, view ctx.lir_module, ctx.lir_module.variant_type[first_variant])
            hold second_code = lirTypeCode(view ctx.types, view ctx.lir_module, ctx.lir_module.variant_type[first_variant + 1])
            // An owned payload (e.g. a list type never registered) must have
            // a concrete LIR type code; `?` is never serialized.
            hold unit_first = ctx.lir_module.variant_payload[first_variant] == 0
            when (!unit_first && first_code.byteLength == 1 && first_code@byteAt(0) == 63) || (second_code.byteLength == 1 && second_code@byteAt(0) == 63) {
                semaAddError(edit ctx, "L0016", "payload de Option/Result no representable en ELE-LIR 1", 0, 0)
            }
            lirBuiltinHeader(edit ctx, k, first_code, second_code)
            proceed
        }
        hold d = ctx.lir_module.en_decl[k]
        ctx.current_module = semaDeclModule(ctx, d)
        hold decl = view tree.declarations[d]
        hold name = lirSpanText(source, decl.a, decl.b)
        hold count = decl.d
        ctx.lir_lines@push("enum e{k} {name} variants {count}")
        each v among decl.c..(decl.c + decl.d) {
            hold variant = view tree.variants[v]
            hold vname = lirSpanText(source, variant.name_start, variant.name_end)
            hold payload_count = variant.payload_count
            change line = "variant {vname} types {payload_count}"
            each i among 0..payload_count {
                hold ty = semaResolveAstType(edit ctx, source, tree, tree.extra[variant.first_payload_index + i])
                hold code = lirTypeCode(view ctx.types, view ctx.lir_module, ty)
                when code.byteLength == 1 && code@byteAt(0) == 63 {
                    semaAddError(edit ctx, "L0016", "payload de enum no representable en ELE-LIR 1", variant.start, variant.end)
                }
                line = "{line} {code}"
            }
            ctx.lir_lines@push(line)
        }
    }
    each k among 0..lists {
        hold elem_t = ctx.lir_module.list_elem[k]
        hold elem_ty = lirTypeCode(view ctx.types, view ctx.lir_module, elem_t)
        ctx.lir_lines@push("list l{k} {elem_ty}")
    }
}

// Is every variable, signature and field type representable in LIR v1?
flow semaLirTypesOk(ctx: view SemaContext, fn_index: Int) => Bool {
    each i among 0..ctx.lir.vars.length {
        hold code = lirTypeCode(view ctx.types, view ctx.lir_module, ctx.lir.vars[i].ty)
        when code.byteLength == 1 && code@byteAt(0) == 63 { give false }
    }
    each i among 0..ctx.lir_module.field_ty.length {
        hold code = lirTypeCode(view ctx.types, view ctx.lir_module, ctx.lir_module.field_ty[i])
        when code.byteLength == 1 && code@byteAt(0) == 63 { give false }
    }
    give true
}

expose flow semaLirFinish(ctx: edit SemaContext, source: view Text, tree: view AstTree, plan: view DropPlan, d: Int) {
    when !ctx.emit_lir { give }
    hold decl = view tree.declarations[d]
    hold fn_index = ctx.lir_func_index[d]
    when ctx.lir.unsupported >= 0 || !semaLirTypesOk(ctx, fn_index) {
        change at = decl.start
        when ctx.lir.unsupported >= 0 { at = ctx.lir.unsupported }
        semaAddError(edit ctx, "L0016", "construcción fuera del subconjunto de la LIR v1 de ELE", at, at)
        give
    }
    change body = lirFinish(edit ctx.lir, view ctx.flow, plan, view ctx.lir_field_local)
    when ctx.lir_fault > 0 && ctx.lir_fault < 14 { lirInjectFault(edit ctx.lir, edit body, ctx.lir_fault) }
    when ctx.lir_fault >= 14 { lirInjectUnionFault(edit ctx.lir, edit body, view ctx.types, view ctx.lir_module, view ctx.drop_memo, ctx.lir_fault) }
    when ctx.lir_patch.byteLength > 0 {
        hold bad = lirApplyPatch(edit ctx.lir, edit body, view ctx.lir_patch, fn_index)
        when bad != 0 {
            semaAddError(edit ctx, "ICE", "error interno del compilador: parche de LIR inválido (línea {bad})", decl.start, decl.end)
            give
        }
    }
    hold checked = lirVerify(view ctx.lir, view body, view ctx.types, view ctx.lir_module, view ctx.drop_memo, fn_index)
    when checked.status != 0 {
        hold rule = checked.status
        hold block = checked.block
        semaAddError(edit ctx, "ICE", "error interno del compilador: LIR inválida (regla {rule}, bloque {block})", decl.start, decl.end)
        give
    }
    ctx.lir_insts += body.order.length
    ctx.lir_blocks += body.term.length
    when ctx.lir_line_starts.length == 0 { ctx.lir_line_starts = lirLineStarts(source) }
    lirWriteFunction(edit ctx.lir_functions, view ctx.lir_line_starts, view ctx.lir, view body, source, view ctx.types, view ctx.lir_module, fn_index, decl.a, decl.b)
}

// Test hook (`sema-l archivo.l --lir-fault=K`): corrupt a verified
// function in one defined way so the tests can prove the verifier rejects
// it. 1 variable id, 2 block id, 3 operand type, 4 use before assignment,
// 5 call arity, 6 drop of a non-owned value, 7 return type, 8 field index.
// 9 invalid platform opcode, 10 platform arity, 11 argument loan mode,
// 12 platform result type, 13 invalid platform argument id.
// Owned unions (#5): 14 owned payload read from the other variant (rule 3),
// 15 conditional drop of a maybe-moved union made unconditional (rule 6),
// 16 a use after an owned payload consumed its union (rule 5),
// 17 drop flag forged to cb1 after move-out (double free, rule 6),
// 18 drop flag forged to cb0 when owned (leak, rule 6).
flow lirInjectUnionFault(l: edit LirFn, body: edit LirBody, types: view TypeTable, lm: view LirModule, drop_memo: view List of[Int], fault: Int) {
    each n among 0..body.order.length {
        hold id = body.order[n]
        hold kind = l.insts[id].kind
        hold dst = l.insts[id].dst
        when kind == LIR_DROP && fault == 15 && l.insts[id].a >= 0 && dst >= 0 && dst < l.vars.length {
            hold ty = l.vars[dst].ty
            when ty >= 0 && ty < types.types.length {
                change union = false
                choose types.types[ty].kind {
                    SemTypeKind.Option : { union = true }
                    SemTypeKind.Result : { union = true }
                    _ : {}
                }
                when union {
                    l.insts[id].a = -1
                    give
                }
            }
        }
        hold is_payload = kind == LIR_PAYLOAD && dst >= 0 && dst < l.vars.length && lirBuiltinPayloadOwned(types, lm, l.vars[dst].ty)
        hold is_read_field = kind == LIR_READ && dst >= 0 && dst < l.vars.length && l.vars[dst].ty >= 0 && l.vars[dst].ty < drop_memo.length && drop_memo[l.vars[dst].ty] == 2
        when is_payload || is_read_field {
            when fault == 14 && is_payload {
                l.insts[id].c = 1 - l.insts[id].c
                give
            }
            when fault == 16 && is_payload {
                hold root = l.places[l.insts[id].a].root
                hold block = l.insts[id].block
                each m among (n + 1)..body.order.length {
                    hold later = body.order[m]
                    when l.insts[later].block == block && l.insts[later].kind == LIR_USE {
                        hold ldst = l.insts[later].dst
                        when ldst >= 0 && ldst < l.vars.length && l.vars[ldst].ty == 4 {
                            proceed
                        }
                        // Well-typed copy of the consumed union into a fresh variable.
                        hold union_ty = l.vars[root].ty
                        hold copy = lirVar(edit l, union_ty, false)
                        l.insts[later].dst = copy
                        l.insts[later].a = root
                        give
                    }
                }
            }
            when fault == 17 {
                // Double free: drop flag forged to cb1 after payload move-out.
                hold block = l.insts[id].block
                each m among (n + 1)..body.order.length {
                    hold later = body.order[m]
                    when l.insts[later].block == block && l.insts[later].kind == LIR_USE {
                        hold ldst = l.insts[later].dst
                        when ldst >= 0 && ldst < l.vars.length && l.vars[ldst].ty == 4 {
                            l.insts[later].a = lirConst(edit l, LIR_CONST_BOOL, 1, 0, 0)
                            give
                        }
                    }
                }
            }
        }
        when fault == 18 && kind == LIR_USE && dst >= 0 && dst < l.vars.length && l.vars[dst].ty == 4 {
            // Leak: drop flag forged to cb0 when owned.
            hold operand = l.insts[id].a
            when !lirIsVar(operand) {
                hold cid = lirConstId(operand)
                when cid >= 0 && cid < l.consts.length && l.consts[cid].kind == LIR_CONST_BOOL && l.consts[cid].value == 1 {
                    l.insts[id].a = lirConst(edit l, LIR_CONST_BOOL, 0, 0, 0)
                    give
                }
            }
        }
    }
}

flow lirInjectFault(l: edit LirFn, body: edit LirBody, fault: Int) {
    each n among 0..body.order.length {
        hold id = body.order[n]
        hold kind = l.insts[id].kind
        when fault == 1 && kind == LIR_USE {
            l.insts[id].dst = l.vars.length + 3
            give
        }
        when fault == 3 && kind == LIR_BINARY {
            l.insts[id].c = lirConst(edit l, LIR_CONST_BOOL, 1, 0, 0)
            give
        }
        when fault == 5 && kind == LIR_CALL {
            l.insts[id].c = l.insts[id].c + 1
            give
        }
        when fault == 6 && kind == LIR_DROP {
            l.insts[id].dst = lirVar(edit l, 1, false)
            give
        }
        when kind == LIR_PLATFORM {
            when fault == 9 { l.insts[id].a = 99; give }
            when fault == 10 { l.insts[id].c += 1; give }
            when fault == 11 && l.insts[id].c > 0 {
                hold first = l.insts[id].b
                hold arg = l.operands[first]
                l.args[arg].by_ref = false
                give
            }
            when fault == 12 {
                l.vars[l.insts[id].dst].ty = 4
                give
            }
            when fault == 13 && l.insts[id].c > 0 {
                hold first = l.insts[id].b
                l.operands[first] = l.args.length + 1
                give
            }
        }
        when fault == 8 && (kind == LIR_READ || kind == LIR_STORE) && l.places[l.insts[id].a].parent >= 0 {
            l.places[l.insts[id].a].field = 99
            give
        }
    }
    when fault == 4 {
        // Use a fresh, never assigned variable as the first operand read.
        hold fresh = lirVar(edit l, 1, false)
        each n among 0..body.order.length {
            hold id = body.order[n]
            when l.insts[id].kind == LIR_BINARY {
                l.insts[id].b = fresh
                give
            }
        }
    }
    each b among 0..body.term.length {
        when fault == 2 && (body.term[b] == LIR_T_JUMP || body.term[b] == LIR_T_BRANCH) {
            body.ta[b] = body.term.length + 5
            give
        }
        when fault == 7 && body.term[b] == LIR_T_RETURN {
            body.top[b] = lirConst(edit l, LIR_CONST_BOOL, 0, 0, 0)
            give
        }
    }
}
