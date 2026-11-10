import lir_tokens
import native_cfg_defs
import native_cfg_types

pub fn cfgReadInst(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int) {
    nativeExpect(source, &mut reader, "i")
    let kind = nativeWord(source, &mut reader)
    var inst = CfgInst(kind: 0, dst: -1, op: 0, callee: -1, argc: 0,
        a: cfgEmptyOperand(), b: cfgEmptyOperand(), c: cfgEmptyOperand(), d: cfgEmptyOperand(),
        place_var: -1, place_field: -1, place_subfield: -1)
    if nativeEquals(source, &kind, "use") {
        inst.kind = 1
        inst.dst = nativeId(source, &mut reader, 118)
        inst.a = nativeOperand(source, &mut reader)
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
        if inst.argc < 0 || inst.argc > 2 { p.error = 32 }
        if inst.argc >= 1 && inst.argc <= 2 {
            nativeExpect(source, &mut reader, "val")
            inst.a = nativeOperand(source, &mut reader)
        }
        if inst.argc == 2 {
            nativeExpect(source, &mut reader, "val")
            inst.b = nativeOperand(source, &mut reader)
        }
    } else if nativeEquals(source, &kind, "struct") {
        inst.kind = 4
        inst.dst = nativeId(source, &mut reader, 118)
        inst.op = nativeId(source, &mut reader, 115)
        inst.argc = nativeNumber(source, &mut reader)
        if inst.argc < 1 || inst.argc > 4 { p.error = 64 }
        if inst.argc >= 1 && inst.argc <= 4 { inst.a = nativeOperand(source, &mut reader) }
        if inst.argc >= 2 && inst.argc <= 4 { inst.b = nativeOperand(source, &mut reader) }
        if inst.argc >= 3 && inst.argc <= 4 { inst.c = nativeOperand(source, &mut reader) }
        if inst.argc == 4 { inst.d = nativeOperand(source, &mut reader) }
    } else if nativeEquals(source, &kind, "read") {
        inst.kind = 5
        inst.dst = nativeId(source, &mut reader, 118)
        let place = cfgReadPlace(p, f, source, &mut reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
    } else if nativeEquals(source, &kind, "store") {
        inst.kind = 6
        let place = cfgReadPlace(p, f, source, &mut reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
        inst.a = nativeOperand(source, &mut reader)
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
    } else {
        p.error = 31
    }
    nativeEndLineSpan(source, &mut reader)
    if reader.error != 0 || (inst.kind != 6 && (inst.dst < 0 || inst.dst >= p.functions[f].vars)) {
        p.error = 33
    }
    if p.error != 0 { return }
    var dest_type = -1
    if inst.kind != 6 { dest_type = p.types_code[p.functions[f].first_var + inst.dst] }
    let first_type = cfgOperandType(p, f, &inst.a)
    if inst.kind == 1 && first_type != dest_type { p.error = 34 }
    if inst.kind == 2 {
        let second_type = cfgOperandType(p, f, &inst.b)
        if inst.op == 0 || first_type < 0 || second_type < 0 { p.error = 35 }
        if inst.op <= 3 && (dest_type != 0 || first_type != 0 || second_type != 0) { p.error = 36 }
        if inst.op >= 4 && (dest_type != 1 || first_type != second_type || first_type > 1) { p.error = 36 }
        if inst.op >= 6 && first_type != 0 { p.error = 36 }
    }
    if inst.kind == 3 && inst.argc >= 1 && (first_type < 0 || first_type >= 2) { p.error = 37 }
    if inst.kind == 3 && inst.argc == 2 && (cfgOperandType(p, f, &inst.b) < 0 || cfgOperandType(p, f, &inst.b) >= 2) { p.error = 37 }
    if inst.kind == 4 {
        if inst.op < 0 || inst.op >= p.structs.length || dest_type != inst.op + 2 { p.error = 65 }
        if p.error == 0 {
            let st = &p.structs[inst.op]
            if inst.argc != st.fields { p.error = 65 }
            if inst.argc >= 1 && first_type != p.fields[st.first_field].ty { p.error = 66 }
            if inst.argc >= 2 && cfgOperandType(p, f, &inst.b) != p.fields[st.first_field + 1].ty { p.error = 66 }
            if inst.argc >= 3 && cfgOperandType(p, f, &inst.c) != p.fields[st.first_field + 2].ty { p.error = 66 }
            if inst.argc == 4 && cfgOperandType(p, f, &inst.d) != p.fields[st.first_field + 3].ty { p.error = 66 }
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
        if ty < 0 { p.error = 67 }
        if inst.kind == 5 && dest_type != ty { p.error = 67 }
        if inst.kind == 6 && first_type != ty { p.error = 67 }
        // Reading a struct field by value would partially move its parent;
        // this subset has only whole-variable move flags, so reject it.
        if inst.kind == 5 && ty >= 2 { p.error = 73 }
    }
    if p.error == 0 { p.insts.push(inst) }
}

