import lir_tokens
import native_cfg_defs
import native_cfg_types
import native_cfg_inst

// ELE-LIR CFG reader; split across modules to obey CORE-1 token limit.
fn cfgReadBlock(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int, b: Int) {
    nativeExpect(source, &mut reader, "block")
    let id = nativeNumber(source, &mut reader)
    let count = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || id != b || count < 0 || count > 100000 {
        p.error = 38
        return
    }
    let first = p.insts.length
    for i in 0..count {
        if p.error != 0 { break }
        cfgReadInst(&mut p, source, &mut reader, f)
    }
    if p.error != 0 { return }
    nativeExpect(source, &mut reader, "t")
    let keyword = nativeWord(source, &mut reader)
    var kind = 0
    var value = cfgEmptyOperand()
    var yes = -1
    var no = -1
    if nativeEquals(source, &keyword, "return") {
        kind = 1
        value = cfgOperand(&mut p, source, &mut reader)
    } else if nativeEquals(source, &keyword, "jump") {
        kind = 2
        yes = nativeNumber(source, &mut reader)
    } else if nativeEquals(source, &keyword, "branch") {
        kind = 3
        value = nativeOperand(source, &mut reader)
        yes = nativeNumber(source, &mut reader)
        no = nativeNumber(source, &mut reader)
    } else if nativeEquals(source, &keyword, "unreachable") {
        kind = 4
    } else {
        p.error = 39
    }
    nativeEndLineSpan(source, &mut reader)
    if reader.error != 0 { p.error = 40 }
    if kind == 1 {
        var expected = 0
        if p.functions[f].result_bool { expected = 1 }
        if p.functions[f].result_unit { expected = cfgUnitType() }
        if p.functions[f].result_text { expected = cfgTextType() }
        if cfgOperandType(p, f, &value) != expected { p.error = 41 }
    }
    if kind == 3 && cfgOperandType(p, f, &value) != 1 { p.error = 42 }
    if (kind == 2 || kind == 3) && (yes < 0 || yes >= p.functions[f].blocks) { p.error = 43 }
    if kind == 3 && (no < 0 || no >= p.functions[f].blocks) { p.error = 43 }
    if p.error == 0 {
        p.blocks.push(CfgBlock(first: first, count: count, term: kind, value: value, yes: yes, no: no))
    }
}

fn cfgReadFunction(p: &mut CfgProgram, source: &Text, reader: &mut NativeReader, f: Int) {
    nativeExpect(source, &mut reader, "func")
    let id = nativeId(source, &mut reader, 102)
    let name = nativeWord(source, &mut reader)
    nativeExpect(source, &mut reader, "params")
    let params = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "result")
    let result_type = cfgTypeOrUnit(p, source, &mut reader)
    let returned_ref = nativeNumber(source, &mut reader)
    let returned_mut = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "vars")
    let vars = nativeNumber(source, &mut reader)
    nativeExpect(source, &mut reader, "blocks")
    let blocks = nativeNumber(source, &mut reader)
    nativeEndLine(source, &mut reader)
    if reader.error != 0 || id != f || !cfgEncodedName(source, &name) || params < 0 || params > 16 || vars < params || vars > 256 || blocks < 1 || blocks > 1024 || returned_ref != 0 || returned_mut != 0 || (result_type < 0 && result_type != cfgUnitType() && result_type != cfgTextType()) {
        p.error = 44
        return
    }
    // Calls and returns of aggregates require ABI-specific lowering. Keep
    // those unsupported until the by-value calling convention is verified.
    if result_type >= 2 { p.error = 68; return }
    p.functions.push(CfgFunc(first_var: p.types_bool.length, vars: vars, first_block: p.blocks.length, blocks: blocks, params: params, result_bool: result_type == 1, result_unit: result_type == cfgUnitType(), result_text: result_type == cfgTextType()))
    var next_slot = 0
    for i in 0..vars {
        nativeExpect(source, &mut reader, "var")
        let vid = nativeId(source, &mut reader, 118)
        let mode = nativeWord(source, &mut reader)
        let is_ref = nativeEquals(source, &mode, "ref")
        if !is_ref && !nativeEquals(source, &mode, "val") { reader.error = 14 }
        let ty = cfgTypeOrUnit(p, source, &mut reader)
        nativeEndLine(source, &mut reader)
        let unit_var = ty == cfgUnitType()
        let text_var = ty == cfgTextType()
        if reader.error != 0 || vid != i || (ty < 0 && !unit_var && !text_var) || (i < params && !is_ref && (ty >= 2 || unit_var)) { p.error = 45; break }
        // References exist only as parameters: they cannot outlive the
        // caller's frame, so no local loan needs a lifetime analysis here.
        if is_ref && (i >= params || unit_var) { p.error = 96; break }
        var size = cfgTypeSize(p, ty)
        if is_ref { size = 8 }
        let count_slots = (size + 7) / 8
        if size < 1 || count_slots < 1 || next_slot + count_slots > 512 { p.error = 69; break }
        p.types_bool.push(ty == 1 && !is_ref)
        p.types_code.push(ty)
        p.var_ref.push(is_ref)
        p.slot_start.push(next_slot)
        p.slot_count.push(count_slots)
        next_slot += count_slots
    }
    if p.error != 0 { return }
    for i in 0..blocks {
        if p.error != 0 { break }
        cfgReadBlock(&mut p, source, &mut reader, f, i)
    }
    if p.error != 0 { return }
    nativeExpect(source, &mut reader, "endfunc")
    nativeEndLine(source, &mut reader)
    if reader.error != 0 { p.error = 46 }
}

pub fn cfgParse(source: &Text) -> CfgProgram {
    var p = cfgEmpty()
    if source.byteLength == 0 || source.byteLength > 1048576 {
        p.error = 47
        return p
    }
    var r = nativeReaderNew()
    nativeExpect(source, &mut r, "ELE-LIR")
    nativeExpect(source, &mut r, "1")
    nativeEndLine(source, &mut r)
    nativeExpect(source, &mut r, "module")
    nativeExpect(source, &mut r, "structs")
    let structs = nativeNumber(source, &mut r)
    var probe = NativeReader(offset: r.offset, error: 0)
    let next_word = nativeWord(source, &mut probe)
    var enums = 0
    if nativeEquals(source, &next_word, "enums") {
        nativeExpect(source, &mut r, "enums")
        enums = nativeNumber(source, &mut r)
    }
    nativeExpect(source, &mut r, "funcs")
    let functions = nativeNumber(source, &mut r)
    nativeExpect(source, &mut r, "main")
    let main = nativeId(source, &mut r, 102)
    nativeEndLine(source, &mut r)
    if r.error != 0 || structs < 0 || structs > 16 || enums < 0 || enums > 16 || functions < 1 || functions > 256 || main < 0 || main >= functions {
        p.error = 48
        return p
    }
    p.main = main
    for i in 0..structs {
        if p.error != 0 { break }
        cfgReadStruct(&mut p, source, &mut r, i)
    }
    if p.error != 0 { return p }
    for i in 0..enums {
        if p.error != 0 { break }
        cfgReadEnum(&mut p, source, &mut r, i)
    }
    if p.error != 0 { return p }
    for i in 0..functions {
        if p.error != 0 { break }
        cfgReadFunction(&mut p, source, &mut r, i)
    }
    if p.error != 0 { return p }
    nativeExpect(source, &mut r, "end")
    nativeEndLine(source, &mut r)
    if r.error != 0 || !nativeAtEnd(source, &r) {
        p.error = 49
        return p
    }
    if p.functions[main].params != 0 || p.functions[main].result_bool { p.error = 50 }
    return p
}
