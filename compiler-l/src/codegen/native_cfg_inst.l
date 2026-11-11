import lir_tokens
import native_cfg_defs
import native_cfg_types
import native_cfg_ref
import native_cfg_arith
import native_cfg_fields

// Source of `print` and `append`: `val <operand>` fills `inst.a` and returns
// -1; `ref p<N> 0` returns the referenced variable.
fn cfgReadSource(p: &mut CfgProgram, f: Int, source: &Text, reader: &mut NativeReader, inst: &mut CfgInst) -> Int {
    let mode = nativeWord(source, &mut reader)
    if nativeEquals(source, &mode, "ref") {
        let error = cfgReadSourceRef(p, f, source, &mut reader, &mut inst)
        if error != 0 { reader.error = error }
        return inst.op
    }
    if !nativeEquals(source, &mode, "val") { reader.error = 14 }
    inst.a = cfgOperand(&mut p, source, &mut reader)
    return -1
}

pub fn cfgReadInst(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int) {
    nativeExpect(source, &mut reader, "i")
    let kind = nativeWord(source, &mut reader)
    var inst = CfgInst(kind: 0, dst: -1, op: 0, callee: -1, argc: 0,
        a: cfgEmptyOperand(), b: cfgEmptyOperand(), c: cfgEmptyOperand(), d: cfgEmptyOperand(),
        place_var: -1, place_field: -1, place_subfield: -1, arg_first: -1, src_field: -1, src_sub: -1)
    if nativeEquals(source, &kind, "use") {
        inst.kind = 1
        inst.dst = nativeId(source, &mut reader, 118)
        inst.a = cfgOperand(&mut p, source, &mut reader)
    } else if nativeEquals(source, &kind, "binary") {
        inst.kind = 2
        inst.dst = nativeId(source, &mut reader, 118)
        let op = nativeWord(source, &mut reader)
        inst.op = cfgBinaryOp(source, &op)
        inst.a = nativeOperand(source, &mut reader)
        inst.b = nativeOperand(source, &mut reader)
    } else if nativeEquals(source, &kind, "call") {
        inst.kind = 3
        inst.dst = nativeId(source, &mut reader, 118)
        inst.callee = nativeId(source, &mut reader, 102)
        inst.argc = nativeNumber(source, &mut reader)
        if inst.argc < 0 || inst.argc > 16 { p.error = 32 }
        inst.arg_first = p.call_args.length
        if p.error == 0 {
            for n in 0..inst.argc {
                let arg_error = cfgReadCallArg(&mut p, f, source, &mut reader)
                if arg_error != 0 { p.error = arg_error }
            }
        }
    } else if nativeEquals(source, &kind, "struct") {
        inst.kind = 4
        inst.dst = nativeId(source, &mut reader, 118)
        inst.op = nativeId(source, &mut reader, 115)
        inst.argc = nativeNumber(source, &mut reader)
        // Store all operands in order, independent from call references.
        if inst.argc < 1 || inst.argc > 64 { p.error = 64; return }
        inst.arg_first = p.struct_args.length
        if p.error == 0 {
            for n in 0..inst.argc {
                p.struct_args.push(cfgOperand(&mut p, source, &mut reader))
            }
        }
    } else if nativeEquals(source, &kind, "read") {
        inst.kind = 5
        inst.dst = nativeId(source, &mut reader, 118)
        let place = cfgReadPlace(p, f, &source, &mut reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
    } else if nativeEquals(source, &kind, "store") {
        inst.kind = 6
        let place = cfgReadPlace(p, f, &source, &mut reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
        inst.a = cfgOperand(&mut p, source, &mut reader)
    } else if nativeEquals(source, &kind, "variant") {
        inst.kind = 7
        inst.dst = nativeId(source, &mut reader, 118)
        inst.op = nativeId(source, &mut reader, 101)
        inst.place_field = nativeNumber(source, &mut reader)
        inst.argc = nativeNumber(source, &mut reader)
        if inst.argc < 0 || inst.argc > 1 { p.error = 83 }
        if inst.argc == 1 { inst.a = nativeOperand(source, &mut reader) }
    } else if nativeEquals(source, &kind, "disc") {
        inst.kind = 8
        inst.dst = nativeId(source, &mut reader, 118)
        // pN, without any projections, is the only accepted place here.
        // The discriminant access does not consume the enum owner.
        inst.place_var = nativeId(source, &mut reader, 112)
    } else if nativeEquals(source, &kind, "payload") {
        // Experimental checked read: i payload vD pN eK V.
        // The source enum remains live because the payload must be Copy.
        // The emitter checks the active discriminant at runtime BEFORE
        // accessing memory. This does not permit owning payload extraction.
        inst.kind = 9
        inst.dst = nativeId(source, &mut reader, 118)
        inst.place_var = nativeId(source, &mut reader, 112)
        inst.op = nativeId(source, &mut reader, 101)
        inst.place_field = nativeNumber(source, &mut reader)
    } else if nativeEquals(source, &kind, "print") {
        // i print val <operand>: writes the decimal Int or `true`/`false`
        // followed by a newline to stdout. It has no destination.
        inst.kind = 10
        let referenced = cfgReadSource(&mut p, f, source, &mut reader, &mut inst)
        inst.op = referenced
    } else if nativeEquals(source, &kind, "textbuf") {
        // i textbuf vD <capacity>: a new empty owned Text.
        inst.kind = 11
        inst.dst = nativeId(source, &mut reader, 118)
        inst.callee = nativeNumber(source, &mut reader)
        if inst.callee < 0 { p.error = 91 }
    } else if nativeEquals(source, &kind, "append") {
        // i append vD <val operand | ref place>: vD stays live and owned.
        inst.kind = 12
        inst.place_var = nativeId(source, &mut reader, 118)
        let referenced = cfgReadSource(&mut p, f, source, &mut reader, &mut inst)
        inst.op = referenced
    } else if nativeEquals(source, &kind, "drop") {
        // i drop vD <vFlag | ->: releases vD, only when the flag is true.
        inst.kind = 13
        inst.place_var = nativeId(source, &mut reader, 118)
        var probe = NativeReader(offset: reader.offset, error: 0)
        let flag = nativeWord(source, &mut probe)
        if nativeEquals(source, &flag, "-") {
            reader.offset = probe.offset
            inst.op = -1
        } else {
            inst.op = nativeId(source, &mut reader, 118)
        }
    } else if nativeEquals(source, &kind, "dropfield") {
        cfgReadDropField(p, f, source, &mut reader, &mut inst)
    } else if nativeEquals(source, &kind, "unary") {
        cfgReadUnary(&mut p, f, source, &mut reader, &mut inst)
    } else if nativeEquals(source, &kind, "len") {
        cfgReadTextQuery(&mut p, f, source, &mut reader, &mut inst, 14)
    } else if nativeEquals(source, &kind, "byteat") {
        cfgReadTextQuery(&mut p, f, source, &mut reader, &mut inst, 15)
    } else {
        p.error = 31
    }
    nativeEndLineSpan(source, &mut reader)
    let has_dst = inst.kind != 6 && inst.kind != 10 && inst.kind != 12 && inst.kind != 13 && inst.kind != 17
    if reader.error != 0 || (has_dst && (inst.dst < 0 || inst.dst >= p.functions[f].vars)) {
        p.error = 33
    }
    if p.error != 0 { return }
    if has_dst && cfgIsRef(p, f, inst.dst) { p.error = 96 }
    if inst.kind == 13 && inst.place_var >= 0 && inst.place_var < p.functions[f].vars {
        if cfgIsRef(p, f, inst.place_var) { p.error = 95 }
    }
    if inst.kind == 14 || inst.kind == 15 { p.error = cfgCheckTextQuery(p, f, &inst) }
    if inst.kind == 16 { p.error = cfgCheckUnary(p, f, &inst) }
    if inst.kind == 17 { p.error = cfgCheckDropField(p, f, &inst) }
    if p.error != 0 { return }
    var dest_type = -1
    if has_dst { dest_type = p.types_code[p.functions[f].first_var + inst.dst] }
    let first_type = cfgOperandType(p, f, &inst.a)
    if inst.kind == 10 || inst.kind == 12 {
        // The source is Int, Bool or Text. A Text variable must come by
        // reference: by value it would be consumed, which is not lowered.
        var source_type = first_type
        if inst.op >= 0 { source_type = cfgSourcePlaceType(p, f, &inst) }
        if source_type != 0 && source_type != 1 && source_type != cfgTextType() { p.error = 90 }
        if inst.kind == 12 && inst.op < 0 && inst.a.is_var && source_type == cfgTextType() { p.error = 90 }
    }
    if inst.kind == 11 && dest_type != cfgTextType() { p.error = 91 }
    if inst.kind == 12 || inst.kind == 13 {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars {
            p.error = 92
        } else if p.types_code[p.functions[f].first_var + inst.place_var] != cfgTextType() {
            p.error = 92
        }
        // Appending a buffer to itself would read storage that growth moves.
        if inst.kind == 12 && inst.op == inst.place_var { p.error = 93 }
    }
    if inst.kind == 13 && inst.op >= 0 {
        if inst.op >= p.functions[f].vars {
            p.error = 94
        } else if p.types_code[p.functions[f].first_var + inst.op] != 1 {
            p.error = 94
        }
    }
    if inst.kind == 1 && first_type != dest_type { p.error = 34 }
    if inst.kind == 2 {
        let second_type = cfgOperandType(p, f, &inst.b)
        if inst.op == 0 || first_type < 0 || second_type < 0 { p.error = 35 }
        if (inst.op <= 3 || inst.op >= 10) && (dest_type != 0 || first_type != 0 || second_type != 0) { p.error = 36 }
        if inst.op >= 4 && inst.op <= 9 && (dest_type != 1 || first_type != second_type || first_type > 1) { p.error = 36 }
        if inst.op >= 6 && inst.op <= 9 && first_type != 0 { p.error = 36 }
    }
    if inst.kind == 4 {
        if inst.op < 0 || inst.op >= p.structs.length || dest_type != inst.op + 2 { p.error = 65 }
        if p.error == 0 {
            let st = &p.structs[inst.op]
            if inst.argc != st.fields { p.error = 65 }
            if p.error == 0 {
                for n in 0..inst.argc {
                    let arg = &p.struct_args[inst.arg_first + n]
                    if cfgOperandType(p, f, &arg) != p.fields[st.first_field + n].ty {
                        p.error = 66
                        break
                    }
                }
            }
        }
    }
    if inst.kind == 7 {
        if inst.op < 0 || inst.op >= p.enums.length { p.error = 84 }
        if p.error == 0 {
            let item = &p.enums[inst.op]
            if dest_type != 2 + p.structs.length + inst.op || inst.place_field < 0 || inst.place_field >= item.variants {
                p.error = 85
            } else {
                let variant = &p.variants[item.first_variant + inst.place_field]
                var required = 0
                if variant.payload_type >= 0 { required = 1 }
                if inst.argc != required || (required == 1 && first_type != variant.payload_type) { p.error = 86 }
            }
        }
    }
    if inst.kind == 8 {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars || dest_type != 0 {
            p.error = 87
        } else {
            let owner_type = p.types_code[p.functions[f].first_var + inst.place_var]
            let enum_index = owner_type - 2 - p.structs.length
            if enum_index < 0 || enum_index >= p.enums.length { p.error = 87 }
        }
    }
    if inst.kind == 9 {
        if inst.place_var < 0 || inst.place_var >= p.functions[f].vars || inst.op < 0 || inst.op >= p.enums.length {
            p.error = 88
        } else {
            let ty = p.types_code[p.functions[f].first_var + inst.place_var]
            let e = &p.enums[inst.op]
            if ty != 2 + p.structs.length + inst.op || inst.place_field < 0 || inst.place_field >= e.variants {
                p.error = 88
            } else {
                let payload = p.variants[e.first_variant + inst.place_field].payload_type
                // A unit variant cannot be projected; only Int/Bool Copy
                // payloads are safe while the heap/drop runtime is absent.
                if payload < 0 || payload > 1 || dest_type != payload { p.error = 89 }
            }
        }
    }
    if inst.kind == 5 || inst.kind == 6 {
        let place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield)
        let ty = cfgPlaceType(p, f, &place)
        if ty == -1 { p.error = 67 }
        if inst.kind == 5 && dest_type != ty { p.error = 67 }
        if inst.kind == 6 && first_type != ty { p.error = 67 }
        // A bare `pN` is a place only through a reference; plain variables
        // are read and written with `use`.
        if inst.place_field < 0 && !cfgIsRef(p, f, inst.place_var) { p.error = 67 }
        // Moving a Text out of a referent would duplicate its buffer. A
        // Text field of an owned shape moves out, and a store may refill a
        // field whose Text was moved or released (native_cfg_paths).
        if inst.kind == 5 && cfgOwnsText(p, ty) && cfgIsRef(p, f, inst.place_var) { p.error = 95 }
        if inst.place_field < 0 && cfgOwnsText(p, ty) { p.error = 95 }
        // Reading a shape/choice field by value moves it out of an owned
        // parent; the verifier tracks that move path (native_cfg_paths).
        // Through a reference it is a copy, allowed only for values that own
        // no Text.
    }
    if p.error == 0 { p.insts.push(inst) }
}

