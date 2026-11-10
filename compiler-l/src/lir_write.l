import tokens
import sema_types
import lir_build
import lir_finish
import lir_emit

// Serialization of one verified function (protocol version 1).

fn lirBinaryName(op: Int) -> Text {
    if op == LIR_ADD { return "add" }
    if op == LIR_SUB { return "sub" }
    if op == LIR_MUL { return "mul" }
    if op == LIR_DIV { return "div" }
    if op == LIR_REM { return "rem" }
    if op == LIR_EQ { return "eq" }
    if op == LIR_NE { return "ne" }
    if op == LIR_LT { return "lt" }
    if op == LIR_LE { return "le" }
    if op == LIR_GT { return "gt" }
    return "ge"
}

fn lirFlagText(flag: Int) -> Text {
    if flag < 0 { return "-" }
    return "v{flag}"
}

fn lirInstText(l: &LirFn, source: &Text, lm: &LirModule, id: Int) -> Text {
    let inst = &l.insts[id]
    let dst = inst.dst
    let kind = inst.kind
    if kind == LIR_USE {
        let op = lirOperandText(l, source, inst.a)
        return "i use v{dst} {op}"
    }
    if kind == LIR_UNARY {
        let op = lirOperandText(l, source, inst.b)
        if inst.a == LIR_NOT { return "i unary v{dst} not {op}" }
        return "i unary v{dst} neg {op}"
    }
    if kind == LIR_BINARY {
        let name = lirBinaryName(inst.a)
        let a = lirOperandText(l, source, inst.b)
        let b = lirOperandText(l, source, inst.c)
        return "i binary v{dst} {name} {a} {b}"
    }
    if kind == LIR_CALL || kind == LIR_STRUCT {
        let target = inst.a
        let count = inst.c
        var out = "i call v{dst} f{target} {count}"
        if kind == LIR_STRUCT { out = "i struct v{dst} s{target} {count}" }
        for i in 0..count {
            let item = l.operands[inst.b + i]
            var piece = ""
            if kind == LIR_CALL { piece = lirArgText(l, source, item) } else { piece = lirOperandText(l, source, item) }
            out = "{out} {piece}"
        }
        return out
    }
    if kind == LIR_VARIANT {
        let variant = lm.en_first[inst.a] + inst.b
        if lm.variant_payload[variant] == 1 {
            let payload = lirOperandText(l, source, inst.c)
            return "i variant v{dst} e{inst.a} {inst.b} 1 {payload}"
        }
        return "i variant v{dst} e{inst.a} {inst.b} 0"
    }
    if kind == LIR_PAYLOAD {
        let place = lirPlaceText(l, inst.a)
        return "i payload v{dst} {place} e{inst.b} {inst.c}"
    }
    if kind == LIR_DISC {
        let place = lirPlaceText(l, inst.a)
        return "i disc v{dst} {place}"
    }
    if kind == LIR_LIST_LIT {
        let list = inst.a
        let count = inst.c
        var out = "i listlit v{dst} l{list} {count}"
        for i in 0..count {
            let item = l.operands[inst.b + i]
            let piece = lirOperandText(l, source, item)
            out = "{out} {piece}"
        }
        return out
    }
    if kind == LIR_READ {
        let place = lirPlaceText(l, inst.a)
        return "i read v{dst} {place}"
    }
    if kind == LIR_LOAN {
        let place = lirPlaceText(l, inst.a)
        let m = inst.b
        return "i loan v{dst} {place} {m}"
    }
    if kind == LIR_TEXTBUF {
        let capacity = inst.a
        return "i textbuf v{dst} {capacity}"
    }
    if kind == LIR_APPEND {
        let arg = lirArgText(l, source, inst.a)
        return "i append v{dst} {arg}"
    }
    if kind == LIR_STORE {
        let place = lirPlaceText(l, inst.a)
        let op = lirOperandText(l, source, inst.b)
        return "i store {place} {op}"
    }
    if kind == LIR_PRINT {
        let arg = lirArgText(l, source, inst.a)
        return "i print {arg}"
    }
    if kind == LIR_DROP {
        let flag = lirFlagText(inst.a)
        return "i drop v{dst} {flag}"
    }
    if kind == LIR_LEN {
        let place = lirPlaceText(l, inst.a)
        return "i len v{dst} {place}"
    }
    if kind == LIR_CAP {
        let place = lirPlaceText(l, inst.a)
        return "i cap v{dst} {place}"
    }
    if kind == LIR_LIST_PUSH {
        let place = lirPlaceText(l, inst.a)
        let op = lirOperandText(l, source, inst.b)
        return "i listpush {place} {op}"
    }
    if kind == LIR_LIST_POP {
        let place = lirPlaceText(l, inst.a)
        return "i listpop v{dst} {place}"
    }
    if kind == LIR_LIST_RESERVE {
        let place = lirPlaceText(l, inst.a)
        let op = lirOperandText(l, source, inst.b)
        return "i listreserve {place} {op}"
    }
    if kind == LIR_BYTE_AT {
        let place = lirPlaceText(l, inst.a)
        let op = lirOperandText(l, source, inst.b)
        return "i byteat v{dst} {place} {op}"
    }
    if kind == LIR_PLATFORM {
        let op_code = inst.a
        let first = inst.b
        let count = inst.c
        var op_name = "argcount"
        if op_code == 1 { op_name = "arg" }
        if op_code == 2 { op_name = "readtext" }
        if op_code == 3 { op_name = "printerror" }
        if op_code == 4 { op_name = "writebytes" }
        var out = "i platform v{dst} {op_name} {count}"
        for i in 0..count {
            let item = l.operands[first + i]
            let piece = lirArgText(l, source, item)
            out = "{out} {piece}"
        }
        return out
    }
    let place = lirPlaceText(l, inst.a)
    let flag = lirFlagText(inst.b)
    return "i dropfield {place} {flag}"
}

fn lirTermText(l: &LirFn, body: &LirBody, source: &Text, b: Int) -> Text {
    let kind = body.term[b]
    let ta = body.ta[b]
    let tb = body.tb[b]
    if kind == LIR_T_JUMP { return "t jump {ta}" }
    if kind == LIR_T_BRANCH {
        let op = lirOperandText(l, source, body.top[b])
        return "t branch {op} {ta} {tb}"
    }
    if kind == LIR_T_RETURN {
        let op = lirOperandText(l, source, body.top[b])
        return "t return {op}"
    }
    if kind == LIR_T_RETURNREF {
        let slot = body.top[b]
        return "t returnref v{slot}"
    }
    return "t unreachable"
}

fn lirWriteFunction(lines: &mut List<Text>, starts: &List<Int>, l: &LirFn, body: &LirBody, source: &Text, types: &TypeTable, lm: &LirModule, fn_index: Int, name_start: Int, name_end: Int) {
    let name = lirSpanText(source, name_start, name_end)
    let params = l.params
    let result = lirTypeCode(types, lm, lm.fn_ret[fn_index])
    var reference = 0
    var mutable = 0
    if lm.fn_ret_ref[fn_index] { reference = 1 }
    if lm.fn_ret_mut[fn_index] { mutable = 1 }
    let vars = l.vars.length
    let blocks = body.term.length
    lines.push("func f{fn_index} {name} params {params} result {result} {reference} {mutable} vars {vars} blocks {blocks}")
    for i in 0..vars {
        let ty = lirTypeCode(types, lm, l.vars[i].ty)
        if l.vars[i].is_ref { lines.push("var v{i} ref {ty}") } else { lines.push("var v{i} val {ty}") }
    }
    for b in 0..blocks {
        let count = body.count[b]
        lines.push("block {b} {count}")
        for i in body.first[b]..(body.first[b] + count) {
            let text = lirInstText(l, source, lm, body.order[i])
            let at = lirAtText(source, starts, l.insts[body.order[i]].at)
            lines.push("{text}{at}")
        }
        lines.push(lirTermText(l, body, source, b))
    }
    lines.push("endfunc")
}
