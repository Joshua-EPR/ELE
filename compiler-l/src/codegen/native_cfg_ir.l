take lir_tokens
take native_cfg_defs
take native_cfg_types
take native_cfg_inst
take native_cfg_list
take native_cfg_fields
take native_cfg_platform
take x86_64
take native_cfg_returnref

// ELE-LIR CFG reader; split across modules to obey CORE-1 token limit.
//
// Capacity: functions, variables, structs, enums and lists live in growable
// lists, so their counts have no fixed cap. What remains bounded is bounded
// by an encoding: a frame must fit x64MaxFrameSlots (disp32/imm32, code 69),
// and every type code needs a drop-glue runtime index below
// cfgPlatformBase() (code 48 here, 74 in native_cfg_emit). A declared count
// larger than the declarations that follow fails on the first missing line.

// Largest ELE-LIR input: the 32 MiB per-file limit with which the Stage 1
// front end (modules_l) reads the sources that produce it.
expose flow cfgMaxSource() => Int {
    give 33554432
}

flow cfgReadBlock(p: edit CfgProgram, source: view Text, reader: edit NativeReader, f: Int, b: Int) {
    nativeExpect(source, edit reader, "block")
    hold id = nativeNumber(source, edit reader)
    hold count = nativeNumber(source, edit reader)
    nativeEndLine(source, edit reader)
    when reader.error != 0 || id != b || count < 0 || count > 250000 {
        p.error = 38
        give
    }
    p.insts@reserve(count)
    hold first = p.insts.length
    each i among 0..count {
        when p.error != 0 { leave }
        cfgReadInst(edit p, source, edit reader, f)
    }
    when p.error != 0 { give }
    nativeExpect(source, edit reader, "t")
    hold keyword = nativeWord(source, edit reader)
    change kind = 0
    change value = cfgEmptyOperand()
    change yes = -1
    change no = -1
    when nativeEquals(source, view keyword, "return") {
        kind = 1
        value = cfgOperand(edit p, source, edit reader)
    } otherwise when nativeEquals(source, view keyword, "jump") {
        kind = 2
        yes = nativeNumber(source, edit reader)
    } otherwise when nativeEquals(source, view keyword, "branch") {
        kind = 3
        value = nativeOperand(source, edit reader)
        yes = nativeNumber(source, edit reader)
        no = nativeNumber(source, edit reader)
    } otherwise when nativeEquals(source, view keyword, "unreachable") {
        kind = 4
    } otherwise when nativeEquals(source, view keyword, "returnref") {
        // Checked with the whole function (native_cfg_returnref).
        kind = 5
        value = nativeOperand(source, edit reader)
    } otherwise {
        p.error = 39
    }
    nativeEndLineSpan(source, edit reader)
    when reader.error != 0 { p.error = 40 }
    when kind == 1 {
        hold expected = p.functions[f].result_type
        when cfgOperandType(p, f, view value) != expected { p.error = 41 }
    }
    when kind == 3 && cfgOperandType(p, f, view value) != 1 { p.error = 42 }
    when (kind == 2 || kind == 3) && (yes < 0 || yes >= p.functions[f].blocks) { p.error = 43 }
    when kind == 3 && (no < 0 || no >= p.functions[f].blocks) { p.error = 43 }
    when p.error == 0 {
        p.blocks@push(CfgBlock(first: first, count: count, term: kind, value: value, yes: yes, no: no))
    }
}

flow cfgReadFunction(p: edit CfgProgram, source: view Text, reader: edit NativeReader, f: Int) {
    nativeExpect(source, edit reader, "func")
    hold id = nativeId(source, edit reader, 102)
    hold name = nativeWord(source, edit reader)
    nativeExpect(source, edit reader, "params")
    hold params = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "result")
    hold result_type = cfgTypeOrUnit(p, source, edit reader)
    hold returned_ref = nativeNumber(source, edit reader)
    hold returned_mut = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "vars")
    hold vars = nativeNumber(source, edit reader)
    nativeExpect(source, edit reader, "blocks")
    hold blocks = nativeNumber(source, edit reader)
    nativeEndLine(source, edit reader)
    hold ref_mode = cfgReturnedRefMode(returned_ref, returned_mut)
    when reader.error != 0 || id != f || !cfgEncodedName(source, view name) || params < 0 || params > 16 || vars < params || blocks < 1 || blocks > 1024 || ref_mode == -2 || (ref_mode >= 0 && result_type == cfgUnitType()) || (result_type < 0 && result_type != cfgUnitType() && result_type != cfgTextType()) {
        p.error = 44
        give
    }
    // Calls and returns of aggregates require ABI-specific lowering. Keep
    // those unsupported until the by-value calling convention is verified.
    // Aggregate results travel through a hidden pointer (see native_cfg_emit).
    when ref_mode < 0 && result_type >= 2 && cfgTypeSize(p, result_type) > cfgMaxValueBytes() { p.error = 68; give }
    // A returned reference is one word: the referent's address.
    change value_type = result_type
    when ref_mode >= 0 { value_type = 0 }
    p.functions@push(CfgFunc(first_var: p.types_bool.length, vars: vars, first_block: p.blocks.length, blocks: blocks, params: params, result_bool: value_type == 1, result_unit: value_type == cfgUnitType(), result_text: value_type == cfgTextType(), result_type: value_type, result_ref: ref_mode, result_ref_type: result_type))
    p.types_bool@reserve(vars)
    p.types_code@reserve(vars)
    p.var_ref@reserve(vars)
    p.ref_root@reserve(vars)
    p.ref_field@reserve(vars)
    p.ref_sub@reserve(vars)
    p.ref_mut@reserve(vars)
    p.slot_start@reserve(vars)
    p.slot_count@reserve(vars)
    p.blocks@reserve(blocks)
    change next_slot = 0
    each i among 0..vars {
        nativeExpect(source, edit reader, "var")
        hold vid = nativeId(source, edit reader, 118)
        hold mode = nativeWord(source, edit reader)
        hold is_ref = nativeEquals(source, view mode, "ref")
        when !is_ref && !nativeEquals(source, view mode, "val") { reader.error = 14 }
        hold ty = cfgTypeOrUnit(p, source, edit reader)
        nativeEndLine(source, edit reader)
        hold unit_var = ty == cfgUnitType()
        hold text_var = ty == cfgTextType()
        when reader.error != 0 || vid != i || (ty < 0 && !unit_var && !text_var) || (i < params && !is_ref && unit_var) { p.error = 45; leave }
        // A local reference is defined by a `loan` (native_cfg_loan).
        when is_ref && unit_var { p.error = 96; leave }
        change size = cfgTypeSize(p, ty)
        when is_ref { size = 8 }
        hold count_slots = (size + 7) / 8
        when size < 1 || count_slots < 1 || next_slot + count_slots > x64MaxFrameSlots() { p.error = 69; leave }
        p.types_bool@push(ty == 1 && !is_ref)
        p.types_code@push(ty)
        p.var_ref@push(is_ref)
        p.ref_root@push(-1)
        p.ref_field@push(-1)
        p.ref_sub@push(-1)
        p.ref_mut@push(-1)
        p.slot_start@push(next_slot)
        p.slot_count@push(count_slots)
        next_slot += count_slots
    }
    when p.error != 0 { give }
    each i among 0..blocks {
        when p.error != 0 { leave }
        cfgReadBlock(edit p, source, edit reader, f, i)
    }
    when p.error != 0 { give }
    hold returned = cfgCheckReturnRefs(p, f)
    when returned != 0 { p.error = returned; give }
    nativeExpect(source, edit reader, "endfunc")
    nativeEndLine(source, edit reader)
    when reader.error != 0 { p.error = 46 }
}

expose flow cfgParse(source: view Text) => CfgProgram {
    change p = cfgEmpty()
    when source.byteLength == 0 || source.byteLength > cfgMaxSource() {
        p.error = 47
        give p
    }
    change r = nativeReaderNew()
    nativeExpect(source, edit r, "ELE-LIR")
    nativeExpect(source, edit r, "1")
    nativeEndLine(source, edit r)
    nativeExpect(source, edit r, "module")
    nativeExpect(source, edit r, "structs")
    hold structs = nativeNumber(source, edit r)
    change probe = NativeReader(offset: r.offset, error: 0)
    hold next_word = nativeWord(source, edit probe)
    change enums = 0
    when nativeEquals(source, view next_word, "enums") {
        nativeExpect(source, edit r, "enums")
        enums = nativeNumber(source, edit r)
    }
    change lists = 0
    change list_probe = NativeReader(offset: r.offset, error: 0)
    hold list_word = nativeWord(source, edit list_probe)
    when nativeEquals(source, view list_word, "lists") {
        nativeExpect(source, edit r, "lists")
        lists = nativeNumber(source, edit r)
    }
    nativeExpect(source, edit r, "funcs")
    hold functions = nativeNumber(source, edit r)
    nativeExpect(source, edit r, "main")
    hold main = nativeId(source, edit r, 102)
    nativeEndLine(source, edit r)
    when r.error != 0 || structs < 0 || enums < 0 || lists < 0 || 2 + structs + enums + lists >= cfgPlatformBase() || functions < 1 || main < 0 || main >= functions {
        p.error = 48
        give p
    }
    p.main = main
    p.decl_structs = structs
    p.decl_enums = enums
    p.decl_lists = lists
    p.structs@reserve(structs)
    p.enums@reserve(enums)
    p.list_elem@reserve(lists)
    p.functions@reserve(functions)
    each i among 0..structs {
        when p.error != 0 { leave }
        cfgReadStruct(edit p, source, edit r, i)
    }
    when p.error != 0 { give p }
    each i among 0..enums {
        when p.error != 0 { leave }
        cfgReadEnum(edit p, source, edit r, i)
    }
    when p.error != 0 { give p }
    // Layouts need every struct and enum (structs may name later enums).
    cfgLayoutDecls(edit p)
    when p.error != 0 { give p }
    each i among 0..lists {
        when p.error != 0 { leave }
        cfgReadList(edit p, source, edit r, i)
    }
    when p.error != 0 { give p }
    each i among 0..functions {
        when p.error != 0 { leave }
        cfgReadFunction(edit p, source, edit r, i)
    }
    when p.error != 0 { give p }
    nativeExpect(source, edit r, "end")
    nativeEndLine(source, edit r)
    when r.error != 0 || !nativeAtEnd(source, view r) {
        p.error = 49
        give p
    }
    when p.functions[main].params != 0 || p.functions[main].result_bool || p.functions[main].result_type >= 2 || p.functions[main].result_ref >= 0 { p.error = 50 }
    give p
}
