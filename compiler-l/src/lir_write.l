take tokens
take sema_types
take lir_build
take lir_finish
take lir_emit

// Serialization of one verified function (protocol version 1).

flow lirBinaryName(op: Int) => Text {
    when op == LIR_ADD { give "add" }
    when op == LIR_SUB { give "sub" }
    when op == LIR_MUL { give "mul" }
    when op == LIR_DIV { give "div" }
    when op == LIR_REM { give "rem" }
    when op == LIR_EQ { give "eq" }
    when op == LIR_NE { give "ne" }
    when op == LIR_LT { give "lt" }
    when op == LIR_LE { give "le" }
    when op == LIR_GT { give "gt" }
    when op == LIR_BAND { give "band" }
    when op == LIR_BOR { give "bor" }
    when op == LIR_BXOR { give "bxor" }
    when op == LIR_SHL { give "shl" }
    when op == LIR_SHR { give "shr" }
    when op == LIR_WADD { give "wadd" }
    when op == LIR_WSUB { give "wsub" }
    when op == LIR_WMUL { give "wmul" }
    give "ge"
}

flow lirFlagText(flag: Int) => Text {
    when flag < 0 { give "-" }
    give "v{flag}"
}

flow lirInstText(l: view LirFn, source: view Text, lm: view LirModule, id: Int) => Text {
    hold inst = view l.insts[id]
    hold dst = inst.dst
    hold kind = inst.kind
    when kind == LIR_USE {
        hold op = lirOperandText(l, source, inst.a)
        give "i use v{dst} {op}"
    }
    when kind == LIR_UNARY {
        hold op = lirOperandText(l, source, inst.b)
        when inst.a == LIR_NOT { give "i unary v{dst} not {op}" }
        when inst.a == LIR_ITOF { give "i unary v{dst} itof {op}" }
        when inst.a == LIR_FTOI { give "i unary v{dst} ftoi {op}" }
        when inst.a == LIR_BNOT { give "i unary v{dst} bnot {op}" }
        give "i unary v{dst} neg {op}"
    }
    when kind == LIR_BINARY {
        hold name = lirBinaryName(inst.a)
        hold a = lirOperandText(l, source, inst.b)
        hold b = lirOperandText(l, source, inst.c)
        give "i binary v{dst} {name} {a} {b}"
    }
    when kind == LIR_CALL || kind == LIR_STRUCT {
        hold target = inst.a
        hold count = inst.c
        change out = "i call v{dst} f{target} {count}"
        when kind == LIR_STRUCT { out = "i struct v{dst} s{target} {count}" }
        each i among 0..count {
            hold item = l.operands[inst.b + i]
            change piece = ""
            when kind == LIR_CALL { piece = lirArgText(l, source, item) } otherwise { piece = lirOperandText(l, source, item) }
            out = "{out} {piece}"
        }
        give out
    }
    when kind == LIR_VARIANT {
        hold variant = lm.en_first[inst.a] + inst.b
        when lm.variant_payload[variant] == 1 {
            hold payload = lirOperandText(l, source, inst.c)
            give "i variant v{dst} e{inst.a} {inst.b} 1 {payload}"
        }
        give "i variant v{dst} e{inst.a} {inst.b} 0"
    }
    when kind == LIR_PAYLOAD {
        hold place = lirPlaceText(l, inst.a)
        give "i payload v{dst} {place} e{inst.b} {inst.c}"
    }
    when kind == LIR_DISC {
        hold place = lirPlaceText(l, inst.a)
        give "i disc v{dst} {place}"
    }
    when kind == LIR_LIST_LIT {
        hold list = inst.a
        hold count = inst.c
        change out = "i listlit v{dst} l{list} {count}"
        each i among 0..count {
            hold item = l.operands[inst.b + i]
            hold piece = lirOperandText(l, source, item)
            out = "{out} {piece}"
        }
        give out
    }
    when kind == LIR_READ {
        hold place = lirPlaceText(l, inst.a)
        give "i read v{dst} {place}"
    }
    when kind == LIR_LOAN {
        hold place = lirPlaceText(l, inst.a)
        hold m = inst.b
        give "i loan v{dst} {place} {m}"
    }
    when kind == LIR_TEXTBUF {
        hold capacity = inst.a
        give "i textbuf v{dst} {capacity}"
    }
    when kind == LIR_APPEND {
        hold arg = lirArgText(l, source, inst.a)
        give "i append v{dst} {arg}"
    }
    when kind == LIR_STORE {
        hold place = lirPlaceText(l, inst.a)
        hold op = lirOperandText(l, source, inst.b)
        give "i store {place} {op}"
    }
    when kind == LIR_PRINT {
        hold arg = lirArgText(l, source, inst.a)
        give "i print {arg}"
    }
    when kind == LIR_DROP {
        hold flag = lirFlagText(inst.a)
        give "i drop v{dst} {flag}"
    }
    when kind == LIR_LEN {
        hold place = lirPlaceText(l, inst.a)
        give "i len v{dst} {place}"
    }
    when kind == LIR_CAP {
        hold place = lirPlaceText(l, inst.a)
        give "i cap v{dst} {place}"
    }
    when kind == LIR_LIST_PUSH {
        hold place = lirPlaceText(l, inst.a)
        hold op = lirOperandText(l, source, inst.b)
        give "i listpush {place} {op}"
    }
    when kind == LIR_LIST_POP {
        hold place = lirPlaceText(l, inst.a)
        give "i listpop v{dst} {place}"
    }
    when kind == LIR_LIST_RESERVE {
        hold place = lirPlaceText(l, inst.a)
        hold op = lirOperandText(l, source, inst.b)
        give "i listreserve {place} {op}"
    }
    when kind == LIR_BYTE_AT {
        hold place = lirPlaceText(l, inst.a)
        hold op = lirOperandText(l, source, inst.b)
        give "i byteat v{dst} {place} {op}"
    }
    when kind == LIR_PLATFORM {
        hold op_code = inst.a
        hold first = inst.b
        hold count = inst.c
        change op_name = "argcount"
        when op_code == 1 { op_name = "arg" }
        when op_code == 2 { op_name = "readtext" }
        when op_code == 3 { op_name = "printerror" }
        when op_code == 4 { op_name = "writebytes" }
        when op_code == 5 { op_name = "samefile" }
        when op_code == 6 { op_name = "consolemode" }
        when op_code == 7 { op_name = "readevent" }
        when op_code == 8 { op_name = "writeconsole" }
        when op_code == 9 { op_name = "fileopen" }
        when op_code == 10 { op_name = "fileread" }
        when op_code == 11 { op_name = "filewrite" }
        when op_code == 12 { op_name = "fileseek" }
        when op_code == 13 { op_name = "filesize" }
        when op_code == 14 { op_name = "fileflush" }
        when op_code == 15 { op_name = "fileclose" }
        when op_code == 16 { op_name = "filestatus" }
        when op_code == 17 { op_name = "windowopen" }
        when op_code == 18 { op_name = "windowstatus" }
        when op_code == 19 { op_name = "windownext" }
        when op_code == 20 { op_name = "windowfill" }
        when op_code == 21 { op_name = "windowtext" }
        when op_code == 22 { op_name = "windowpresent" }
        when op_code == 23 { op_name = "windowsend" }
        when op_code == 24 { op_name = "windowpixel" }
        when op_code == 25 { op_name = "windowclose" }
        when op_code == 26 { op_name = "windowcell" }
        when op_code == 27 { op_name = "windowtextbytes" }
        when op_code == 28 { op_name = "clipboardwrite" }
        when op_code == 29 { op_name = "clipboardread" }
        when op_code == 30 { op_name = "textfrombytes" }
        when op_code >= 31 { op_name = lirIntrinsicName(op_code) }
        change out ="i platform v{dst} {op_name} {count}"
        each i among 0..count {
            hold item = l.operands[first + i]
            hold piece = lirArgText(l, source, item)
            out = "{out} {piece}"
        }
        give out
    }
    hold place = lirPlaceText(l, inst.a)
    hold flag = lirFlagText(inst.b)
    give "i dropfield {place} {flag}"
}

flow lirTermText(l: view LirFn, body: view LirBody, source: view Text, b: Int) => Text {
    hold kind = body.term[b]
    hold ta = body.ta[b]
    hold tb = body.tb[b]
    when kind == LIR_T_JUMP { give "t jump {ta}" }
    when kind == LIR_T_BRANCH {
        hold op = lirOperandText(l, source, body.top[b])
        give "t branch {op} {ta} {tb}"
    }
    when kind == LIR_T_RETURN {
        hold op = lirOperandText(l, source, body.top[b])
        give "t return {op}"
    }
    when kind == LIR_T_RETURNREF {
        hold slot = body.top[b]
        give "t returnref v{slot}"
    }
    give "t unreachable"
}

expose flow lirWriteFunction(lines: edit List of[Text], starts: view List of[Int], l: view LirFn, body: view LirBody, source: view Text, types: view TypeTable, lm: view LirModule, fn_index: Int, name_start: Int, name_end: Int) {
    hold name = lirSpanText(source, name_start, name_end)
    hold params = l.params
    hold result = lirTypeCode(types, lm, lm.fn_ret[fn_index])
    change reference = 0
    change mutable = 0
    when lm.fn_ret_ref[fn_index] { reference = 1 }
    when lm.fn_ret_mut[fn_index] { mutable = 1 }
    hold vars = l.vars.length
    hold blocks = body.term.length
    lines@push("func f{fn_index} {name} params {params} result {result} {reference} {mutable} vars {vars} blocks {blocks}")
    each i among 0..vars {
        hold ty = lirTypeCode(types, lm, l.vars[i].ty)
        when l.vars[i].is_ref { lines@push("var v{i} ref {ty}") } otherwise { lines@push("var v{i} val {ty}") }
    }
    each b among 0..blocks {
        hold count = body.count[b]
        lines@push("block {b} {count}")
        each i among body.first[b]..(body.first[b] + count) {
            hold text = lirInstText(l, source, lm, body.order[i])
            hold at = lirAtText(source, starts, l.insts[body.order[i]].at)
            lines@push("{text}{at}")
        }
        lines@push(lirTermText(l, body, source, b))
    }
    lines@push("endfunc")
}
