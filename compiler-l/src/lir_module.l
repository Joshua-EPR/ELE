import tokens
import ast
import sema_types
import symbols
import flow_cfg
import drops_plan
import lir_build
import lir_finish
import lir_verify
import lir_emit
import lir_write
import lir_builtin_union
import sema_context
import sema_drop

// Module level of the ELE LIR: index tables, signatures, struct layouts,
// the protocol header, and the per-function finish (splice the drop plan,
// verify, serialize). Only `sema-l --emit-lir` finishes and writes LIR.

pub fn semaLirSetup(ctx: &mut SemaContext, source: &Text, tree: &AstTree) {
    for f in 0..tree.fields.length { ctx.lir_field_local.push(-1) }
    var functions = 0
    var structs = 0
    for d in 0..tree.declarations.length {
        ctx.lir_func_index.push(-1)
        ctx.lir_struct_index.push(-1)
        let decl = &tree.declarations[d]
        match decl.kind {
            AstDeclKind.Function => {
                ctx.lir_func_index[d] = functions
                let main_name = "main"
                if symbolNameEqualsText(source, decl.a, decl.b, main_name) { ctx.lir_main = functions }
                functions += 1
            }
            AstDeclKind.Struct => {
                ctx.current_module = semaDeclModule(ctx, d)
                ctx.lir_struct_index[d] = structs
                for f in decl.c..(decl.c + decl.d) { ctx.lir_field_local[f] = f - decl.c }
                ctx.lir_module.st_first.push(ctx.lir_module.field_ty.length)
                ctx.lir_module.st_count.push(decl.d)
                ctx.lir_module.st_decl.push(d)
                for f in decl.c..(decl.c + decl.d) {
                    let ty = semaFieldType(&mut ctx, source, tree, f)
                    ctx.lir_module.field_ty.push(ty)
                }
                structs += 1
            }
            AstDeclKind.Enum => {
                ctx.current_module = semaDeclModule(ctx, d)
                ctx.lir_module.en_decl.push(d)
                ctx.lir_module.en_builtin.push(-1)
                ctx.lir_module.en_first.push(ctx.lir_module.variant_payload.length)
                ctx.lir_module.en_count.push(decl.d)
                var has_payload = false
                for v in decl.c..(decl.c + decl.d) {
                    let n = tree.variants[v].payload_count
                    ctx.lir_module.variant_payload.push(n)
                    var payload_ty = 6
                    if n > 0 {
                        payload_ty = semaResolveAstType(&mut ctx, source, tree, tree.extra[tree.variants[v].first_payload_index])
                        has_payload = true
                    }
                    ctx.lir_module.variant_type.push(payload_ty)
                }
                if !has_payload { ctx.lir_module.unit_enums.push(d) }
            }
            _ => {}
        }
    }
    for d in 0..tree.declarations.length {
        let decl = &tree.declarations[d]
        match decl.kind {
            AstDeclKind.Function => { semaLirSignature(&mut ctx, source, tree, d) }
            _ => {}
        }
    }
    // Signatures have resolved their concrete generic types. Newly inferred
    // Option/Result types are additionally registered as expressions lower.
    for t in 8..ctx.types.types.length {
        lirBuiltinRegister(&mut ctx.lir_module, &ctx.types, t)
    }
    for t in 8..ctx.types.types.length {
        match ctx.types.types[t].kind {
            SemTypeKind.List => {
                let elem = ctx.types.types[t].elem_type
                var found = false
                for k in 0..ctx.lir_module.list_elem.length {
                    if ctx.lir_module.list_elem[k] == elem { found = true }
                }
                if !found {
                    ctx.lir_module.list_elem.push(elem)
                }
            }
            _ => {}
        }
    }
}

pub fn semaLirComplete(ctx: &mut SemaContext, source: &Text, tree: &AstTree) {
    if !ctx.emit_lir || ctx.errors.length > 0 { return }
    // Determine header function count before taking a mutable loan of ctx.
    let function_count = ctx.lir_module.fn_first.length
    semaLirHeader(&mut ctx, source, tree, function_count)
    if ctx.errors.length > 0 { return }
    for i in 0..ctx.lir_functions.length {
        let line = &ctx.lir_functions[i]
        ctx.lir_lines.push("{line}")
    }
}

fn semaLirSignature(ctx: &mut SemaContext, source: &Text, tree: &AstTree, d: Int) {
    ctx.current_module = semaDeclModule(ctx, d)
    let decl = &tree.declarations[d]
    ctx.lir_module.fn_first.push(ctx.lir_module.param_ty.length)
    ctx.lir_module.fn_count.push(decl.e)
    ctx.lir_module.fn_decl.push(d)
    for p in 0..decl.e {
        let ty = semaResolveAstType(&mut ctx, source, tree, tree.params[decl.d + p].type_id)
        let elem = semaRefElem(ctx, ty)
        if elem >= 0 {
            ctx.lir_module.param_ty.push(elem)
        } else {
            ctx.lir_module.param_ty.push(ty)
        }
        ctx.lir_module.param_ref.push(elem >= 0)
        ctx.lir_module.param_mut.push(semaIsMutRef(ctx, ty))
    }
    var ret = 6
    if decl.f >= 0 { ret = semaResolveAstType(&mut ctx, source, tree, decl.f) }
    let elem = semaRefElem(ctx, ret)
    ctx.lir_module.fn_ret_ref.push(elem >= 0)
    ctx.lir_module.fn_ret_mut.push(semaIsMutRef(ctx, ret))
    if elem >= 0 { ret = elem }
    ctx.lir_module.fn_ret.push(ret)
}

fn semaLirHeader(ctx: &mut SemaContext, source: &Text, tree: &AstTree, functions: Int) {
    let structs = ctx.lir_module.st_decl.length
    let enums = ctx.lir_module.en_decl.length
    let lists = ctx.lir_module.list_elem.length
    let main = ctx.lir_main
    ctx.lir_lines.push("ELE-LIR 1")
    var header = "module structs {structs}"
    if enums > 0 { header = "{header} enums {enums}" }
    if lists > 0 { header = "{header} lists {lists}" }
    ctx.lir_lines.push("{header} funcs {functions} main f{main}")
    for k in 0..structs {
        let decl = &tree.declarations[ctx.lir_module.st_decl[k]]
        let name = lirSpanText(source, decl.a, decl.b)
        let count = decl.d
        ctx.lir_lines.push("struct s{k} {name} fields {count}")
        for f in decl.c..(decl.c + decl.d) {
            let field_name = lirSpanText(source, tree.fields[f].name_start, tree.fields[f].name_end)
            let ty = lirTypeCode(&ctx.types, &ctx.lir_module, ctx.lir_module.field_ty[ctx.lir_module.st_first[k] + f - decl.c])
            ctx.lir_lines.push("field {field_name} {ty}")
        }
    }
    for k in 0..enums {
        if ctx.lir_module.en_builtin[k] >= 0 {
            let first_variant = ctx.lir_module.en_first[k]
            let first_code = lirTypeCode(&ctx.types, &ctx.lir_module, ctx.lir_module.variant_type[first_variant])
            let second_code = lirTypeCode(&ctx.types, &ctx.lir_module, ctx.lir_module.variant_type[first_variant + 1])
            lirBuiltinHeader(&mut ctx, k, first_code, second_code)
            continue
        }
        let d = ctx.lir_module.en_decl[k]
        ctx.current_module = semaDeclModule(ctx, d)
        let decl = &tree.declarations[d]
        let name = lirSpanText(source, decl.a, decl.b)
        let count = decl.d
        ctx.lir_lines.push("enum e{k} {name} variants {count}")
        for v in decl.c..(decl.c + decl.d) {
            let variant = &tree.variants[v]
            let vname = lirSpanText(source, variant.name_start, variant.name_end)
            let payload_count = variant.payload_count
            var line = "variant {vname} types {payload_count}"
            for i in 0..payload_count {
                let ty = semaResolveAstType(&mut ctx, source, tree, tree.extra[variant.first_payload_index + i])
                let code = lirTypeCode(&ctx.types, &ctx.lir_module, ty)
                if code.byteLength == 1 && code.byteAt(0) == 63 {
                    semaAddError(&mut ctx, "L0016", "payload de enum no representable en ELE-LIR 1", variant.start, variant.end)
                }
                line = "{line} {code}"
            }
            ctx.lir_lines.push(line)
        }
    }
    for k in 0..lists {
        let elem_t = ctx.lir_module.list_elem[k]
        let elem_ty = lirTypeCode(&ctx.types, &ctx.lir_module, elem_t)
        ctx.lir_lines.push("list l{k} {elem_ty}")
    }
}

// Is every variable, signature and field type representable in LIR v1?
fn semaLirTypesOk(ctx: &SemaContext, fn_index: Int) -> Bool {
    for i in 0..ctx.lir.vars.length {
        let code = lirTypeCode(&ctx.types, &ctx.lir_module, ctx.lir.vars[i].ty)
        if code.byteLength == 1 && code.byteAt(0) == 63 { return false }
    }
    for i in 0..ctx.lir_module.field_ty.length {
        let code = lirTypeCode(&ctx.types, &ctx.lir_module, ctx.lir_module.field_ty[i])
        if code.byteLength == 1 && code.byteAt(0) == 63 { return false }
    }
    return true
}

pub fn semaLirFinish(ctx: &mut SemaContext, source: &Text, tree: &AstTree, plan: &DropPlan, d: Int) {
    if !ctx.emit_lir { return }
    let decl = &tree.declarations[d]
    let fn_index = ctx.lir_func_index[d]
    if ctx.lir.unsupported >= 0 || !semaLirTypesOk(ctx, fn_index) {
        var at = decl.start
        if ctx.lir.unsupported >= 0 { at = ctx.lir.unsupported }
        semaAddError(&mut ctx, "L0016", "construcción fuera del subconjunto de la LIR v1 de ELE", at, at)
        return
    }
    var body = lirFinish(&mut ctx.lir, &ctx.flow, plan, &ctx.lir_field_local)
    if ctx.lir_fault > 0 { lirInjectFault(&mut ctx.lir, &mut body, ctx.lir_fault) }
    let checked = lirVerify(&ctx.lir, &body, &ctx.types, &ctx.lir_module, &ctx.drop_memo, fn_index)
    if checked.status != 0 {
        let rule = checked.status
        let block = checked.block
        semaAddError(&mut ctx, "ICE", "error interno del compilador: LIR inválida (regla {rule}, bloque {block})", decl.start, decl.end)
        return
    }
    ctx.lir_insts += body.order.length
    ctx.lir_blocks += body.term.length
    if ctx.lir_line_starts.length == 0 { ctx.lir_line_starts = lirLineStarts(source) }
    lirWriteFunction(&mut ctx.lir_functions, &ctx.lir_line_starts, &ctx.lir, &body, source, &ctx.types, &ctx.lir_module, fn_index, decl.a, decl.b)
}

// Test hook (`sema-l archivo.l --lir-fault=K`): corrupt a verified
// function in one defined way so the tests can prove the verifier rejects
// it. 1 variable id, 2 block id, 3 operand type, 4 use before assignment,
// 5 call arity, 6 drop of a non-owned value, 7 return type, 8 field index.
// 9 invalid platform opcode, 10 platform arity, 11 argument loan mode,
// 12 platform result type, 13 invalid platform argument id.
fn lirInjectFault(l: &mut LirFn, body: &mut LirBody, fault: Int) {
    for n in 0..body.order.length {
        let id = body.order[n]
        let kind = l.insts[id].kind
        if fault == 1 && kind == LIR_USE {
            l.insts[id].dst = l.vars.length + 3
            return
        }
        if fault == 3 && kind == LIR_BINARY {
            l.insts[id].c = lirConst(&mut l, LIR_CONST_BOOL, 1, 0, 0)
            return
        }
        if fault == 5 && kind == LIR_CALL {
            l.insts[id].c = l.insts[id].c + 1
            return
        }
        if fault == 6 && kind == LIR_DROP {
            l.insts[id].dst = lirVar(&mut l, 1, false)
            return
        }
        if kind == LIR_PLATFORM {
            if fault == 9 { l.insts[id].a = 99; return }
            if fault == 10 { l.insts[id].c += 1; return }
            if fault == 11 && l.insts[id].c > 0 {
                let first = l.insts[id].b
                let arg = l.operands[first]
                l.args[arg].by_ref = false
                return
            }
            if fault == 12 {
                l.vars[l.insts[id].dst].ty = 4
                return
            }
            if fault == 13 && l.insts[id].c > 0 {
                let first = l.insts[id].b
                l.operands[first] = l.args.length + 1
                return
            }
        }
        if fault == 8 && (kind == LIR_READ || kind == LIR_STORE) && l.places[l.insts[id].a].parent >= 0 {
            l.places[l.insts[id].a].field = 99
            return
        }
    }
    if fault == 4 {
        // Use a fresh, never assigned variable as the first operand read.
        let fresh = lirVar(&mut l, 1, false)
        for n in 0..body.order.length {
            let id = body.order[n]
            if l.insts[id].kind == LIR_BINARY {
                l.insts[id].b = fresh
                return
            }
        }
    }
    for b in 0..body.term.length {
        if fault == 2 && (body.term[b] == LIR_T_JUMP || body.term[b] == LIR_T_BRANCH) {
            body.ta[b] = body.term.length + 5
            return
        }
        if fault == 7 && body.term[b] == LIR_T_RETURN {
            body.top[b] = lirConst(&mut l, LIR_CONST_BOOL, 0, 0, 0)
            return
        }
    }
}
