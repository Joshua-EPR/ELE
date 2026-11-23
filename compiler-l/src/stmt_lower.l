take tokens
take ast
take sema_types
take symbols
take scopes
take flow_cfg
take lir_build
take sema_context
take sema_drop
take sema_lower
take lir_builtin_union

// Statement lowering helpers for the semantic pass (sema_stmt.l). They run
// right after the statement's CFG events, so the instructions they emit sit
// after those events and the drop plan can be spliced around them.

// `let name = value` after FLOW_INIT: a reference binding names the
// reference variable produced by the initializer; any other binding gets
// its own variable assigned from the value.
expose flow lirLetBind(ctx: edit SemaContext, path: Int, ty: Int, reference: Bool) {
    hold value = lirTakeOperand(edit ctx, ty)
    when reference && lirIsVar(value) {
        lirBindPath(edit ctx.lir, path, value)
        give
    }
    hold slot = lirVar(edit ctx.lir, ty, false)
    lirBindPath(edit ctx.lir, path, slot)
    lirAt(edit ctx, LIR_USE, slot, value, 0, 0)
}

// `target = value` / `target op= value` after FLOW_WRITE.
expose flow lirAssign(ctx: edit SemaContext, source: view Text, place: Int, value: Int, ty: Int, op_start: Int, op_end: Int) {
    when place < 0 { give }
    change result = value
    when op_end - op_start > 1 {
        ctx.lir.place = place
        hold current = lirTakeOperand(edit ctx, ty)
        hold op = lirBinaryOp(source, op_start, op_start + 1)
        result = lirNew(edit ctx, ty, false, LIR_BINARY, op, current, value)
    }
    lirWrite(edit ctx, place, result)
}

// Branch condition of the current block (if, while, for).
expose flow lirCondition(ctx: edit SemaContext) {
    hold operand = lirTakeOperand(edit ctx, 4)
    // End the block-count read before lending the LIR mutably.
    hold block_count = ctx.flow.blocks.length
    lirBlocks(edit ctx.lir, block_count)
    ctx.lir.cond[ctx.flow.current] = operand
}

// Return value of the current block, recorded before it is detached.
expose flow lirReturnAt(ctx: edit SemaContext, value: Int, reference: Bool) {
    // End the block-count read before lending the LIR mutably.
    hold block_count = ctx.flow.blocks.length
    lirBlocks(edit ctx.lir, block_count)
    change operand = value
    when operand == LIR_NONE { operand = lirConst(edit ctx.lir, LIR_CONST_UNIT, 0, 0, 0) }
    ctx.lir.ret[ctx.flow.current] = operand
    ctx.lir.ret_ref[ctx.flow.current] = reference
}

// Forget whatever a discarded expression left in the value channel.
expose flow lirDiscard(ctx: edit SemaContext) {
    ctx.lir.place = -1
    ctx.lir.val = LIR_NONE
}

// `for i in start..end`: counter and limit are evaluated once; the header
// tests `counter < limit`, the body binds `i`, and the step block (also the
// target of `continue`) increments the counter.
expose flow lirForInit(ctx: edit SemaContext, start: Int, end: Int) => Int {
    // The limit variable is always the one right after the counter.
    hold counter = lirNew(edit ctx, 1, false, LIR_USE, start, 0, 0)
    lirNew(edit ctx, 1, false, LIR_USE, end, 0, 0)
    give counter
}

expose flow lirForTest(ctx: edit SemaContext, counter: Int) {
    // Do not mutate the value channel while constructing its operand.
    hold comparison = lirNew(edit ctx, 4, false, LIR_BINARY, LIR_LT, counter, counter + 1)
    ctx.lir.val = comparison
    ctx.lir.place = -1
    lirCondition(edit ctx)
}

expose flow lirForStep(ctx: edit SemaContext, counter: Int) {
    hold one = lirConst(edit ctx.lir, LIR_CONST_INT, 1, 0, 0)
    hold next = lirNew(edit ctx, 1, false, LIR_BINARY, LIR_ADD, counter, one)
    lirAt(edit ctx, LIR_USE, counter, next, 0, 0)
}

expose flow lirMatchScrutVar(ctx: edit SemaContext, scrut_t: Int) => Int {
    hold scrut_op = lirTakeOperand(edit ctx, scrut_t)
    when lirIsVar(scrut_op) { give scrut_op }
    hold v = lirVar(edit ctx.lir, scrut_t, false)
    lirAt(edit ctx, LIR_USE, v, scrut_op, 0, 0)
    give v
}

expose flow lirMatchArmTest(ctx: edit SemaContext, source: view Text, tree: view AstTree, p_start: Int, p_end: Int, scrut_var: Int, scrut_t: Int, arm_body: Int, next_test: Int, is_last: Bool) => Bool {
    // A wildcard needs no discriminant or payload binding. A proven final
    // named arm is handled by its type-specific branch below: builtin
    // Option/Result arms must still bind their payloads before entry.
    when p_end - p_start == 1 && source@byteAt(p_start) == 95 {
        flowLink(edit ctx.flow, arm_body, -1)
        give true
    }
    change enum_decl = -1
    change elem_t = -1
    change is_option = false
    change is_result = false
    when scrut_t >= 0 && scrut_t < ctx.types.types.length {
        hold st = view ctx.types.types[scrut_t]
        choose st.kind {
            SemTypeKind.Enum : { enum_decl = st.nominal_id }
            SemTypeKind.Option : {
                is_option = true
                elem_t = st.elem_type
            }
            SemTypeKind.Result : {
                is_result = true
                elem_t = st.elem_type
            }
            _ : {}
        }
    }
    hold name_none = "None"
    when is_option || is_result {
        hold builtin_id = lirBuiltinRegister(edit ctx.lir_module, view ctx.types, scrut_t)
        when builtin_id < 0 { lirMarkUnsupported(edit ctx.lir, p_start) }
        change disc = -1
        when is_option && symbolNameEqualsText(source, p_start, p_end, name_none) {
            disc = 0
        } otherwise when is_option && (p_end - p_start > 6) && source@byteAt(p_start) == 83 && source@byteAt(p_start + 1) == 111 && source@byteAt(p_start + 2) == 109 && source@byteAt(p_start + 3) == 101 && source@byteAt(p_start + 4) == 40 {
            disc = 1
        } otherwise when is_result && (p_end - p_start > 4) && source@byteAt(p_start) == 79 && source@byteAt(p_start + 1) == 107 && source@byteAt(p_start + 2) == 40 {
            disc = 0
        } otherwise when is_result && (p_end - p_start > 5) && source@byteAt(p_start) == 69 && source@byteAt(p_start + 1) == 114 && source@byteAt(p_start + 2) == 114 && source@byteAt(p_start + 3) == 40 {
            disc = 1
        }
        when disc >= 0 {
            when is_last {
                // Final named arm is unconditional only after strict coverage
                // proof. Its payload is read inside that arm, not here.
                flowLink(edit ctx.flow, arm_body, -1)
            } otherwise {
                hold place = lirPlaceVar(edit ctx.lir, scrut_var)
                hold tag = lirNew(edit ctx, 1, false, LIR_DISC, place, 0, 0)
                hold target = lirConst(edit ctx.lir, LIR_CONST_INT, disc, 0, 0)
                hold cond = lirNew(edit ctx, 4, false, LIR_BINARY, LIR_EQ, tag, target)
                ctx.lir.val = cond
                ctx.lir.place = -1
                lirCondition(edit ctx)
                flowLink(edit ctx.flow, arm_body, next_test)
            }
            give is_last
        }
        lirMarkUnsupported(edit ctx.lir, p_start)
    }
    // Only the strict nominal-enum coverage proof may promote a final
    // named variant to an unconditional arm (its payload binds separately).
    when is_last && enum_decl >= 0 {
        flowLink(edit ctx.flow, arm_body, -1)
        give true
    }
    when enum_decl >= 0 && enum_decl < tree.declarations.length {
        hold decl = view tree.declarations[enum_decl]
        change variant_idx = -1
        change var_start = p_start
        change var_end = p_end
        each c among p_start..p_end {
            when source@byteAt(c) == 40 && var_end == p_end { var_end = c }
            when source@byteAt(c) == 46 && c < var_end { var_start = c + 1 }
        }
        each v among 0..decl.d {
            hold variant = view tree.variants[decl.c + v]
            when symbolNamesEqual(source, variant.name_start, variant.name_end, var_start, var_end) {
                variant_idx = v
            }
        }
        when variant_idx >= 0 {
            hold variant = view tree.variants[decl.c + variant_idx]
            when variant.payload_count > 1 { lirMarkUnsupported(edit ctx.lir, p_start) }
            hold scrut_place = lirPlaceVar(edit ctx.lir, scrut_var)
            hold disc_var = lirNew(edit ctx, 1, false, LIR_DISC, scrut_place, 0, 0)
            hold disc_const = lirConst(edit ctx.lir, LIR_CONST_INT, variant_idx, 0, 0)
            hold cond = lirNew(edit ctx, 4, false, LIR_BINARY, LIR_EQ, disc_var, disc_const)
            ctx.lir.val = cond
            ctx.lir.place = -1
            lirCondition(edit ctx)
            flowLink(edit ctx.flow, arm_body, next_test)
            give false
        }
    }
    when enum_decl >= 0 { lirMarkUnsupported(edit ctx.lir, p_start) }
    flowLink(edit ctx.flow, arm_body, next_test)
    give false
}

// Bind a payload only in the matching arm. This produces an explicit checked
// `payload` operation, never an unchecked `read` of the enum. Int/Bool are
// copied; any other lowerable payload (lirBuiltinPayloadOk) is moved out of
// the scrutinee, which is consumed. An owned payload (Text, List<T>, nested
// union, owner-bearing shape) becomes an owned binding with its own drop;
// the scrutinee must then be a direct owned variable (semaCheckMatch gives
// temporaries one), so the consumed union is never dropped again.
expose flow lirMatchArmBind(ctx: edit SemaContext, source: view Text, tree: view AstTree, p_start: Int, p_end: Int, scrut_var: Int, scrut_t: Int, scrut_path: Int) {
    when scrut_t < 0 || scrut_t >= ctx.types.types.length { give }
    // Primitive builtin unions reuse the exact checked LIR_PAYLOAD protocol
    // of nominal enums. Never bind before testing the active tag.
    hold st = view ctx.types.types[scrut_t]
    change builtin = false
    change which = -1
    change start = -1
    change payload_ty = -1
    choose st.kind {
        SemTypeKind.Option : {
            builtin = true
            when p_end - p_start > 6 && source@byteAt(p_start) == 83 && source@byteAt(p_start + 4) == 40 {
                which = 1
                start = p_start + 5
                payload_ty = st.elem_type
            }
        }
        SemTypeKind.Result : {
            builtin = true
            when p_end - p_start > 4 && source@byteAt(p_start) == 79 && source@byteAt(p_start + 2) == 40 {
                which = 0
                start = p_start + 3
                payload_ty = st.elem_type
            } otherwise when p_end - p_start > 5 && source@byteAt(p_start) == 69 && source@byteAt(p_start + 3) == 40 {
                which = 1
                start = p_start + 4
                payload_ty = st.nominal_id
            }
        }
        _ : {}
    }
    when builtin {
        when start < 0 { give }
        hold finish = p_end - 1
        when source@byteAt(finish) != 41 { lirMarkUnsupported(edit ctx.lir, p_start); give }
        when finish == start + 1 && source@byteAt(start) == 95 { give }
        // Copyability and drop glue are different properties: Int/Bool copy,
        // but even a drop-free nominal shape/choice MOVES when bound by value.
        // The whole scrutinee is consumed; a second use (or move out of a
        // borrowed scrutinee) is rejected by ownership as L0005.
        // semaNeedsDrop only controls destruction, not the move decision.
        when payload_ty >= 0 && payload_ty < ctx.types.types.length && !lirBuiltinPrimitive(payload_ty) {
            semaAccess(edit ctx, scrut_path, scrut_t, ACCESS_MOVE, start, finish)
            // The examined place stays frozen for the whole arm: assigning
            // it there is rejected like in Stage 0 (semaCheckMatch unfreezes).
            when scrut_path >= 0 && scrut_path < ctx.flow.paths.length && ctx.flow.paths[scrut_path].symbol >= 0 {
                hold frozen = ctx.flow.paths[scrut_path].symbol
                ctx.frozen_symbols@push(frozen)
            }
        }
        // The binding's instructions carry the position of its pattern
        // (the final arm emits no discriminant test of its own).
        ctx.lir.at = p_start
        when !lirBuiltinPayloadOk(view ctx.types, view ctx.lir_module, payload_ty) || !lirBuiltinSupported(view ctx.types, view ctx.lir_module, scrut_t) {
            // Stage 1 ownership must still see the source-level pattern
            // binder for non-native unions (e.g. Result<Int, LexError>).
            // The LIR remains explicitly unsupported: no unchecked payload
            // read, coercion, or fabricated value can reach the backend.
            lirMarkUnsupported(edit ctx.lir, p_start)
            hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Var, start, finish, payload_ty, ctx.scopes.current_scope, false, false, -1, start, finish)
            scopeAddSymbol(edit ctx.scopes, sym_id)
            semaInitPath(edit ctx, sym_id, start, finish)
            give
        }
        hold enum_id = lirBuiltinEnumIndex(view ctx.lir_module, scrut_t)
        when enum_id < 0 { lirMarkUnsupported(edit ctx.lir, p_start); give }
        hold owned = lirBuiltinPayloadOwned(view ctx.types, view ctx.lir_module, payload_ty)
        // Moving an owned payload out needs a tracked, directly owned union.
        when owned && (scrut_path < 0 || scrut_var < 0 || scrut_var >= ctx.lir.vars.length || ctx.lir.vars[scrut_var].is_ref) {
            lirMarkUnsupported(edit ctx.lir, p_start)
        }
        hold place = lirPlaceVar(edit ctx.lir, scrut_var)
        hold value = lirNew(edit ctx, payload_ty, false, LIR_PAYLOAD, place, enum_id, which)
        hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Var, start, finish, payload_ty, ctx.scopes.current_scope, false, false, -1, start, finish)
        scopeAddSymbol(edit ctx.scopes, sym_id)
        semaInitPath(edit ctx, sym_id, start, finish)
        lirSetVal(edit ctx, value)
        // A move-path snapshot must precede the exclusive borrow of ctx.
        hold bind_path = ctx.symbols.symbols[sym_id].move_path
        lirLetBind(edit ctx, bind_path, payload_ty, false)
        // The moved-out payload is an owned binding: dropped at the end of
        // its arm unless moved on (return, call, constructor).
        when owned { semaOwn(edit ctx, source, tree, bind_path, payload_ty, start) }
        give
    }
    choose ctx.types.types[scrut_t].kind {
        SemTypeKind.Enum : {}
        _ : { give }
    }
    hold decl_id = ctx.types.types[scrut_t].nominal_id
    when decl_id < 0 || decl_id >= tree.declarations.length { give }
    hold decl = view tree.declarations[decl_id]
    change open = -1
    change name_start = p_start
    each i among p_start..p_end {
        when source@byteAt(i) == 40 && open < 0 { open = i }
        when source@byteAt(i) == 46 && open < 0 { name_start = i + 1 }
    }
    when open < 0 { give }
    when p_end <= open + 2 || source@byteAt(p_end - 1) != 41 {
        lirMarkUnsupported(edit ctx.lir, p_start)
        give
    }
    hold binding_start = open + 1
    hold binding_end = p_end - 1
    when binding_end == binding_start + 1 && source@byteAt(binding_start) == 95 { give }
    each j among binding_start..binding_end {
        hold b = source@byteAt(j)
        hold letter = (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95
        hold digit = (b >= 48 && b <= 57) && j > binding_start
        when !letter && !digit { lirMarkUnsupported(edit ctx.lir, p_start); give }
    }
    each v among 0..decl.d {
        hold variant = view tree.variants[decl.c + v]
        when !symbolNamesEqual(source, variant.name_start, variant.name_end, name_start, open) { proceed }
        when variant.payload_count != 1 {
            lirMarkUnsupported(edit ctx.lir, p_start)
            give
        }
        hold ty = semaResolveAstType(edit ctx, source, tree, tree.extra[variant.first_payload_index])
        when ty != 1 && ty != 4 {
            lirMarkUnsupported(edit ctx.lir, p_start)
            give
        }
        change enum_id = -1
        each k among 0..ctx.lir_module.en_decl.length {
            when ctx.lir_module.en_decl[k] == decl_id { enum_id = k }
        }
        when enum_id < 0 { lirMarkUnsupported(edit ctx.lir, p_start); give }
        hold place = lirPlaceVar(edit ctx.lir, scrut_var)
        hold value = lirNew(edit ctx, ty, false, LIR_PAYLOAD, place, enum_id, v)
        hold sym_id = symbolAdd(edit ctx.symbols, SymbolKind.Var, binding_start, binding_end, ty, ctx.scopes.current_scope, false, false, -1, binding_start, binding_end)
        scopeAddSymbol(edit ctx.scopes, sym_id)
        semaInitPath(edit ctx, sym_id, binding_start, binding_end)
        lirSetVal(edit ctx, value)
        hold bind_path = ctx.symbols.symbols[sym_id].move_path
        lirLetBind(edit ctx, bind_path, ty, false)
        give
    }
    lirMarkUnsupported(edit ctx.lir, p_start)
}

expose flow semaConstructorField(ctx: edit SemaContext, source: view Text, tree: view AstTree, decl_id: Int, arg: view AstExpr, ty: Int, seen: edit List of[Bool], slots: edit List of[Int]) {
    hold decl = view tree.declarations[decl_id]
    hold field = semaNamedField(source, tree, decl_id, arg)
    when field < 0 || seen[field - decl.c] {
        semaAddError(edit ctx, "L0004", "campo inválido o duplicado en constructor", arg.start, arg.end)
    } otherwise {
        seen[field - decl.c] = true
        slots[field - decl.c] = lirTakeOperand(edit ctx, ty)
        hold expected = semaFieldType(edit ctx, source, tree, field)
        when !semTypeEquals(view ctx.types, ty, expected) {
            semaAddError(edit ctx, "L0004", "tipo incompatible en campo del constructor", arg.start, arg.end)
        }
    }
}

expose flow semaConstructorFinish(ctx: edit SemaContext, tree: view AstTree, expr: view AstExpr, decl_id: Int, struct_t: Int, seen: view List of[Bool], slots: view List of[Int]) {
    hold decl = view tree.declarations[decl_id]
    each i among 0..decl.d {
        when !seen[i] {
            semaAddError(edit ctx, "L0004", "el constructor requiere todos sus campos explícitos", expr.start, expr.end)
            give
        }
    }
    hold first = lirSequence(edit ctx, slots)
    // Preserve slot order and register the completed struct only afterward.
    hold struct_index = ctx.lir_struct_index[decl_id]
    hold value = lirNew(edit ctx, struct_t, false, LIR_STRUCT, struct_index, first, slots.length)
    lirSetVal(edit ctx, value)
}

expose flow semaEnumField(ctx: edit SemaContext, source: view Text, tree: view AstTree, expr: view AstExpr) => Int {
    when expr.a < 0 || expr.a >= tree.expressions.length { give -1 }
    choose tree.expressions[expr.a].kind {
        AstExprKind.Name : {}
        _ : { give -1 }
    }
    hold base_expr = view tree.expressions[expr.a]
    hold sym_id = semaLookupVisible(edit ctx, source, base_expr.start, base_expr.end)
    when sym_id < 0 { give -1 }
    choose ctx.symbols.symbols[sym_id].kind {
        SymbolKind.Enum : {}
        _ : { give -1 }
    }
    hold decl_id = ctx.symbols.symbols[sym_id].decl_id
    when decl_id >= 0 && decl_id < tree.declarations.length {
        hold decl = view tree.declarations[decl_id]
        each v among 0..decl.d {
            hold variant = view tree.variants[decl.c + v]
            when symbolNamesEqual(source, variant.name_start, variant.name_end, expr.b, expr.c) {
                hold ty = ctx.symbols.symbols[sym_id].type_id
                change enum_id = -1
                each k among 0..ctx.lir_module.en_decl.length {
                    when ctx.lir_module.en_decl[k] == decl_id { enum_id = k }
                }
                when enum_id < 0 || variant.payload_count > 0 {
                    // Payload variants require typed construction from their
                    // call arguments, not the unit-variant field syntax.
                    lirMarkUnsupported(edit ctx.lir, expr.start)
                } otherwise {
                    hold result = lirNew(edit ctx, ty, false, LIR_VARIANT, enum_id, v, LIR_NONE)
                    lirSetVal(edit ctx, result)
                }
                give ty
            }
        }
    }
    semaAddError(edit ctx, "L0001", "variante de enum no encontrada", expr.start, expr.end)
    give 7
}
