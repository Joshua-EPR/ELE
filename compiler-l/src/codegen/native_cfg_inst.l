take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_cfg_ref
take native_cfg_arith
take native_cfg_fields
take native_cfg_list
take native_cfg_loan
take native_cfg_platform

// Source of `print` and `append`: `val <operand>` fills `inst.a` and returns
// -1; `ref p<N> 0` returns the referenced variable.
flow cfgReadSource(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) => Int {
    hold mode = nativeWord(source, edit reader)
    when nativeEquals(source, view mode, "ref") {
        hold error = cfgReadSourceRef(edit p, f, source, edit reader, edit inst)
        when error != 0 { reader.error = error }
        give inst.op
    }
    when !nativeEquals(source, view mode, "val") { reader.error = 14 }
    inst.a = cfgOperand(edit p, source, edit reader)
    give -1
}

expose flow cfgReadInst(p: edit CfgProgram, source: view Text, reader: edit NativeReader, f: Int) {
    nativeExpect(source, edit reader, "i")
    hold kind = nativeWord(source, edit reader)
    change inst = CfgInst(kind: 0, dst: -1, op: 0, callee: -1, argc: 0,
        a: cfgEmptyOperand(), b: cfgEmptyOperand(), c: cfgEmptyOperand(), d: cfgEmptyOperand(),
        place_var: -1, place_field: -1, place_subfield: -1, arg_first: -1, src_field: -1, src_sub: -1, place_ext: -1, src_ext: -1)
    when nativeEquals(source, view kind, "use") {
        inst.kind = 1
        inst.dst = nativeId(source, edit reader, 118)
        inst.a = cfgOperand(edit p, source, edit reader)
    } otherwise when nativeEquals(source, view kind, "binary") {
        inst.kind = 2
        inst.dst = nativeId(source, edit reader, 118)
        hold op = nativeWord(source, edit reader)
        inst.op = cfgBinaryOp(source, view op)
        inst.a = nativeOperand(source, edit reader)
        inst.b = nativeOperand(source, edit reader)
    } otherwise when nativeEquals(source, view kind, "call") {
        inst.kind = 3
        inst.dst = nativeId(source, edit reader, 118)
        inst.callee = nativeId(source, edit reader, 102)
        inst.argc = nativeNumber(source, edit reader)
        when inst.argc < 0 || inst.argc > 16 { p.error = 32 }
        inst.arg_first = p.call_args.length
        when p.error == 0 {
            each n among 0..inst.argc {
                hold arg_error = cfgReadCallArg(edit p, f, source, edit reader)
                when arg_error != 0 { p.error = arg_error }
            }
        }
    } otherwise when nativeEquals(source, view kind, "struct") {
        inst.kind = 4
        inst.dst = nativeId(source, edit reader, 118)
        inst.op = nativeId(source, edit reader, 115)
        inst.argc = nativeNumber(source, edit reader)
        // Store all operands in order, independent from call references.
        when inst.argc < 1 || inst.argc > 64 { p.error = 64; give }
        inst.arg_first = p.struct_args.length
        when p.error == 0 {
            each n among 0..inst.argc {
                p.struct_args@push(cfgOperand(edit p, source, edit reader))
            }
        }
    } otherwise when nativeEquals(source, view kind, "read") {
        inst.kind = 5
        inst.dst = nativeId(source, edit reader, 118)
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
        inst.place_ext = place.ext
    } otherwise when nativeEquals(source, view kind, "store") {
        inst.kind = 6
        hold place = cfgReadPlace(edit p, f, source, edit reader)
        inst.place_var = place.variable
        inst.place_field = place.field
        inst.place_subfield = place.subfield
        inst.place_ext = place.ext
        inst.a = cfgOperand(edit p, source, edit reader)
    } otherwise when nativeEquals(source, view kind, "variant") {
        inst.kind = 7
        inst.dst = nativeId(source, edit reader, 118)
        inst.op = nativeId(source, edit reader, 101)
        inst.place_field = nativeNumber(source, edit reader)
        inst.argc = nativeNumber(source, edit reader)
        when inst.argc < 0 || inst.argc > 1 { p.error = 83 }
        when inst.argc == 1 { inst.a = cfgOperand(edit p, source, edit reader) }
    } otherwise when nativeEquals(source, view kind, "disc") {
        inst.kind = 8
        inst.dst = nativeId(source, edit reader, 118)
        // pN, without any projections, is the only accepted place here.
        // The discriminant access does not consume the enum owner.
        inst.place_var = nativeId(source, edit reader, 112)
    } otherwise when nativeEquals(source, view kind, "payload") {
        // Experimental checked read: i payload vD pN eK V.
        // The source enum remains live because the payload must be Copy.
        // The emitter checks the active discriminant at runtime BEFORE
        // accessing memory. This does not permit owning payload extraction.
        inst.kind = 9
        inst.dst = nativeId(source, edit reader, 118)
        inst.place_var = nativeId(source, edit reader, 112)
        inst.op = nativeId(source, edit reader, 101)
        inst.place_field = nativeNumber(source, edit reader)
    } otherwise when nativeEquals(source, view kind, "print") {
        // i print val <operand>: writes the decimal Int or `true`/`false`
        // followed by a newline to stdout. It has no destination.
        inst.kind = 10
        hold referenced = cfgReadSource(edit p, f, source, edit reader, edit inst)
        inst.op = referenced
    } otherwise when nativeEquals(source, view kind, "textbuf") {
        // i textbuf vD <capacity>: a new empty owned Text.
        inst.kind = 11
        inst.dst = nativeId(source, edit reader, 118)
        inst.callee = nativeNumber(source, edit reader)
        when inst.callee < 0 { p.error = 91 }
    } otherwise when nativeEquals(source, view kind, "append") {
        // i append vD <val operand | ref place>: vD stays live and owned.
        inst.kind = 12
        inst.place_var = nativeId(source, edit reader, 118)
        hold referenced = cfgReadSource(edit p, f, source, edit reader, edit inst)
        inst.op = referenced
    } otherwise when nativeEquals(source, view kind, "drop") {
        // i drop vD <vFlag | ->: releases vD, only when the flag is true.
        inst.kind = 13
        inst.place_var = nativeId(source, edit reader, 118)
        change probe = NativeReader(offset: reader.offset, error: 0)
        hold flag = nativeWord(source, edit probe)
        when nativeEquals(source, view flag, "-") {
            reader.offset = probe.offset
            inst.op = -1
        } otherwise {
            inst.op = nativeId(source, edit reader, 118)
        }
    } otherwise when nativeEquals(source, view kind, "dropfield") {
        cfgReadDropField(edit p, f, source, edit reader, edit inst)
    } otherwise when nativeEquals(source, view kind, "unary") {
        cfgReadUnary(edit p, f, source, edit reader, edit inst)
    } otherwise when nativeEquals(source, view kind, "len") {
        cfgReadTextQuery(edit p, f, source, edit reader, edit inst, 14)
    } otherwise when nativeEquals(source, view kind, "byteat") {
        cfgReadTextQuery(edit p, f, source, edit reader, edit inst, 15)
    } otherwise when nativeEquals(source, view kind, "platform") {
        cfgReadPlatform(edit p, f, source, edit reader, edit inst)
    } otherwise when nativeEquals(source, view kind, "loan") {
        cfgReadLoan(edit p, f, source, edit reader, edit inst)
    } otherwise when !cfgReadListInst(edit p, f, source, edit reader, edit inst, view kind) {
        p.error = 31
    }
    nativeEndLineSpan(source, edit reader)
    hold has_dst = inst.kind != 6 && inst.kind != 10 && inst.kind != 12 && inst.kind != 13 && inst.kind != 17 && inst.kind != 19 && inst.kind != 20
    // An earlier, more precise rejection (e.g. 31 unknown instruction) wins.
    when p.error == 0 && (reader.error != 0 || (has_dst && (inst.dst < 0 || inst.dst >= p.functions[f].vars))) {
        p.error = 33
    }
    when p.error != 0 { give }
    when inst.kind == 22 {
        p.error = cfgCheckLoan(edit p, f, view inst)
    } otherwise when has_dst && cfgIsRef(p, f, inst.dst) {
        p.error = 96
    }
    when p.error != 0 { give }
    when inst.kind == 13 && inst.place_var >= 0 && inst.place_var < p.functions[f].vars {
        when cfgIsRef(p, f, inst.place_var) { p.error = 95 }
    }
    when inst.kind == 14 || inst.kind == 15 { p.error = cfgCheckTextQuery(p, f, view inst) }
    when inst.kind == 16 { p.error = cfgCheckUnary(p, f, view inst) }
    when inst.kind == 17 { p.error = cfgCheckDropField(p, f, view inst) }
    when inst.kind == 24 { p.error = cfgCheckPlatform(p, f, view inst) }
    when (inst.kind >= 18 && inst.kind <= 21) || inst.kind == 23 { p.error = cfgCheckListInst(p, f, view inst) }
    when p.error != 0 { give }
    change dest_type = -1
    when has_dst { dest_type = p.types_code[p.functions[f].first_var + inst.dst] }
    hold first_type = cfgOperandType(p, f, view inst.a)
    when inst.kind == 10 || inst.kind == 12 {
        // The source is Int, Bool or Text. As in Stage 0, `append val vN` of a
        // Text only reads it: the source stays owned and is dropped later.
        change source_type = first_type
        when inst.op >= 0 { source_type = cfgSourcePlaceType(p, f, view inst) }
        when source_type != 0 && source_type != 1 && source_type != cfgTextType() { p.error = 90 }
    }
    when inst.kind == 11 && dest_type != cfgTextType() { p.error = 91 }
    when inst.kind == 12 || inst.kind == 13 {
        when inst.place_var < 0 || inst.place_var >= p.functions[f].vars {
            p.error = 92
        } otherwise {
            // `append` writes a Text buffer; `drop` releases a Text, a list or
            // a whole union whose variants own heap storage (union drop glue
            // in native_cfg_list_emit). A whole shape, or a union that owns
            // nothing, is still rejected.
            hold owner = p.types_code[p.functions[f].first_var + inst.place_var]
            hold union_owner = inst.kind == 13 && cfgOwningUnion(p, owner)
            when owner != cfgTextType() && !union_owner && (inst.kind == 12 || cfgListIndex(p, owner) < 0) { p.error = 92 }
        }
        // Appending a buffer to itself would read storage that growth moves.
        when inst.kind == 12 && inst.op == inst.place_var { p.error = 93 }
        when inst.kind == 12 && inst.op < 0 && inst.a.is_var && inst.a.value == inst.place_var { p.error = 93 }
    }
    when inst.kind == 13 && inst.op >= 0 {
        when inst.op >= p.functions[f].vars {
            p.error = 94
        } otherwise when p.types_code[p.functions[f].first_var + inst.op] != 1 {
            p.error = 94
        }
    }
    when inst.kind == 1 && first_type != dest_type { p.error = 34 }
    when inst.kind == 2 {
        hold second_type = cfgOperandType(p, f, view inst.b)
        when inst.op == 0 || first_type < 0 || second_type < 0 { p.error = 35 }
        when (inst.op <= 3 || inst.op >= 10) && (dest_type != 0 || first_type != 0 || second_type != 0) { p.error = 36 }
        when inst.op >= 4 && inst.op <= 9 && (dest_type != 1 || first_type != second_type || first_type > 1) { p.error = 36 }
        when inst.op >= 6 && inst.op <= 9 && first_type != 0 { p.error = 36 }
    }
    when inst.kind == 4 {
        when inst.op < 0 || inst.op >= p.structs.length || dest_type != inst.op + 2 { p.error = 65 }
        when p.error == 0 {
            hold st = view p.structs[inst.op]
            when inst.argc != st.fields { p.error = 65 }
            when p.error == 0 {
                each n among 0..inst.argc {
                    hold arg = view p.struct_args[inst.arg_first + n]
                    when cfgOperandType(p, f, view arg) != p.fields[st.first_field + n].ty {
                        p.error = 66
                        leave
                    }
                }
            }
        }
    }
    when inst.kind == 7 {
        when inst.op < 0 || inst.op >= p.enums.length { p.error = 84 }
        when p.error == 0 {
            hold item = view p.enums[inst.op]
            when dest_type != 2 + p.structs.length + inst.op || inst.place_field < 0 || inst.place_field >= item.variants {
                p.error = 85
            } otherwise {
                hold variant = view p.variants[item.first_variant + inst.place_field]
                change required = 0
                when variant.payload_type != -1 { required = 1 }
                when inst.argc != required || (required == 1 && first_type != variant.payload_type) { p.error = 86 }
            }
        }
    }
    when inst.kind == 8 {
        when inst.place_var < 0 || inst.place_var >= p.functions[f].vars || dest_type != 0 {
            p.error = 87
        } otherwise {
            hold owner_type = p.types_code[p.functions[f].first_var + inst.place_var]
            hold enum_index = owner_type - 2 - p.structs.length
            when enum_index < 0 || enum_index >= p.enums.length { p.error = 87 }
        }
    }
    when inst.kind == 9 {
        when inst.place_var < 0 || inst.place_var >= p.functions[f].vars || inst.op < 0 || inst.op >= p.enums.length {
            p.error = 88
        } otherwise {
            hold ty = p.types_code[p.functions[f].first_var + inst.place_var]
            hold e = view p.enums[inst.op]
            when ty != 2 + p.structs.length + inst.op || inst.place_field < 0 || inst.place_field >= e.variants {
                p.error = 88
            } otherwise {
                hold payload = p.variants[e.first_variant + inst.place_field].payload_type
                // A unit variant cannot be projected. Payloads are Int/Bool
                // (copied) or aggregates/Text (cfgLayoutEnum), whose
                // extraction MOVES the whole enum (native_cfg_verify). Moving
                // out of a referent is not allowed.
                when (payload < 0 && payload != cfgTextType()) || dest_type != payload { p.error = 89 }
                when (payload >= 2 || payload == cfgTextType()) && cfgIsRef(p, f, inst.place_var) { p.error = 89 }
            }
        }
    }
    when inst.kind == 5 || inst.kind == 6 {
        hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: inst.place_ext)
        hold ty = cfgPlaceType(p, f, view place)
        when ty == -1 { p.error = 67 }
        when inst.kind == 5 && dest_type != ty { p.error = 67 }
        when inst.kind == 6 && first_type != ty { p.error = 67 }
        // A bare `pN` is a place only through a reference; plain variables
        // are read and written with `use`.
        when inst.place_field < 0 && inst.place_ext < 0 && !cfgIsRef(p, f, inst.place_var) { p.error = 67 }
        // Moving a Text or a list out of a referent would duplicate its
        // buffer. A field of an owned shape moves out, and a store may refill
        // a field whose value was moved or released (native_cfg_paths).
        when inst.kind == 5 && (cfgOwnsHeap(p, ty) || cfgIsLinear(ty)) && cfgIsRef(p, f, inst.place_var) { p.error = 95 }
        // A linear referent is live for the entire borrow. Replacing it would
        // discard the original OS resource without a consuming close.
        when inst.kind == 6 && cfgIsLinear(ty) { p.error = 104 }
        // A whole store through a reference (`i store pN vM`) replaces an
        // owning referent: the emitter releases the old value through its
        // drop glue, then moves the new one in (the verifier requires the
        // old value whole). The source cannot be the reference itself.
        when inst.kind == 6 && inst.place_field < 0 && inst.place_ext < 0 && cfgOwnsHeap(p, ty) && inst.a.is_var && inst.a.value == inst.place_var { p.error = 104 }
        // Moving an owner out of an indexed place is not tracked by move
        // paths. A store releases the old element before transferring its
        // replacement; the source cannot be the collection itself.
        when p.error == 0 && inst.kind == 5 && inst.place_ext >= 0 && cfgOwnsHeap(p, ty) { p.error = 103 }
        when p.error == 0 && inst.kind == 6 && inst.place_ext >= 0 && cfgOwnsHeap(p, ty) && inst.a.is_var && inst.a.value == inst.place_var { p.error = 104 }
    }
    when p.error == 0 { p.insts@push(inst) }
}
