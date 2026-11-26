take lir_build
take lir_finish

// Test hook (`sema-l archivo.l --lir-patch parche.txt`): rewrite a lowered
// function with forged instructions before the verifier sees it, so the
// tests can hand the ELE verifier exactly the adversarial LIR they hand the
// Rust validator. The patch never bypasses verification: the patched
// function is verified like any other and only written when it is accepted.
//
// One operation per line, instructions and terminators in the textual
// ELE-LIR 1 syntax (`lir_write.l`), without the `@line:col` suffix:
//   f <fn>                      following operations apply to function fN
//   set <block> <j> <inst>      replace the j-th instruction of the block
//   ins <block> <j> <inst>      insert before the j-th instruction (j may
//                               be the block's count: append)
//   del <block> <j>             delete the j-th instruction of the block
//   term <block> <term>         replace the terminator of the block
// Places, constants and call arguments of a forged instruction are created
// fresh; variable ids must exist. Text constants are not supported.

expose shape LirPatchWord {
    start: Int
    end: Int
}

expose shape LirPatchReader {
    pos: Int
    error: Int
}

flow lirPatchWord(src: view Text, r: edit LirPatchReader) => LirPatchWord {
    change p = r.pos
    during p < src.byteLength && src@byteAt(p) == 32 { p += 1 }
    hold start = p
    during p < src.byteLength {
        hold b = src@byteAt(p)
        when b == 32 || b == 10 || b == 13 { leave }
        p += 1
    }
    r.pos = p
    when p == start { r.error = 1 }
    give LirPatchWord(start: start, end: p)
}

flow lirPatchEq(src: view Text, w: view LirPatchWord, literal: Text) => Bool {
    when w.end - w.start != literal.byteLength { give false }
    each i among 0..literal.byteLength {
        when src@byteAt(w.start + i) != literal@byteAt(i) { give false }
    }
    give true
}

// Decimal number of `w` after `skip` prefix bytes; an optional leading `-`.
flow lirPatchDecimal(src: view Text, r: edit LirPatchReader, w: view LirPatchWord, skip: Int) => Int {
    change p = w.start + skip
    change negative = false
    when p < w.end && src@byteAt(p) == 45 {
        negative = true
        p += 1
    }
    when p >= w.end {
        r.error = 2
        give 0
    }
    change n = 0
    during p < w.end {
        hold b = src@byteAt(p)
        when b < 48 || b > 57 || n > 100000000 {
            r.error = 2
            give 0
        }
        n = n * 10 + b - 48
        p += 1
    }
    when negative { give 0 - n }
    give n
}

flow lirPatchNumber(src: view Text, r: edit LirPatchReader) => Int {
    hold w = lirPatchWord(src, edit r)
    give lirPatchDecimal(src, edit r, view w, 0)
}

// `<prefix><n>` with a non-negative n below `bound`.
flow lirPatchId(src: view Text, r: edit LirPatchReader, prefix: Int, bound: Int) => Int {
    hold w = lirPatchWord(src, edit r)
    when w.start >= w.end || src@byteAt(w.start) != prefix {
        r.error = 3
        give -1
    }
    hold n = lirPatchDecimal(src, edit r, view w, 1)
    when n < 0 || n >= bound {
        r.error = 3
        give -1
    }
    give n
}

flow lirPatchOperand(src: view Text, r: edit LirPatchReader, l: edit LirFn) => Int {
    hold w = lirPatchWord(src, edit r)
    when w.start >= w.end {
        r.error = 4
        give LIR_NONE
    }
    hold first = src@byteAt(w.start)
    when first == 118 {
        hold n = lirPatchDecimal(src, edit r, view w, 1)
        when n < 0 || n >= l.vars.length {
            r.error = 4
            give LIR_NONE
        }
        give n
    }
    when lirPatchEq(src, view w, "cb0") { give lirConst(edit l, LIR_CONST_BOOL, 0, 0, 0) }
    when lirPatchEq(src, view w, "cb1") { give lirConst(edit l, LIR_CONST_BOOL, 1, 0, 0) }
    when lirPatchEq(src, view w, "cu") { give lirConst(edit l, LIR_CONST_UNIT, 0, 0, 0) }
    when w.end - w.start >= 3 && first == 99 && src@byteAt(w.start + 1) == 105 {
        hold n = lirPatchDecimal(src, edit r, view w, 2)
        give lirConst(edit l, LIR_CONST_INT, n, 0, 0)
    }
    r.error = 4
    give LIR_NONE
}

// Digits starting at `p`; the value is left in `out.start` and the
// position after them in `out.end` (out.end == p: no digits).
flow lirPatchDigits(src: view Text, p: Int, end: Int, out: edit LirPatchWord) {
    change q = p
    change n = 0
    during q < end && src@byteAt(q) >= 48 && src@byteAt(q) <= 57 && n < 100000000 {
        n = n * 10 + src@byteAt(q) - 48
        q += 1
    }
    out.start = n
    out.end = q
}

// `p<var>(.<field>)*([v<idx>])*` as fresh places of `l`.
flow lirPatchPlace(src: view Text, r: edit LirPatchReader, l: edit LirFn) => Int {
    hold w = lirPatchWord(src, edit r)
    when w.end - w.start < 2 || src@byteAt(w.start) != 112 {
        r.error = 5
        give -1
    }
    change number = LirPatchWord(start: 0, end: 0)
    lirPatchDigits(src, w.start + 1, w.end, edit number)
    when number.end == w.start + 1 || number.start >= l.vars.length {
        r.error = 5
        give -1
    }
    change place = lirPlaceVar(edit l, number.start)
    change pos = number.end
    during pos < w.end && r.error == 0 {
        hold b = src@byteAt(pos)
        when b == 46 {
            lirPatchDigits(src, pos + 1, w.end, edit number)
            when number.end == pos + 1 {
                r.error = 5
                give -1
            }
            place = lirPlaceField(edit l, place, number.start)
            pos = number.end
        } otherwise when b == 91 && pos + 1 < w.end && src@byteAt(pos + 1) == 118 {
            lirPatchDigits(src, pos + 2, w.end, edit number)
            when number.end == pos + 2 || number.end >= w.end || src@byteAt(number.end) != 93 || number.start >= l.vars.length {
                r.error = 5
                give -1
            }
            place = lirPlaceIndex(edit l, place, number.start)
            pos = number.end + 1
        } otherwise {
            r.error = 5
            give -1
        }
    }
    give place
}

flow lirPatchFlag(src: view Text, r: edit LirPatchReader, l: edit LirFn) => Int {
    hold save = r.pos
    hold w = lirPatchWord(src, edit r)
    when lirPatchEq(src, view w, "-") { give -1 }
    r.pos = save
    give lirPatchId(src, edit r, 118, l.vars.length)
}

flow lirPatchArg(src: view Text, r: edit LirPatchReader, l: edit LirFn) => Int {
    hold w = lirPatchWord(src, edit r)
    when lirPatchEq(src, view w, "val") {
        hold value = lirPatchOperand(src, edit r, edit l)
        give lirArg(edit l, false, value, false)
    }
    when lirPatchEq(src, view w, "ref") {
        hold place = lirPatchPlace(src, edit r, edit l)
        hold mode = lirPatchNumber(src, edit r)
        give lirArg(edit l, true, place, mode == 1)
    }
    r.error = 6
    give -1
}

flow lirPatchBinary(src: view Text, w: view LirPatchWord) => Int {
    when lirPatchEq(src, w, "add") { give LIR_ADD }
    when lirPatchEq(src, w, "sub") { give LIR_SUB }
    when lirPatchEq(src, w, "mul") { give LIR_MUL }
    when lirPatchEq(src, w, "div") { give LIR_DIV }
    when lirPatchEq(src, w, "rem") { give LIR_REM }
    when lirPatchEq(src, w, "eq") { give LIR_EQ }
    when lirPatchEq(src, w, "ne") { give LIR_NE }
    when lirPatchEq(src, w, "lt") { give LIR_LT }
    when lirPatchEq(src, w, "le") { give LIR_LE }
    when lirPatchEq(src, w, "gt") { give LIR_GT }
    when lirPatchEq(src, w, "ge") { give LIR_GE }
    when lirPatchEq(src, w, "band") { give LIR_BAND }
    when lirPatchEq(src, w, "bor") { give LIR_BOR }
    when lirPatchEq(src, w, "bxor") { give LIR_BXOR }
    when lirPatchEq(src, w, "shl") { give LIR_SHL }
    when lirPatchEq(src, w, "shr") { give LIR_SHR }
    when lirPatchEq(src, w, "wadd") { give LIR_WADD }
    when lirPatchEq(src, w, "wsub") { give LIR_WSUB }
    when lirPatchEq(src, w, "wmul") { give LIR_WMUL }
    give -1
}

// One forged instruction `i <kind> ...` into `inst` (kind, dst, a, b, c).
flow lirPatchInst(src: view Text, r: edit LirPatchReader, l: edit LirFn, inst: edit LirInst) {
    hold head = lirPatchWord(src, edit r)
    when !lirPatchEq(src, view head, "i") {
        r.error = 7
        give
    }
    hold w = lirPatchWord(src, edit r)
    hold vars = l.vars.length
    inst.dst = -1
    inst.a = -1
    inst.b = -1
    inst.c = -1
    when lirPatchEq(src, view w, "use") {
        inst.kind = LIR_USE
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchOperand(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "unary") {
        inst.kind = LIR_UNARY
        inst.dst = lirPatchId(src, edit r, 118, vars)
        hold op = lirPatchWord(src, edit r)
        inst.a = LIR_NEG
        when lirPatchEq(src, view op, "not") { inst.a = LIR_NOT }
        when lirPatchEq(src, view op, "itof") { inst.a = LIR_ITOF }
        when lirPatchEq(src, view op, "ftoi") { inst.a = LIR_FTOI }
        when lirPatchEq(src, view op, "bnot") { inst.a = LIR_BNOT }
        inst.b = lirPatchOperand(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "binary") {
        inst.kind = LIR_BINARY
        inst.dst = lirPatchId(src, edit r, 118, vars)
        hold op = lirPatchWord(src, edit r)
        inst.a = lirPatchBinary(src, view op)
        when inst.a < 0 { r.error = 8 }
        inst.b = lirPatchOperand(src, edit r, edit l)
        inst.c = lirPatchOperand(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "call") {
        inst.kind = LIR_CALL
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchId(src, edit r, 102, 1000000)
        hold count = lirPatchNumber(src, edit r)
        change ids: List of[Int] = List[]
        each i among 0..count {
            ids@push(lirPatchArg(src, edit r, edit l))
        }
        inst.b = l.operands.length
        inst.c = count
        each i among 0..ids.length { l.operands@push(ids[i]) }
    } otherwise when lirPatchEq(src, view w, "read") {
        inst.kind = LIR_READ
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchPlace(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "loan") {
        inst.kind = LIR_LOAN
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchPlace(src, edit r, edit l)
        inst.b = lirPatchNumber(src, edit r)
    } otherwise when lirPatchEq(src, view w, "store") {
        inst.kind = LIR_STORE
        inst.a = lirPatchPlace(src, edit r, edit l)
        inst.b = lirPatchOperand(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "print") {
        inst.kind = LIR_PRINT
        inst.a = lirPatchArg(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "drop") {
        inst.kind = LIR_DROP
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchFlag(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "dropfield") {
        inst.kind = LIR_DROPFIELD
        inst.a = lirPatchPlace(src, edit r, edit l)
        inst.b = lirPatchFlag(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "disc") {
        inst.kind = LIR_DISC
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchPlace(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "payload") {
        inst.kind = LIR_PAYLOAD
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchPlace(src, edit r, edit l)
        inst.b = lirPatchId(src, edit r, 101, 1000000)
        inst.c = lirPatchNumber(src, edit r)
    } otherwise when lirPatchEq(src, view w, "variant") {
        inst.kind = LIR_VARIANT
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchId(src, edit r, 101, 1000000)
        inst.b = lirPatchNumber(src, edit r)
        inst.c = LIR_NONE
        when lirPatchNumber(src, edit r) == 1 { inst.c = lirPatchOperand(src, edit r, edit l) }
    } otherwise when lirPatchEq(src, view w, "len") {
        inst.kind = LIR_LEN
        inst.dst = lirPatchId(src, edit r, 118, vars)
        inst.a = lirPatchPlace(src, edit r, edit l)
    } otherwise {
        r.error = 9
    }
}

flow lirPatchTerm(src: view Text, r: edit LirPatchReader, l: edit LirFn, body: edit LirBody, b: Int) {
    hold head = lirPatchWord(src, edit r)
    when !lirPatchEq(src, view head, "t") {
        r.error = 10
        give
    }
    hold w = lirPatchWord(src, edit r)
    hold blocks = body.term.length
    body.ta[b] = 0
    body.tb[b] = 0
    body.top[b] = LIR_NONE
    when lirPatchEq(src, view w, "jump") {
        body.term[b] = LIR_T_JUMP
        body.ta[b] = lirPatchNumber(src, edit r)
    } otherwise when lirPatchEq(src, view w, "branch") {
        body.term[b] = LIR_T_BRANCH
        body.top[b] = lirPatchOperand(src, edit r, edit l)
        body.ta[b] = lirPatchNumber(src, edit r)
        body.tb[b] = lirPatchNumber(src, edit r)
    } otherwise when lirPatchEq(src, view w, "return") {
        body.term[b] = LIR_T_RETURN
        body.top[b] = lirPatchOperand(src, edit r, edit l)
    } otherwise when lirPatchEq(src, view w, "returnref") {
        body.term[b] = LIR_T_RETURNREF
        body.top[b] = lirPatchId(src, edit r, 118, l.vars.length)
    } otherwise when lirPatchEq(src, view w, "unreachable") {
        body.term[b] = LIR_T_UNREACHABLE
    } otherwise {
        r.error = 10
    }
    when body.ta[b] < 0 || body.ta[b] >= blocks || body.tb[b] < 0 || body.tb[b] >= blocks { r.error = 10 }
}

// Insert (`delta` 1, before order position `at`) or delete (`delta` -1, at
// position `at`) one entry of block `b` and shift the blocks after it.
flow lirPatchSplice(body: edit LirBody, b: Int, at: Int, id: Int, delta: Int) {
    change order: List of[Int] = List[]
    each i among 0..body.order.length {
        when i == at && delta > 0 { order@push(id) }
        when !(i == at && delta < 0) { order@push(body.order[i]) }
    }
    when at == body.order.length && delta > 0 { order@push(id) }
    body.order = order
    each k among 0..body.first.length {
        when k != b && (body.first[k] > at || (delta > 0 && body.first[k] == at)) {
            body.first[k] = body.first[k] + delta
        }
    }
    body.count[b] = body.count[b] + delta
}

// Apply the operations of `patch` aimed at function `fn_index`. Returns 0,
// or the 1-based line of the first malformed operation.
expose flow lirApplyPatch(l: edit LirFn, body: edit LirBody, patch: view Text, fn_index: Int) => Int {
    change r = LirPatchReader(pos: 0, error: 0)
    change line = 0
    change target = -1
    during r.pos < patch.byteLength {
        line += 1
        // Skip blank lines (and the CR of a CRLF line end).
        change p = r.pos
        during p < patch.byteLength && (patch@byteAt(p) == 32 || patch@byteAt(p) == 13) { p += 1 }
        when p < patch.byteLength && patch@byteAt(p) == 10 {
            r.pos = p + 1
            proceed
        }
        when p >= patch.byteLength { leave }
        hold op = lirPatchWord(patch, edit r)
        when lirPatchEq(patch, view op, "f") {
            target = lirPatchNumber(patch, edit r)
        } otherwise when target != fn_index {
            // An operation for another function: skip the line.
            during r.pos < patch.byteLength && patch@byteAt(r.pos) != 10 { r.pos += 1 }
        } otherwise {
            hold blocks = body.term.length
            hold b = lirPatchNumber(patch, edit r)
            when r.error != 0 || b < 0 || b >= blocks { give line }
            when lirPatchEq(patch, view op, "term") {
                lirPatchTerm(patch, edit r, edit l, edit body, b)
            } otherwise {
                hold j = lirPatchNumber(patch, edit r)
                hold insert = lirPatchEq(patch, view op, "ins")
                change limit = body.count[b]
                when insert { limit += 1 }
                when r.error != 0 || j < 0 || j >= limit { give line }
                hold at = body.first[b] + j
                when lirPatchEq(patch, view op, "del") {
                    lirPatchSplice(edit body, b, at, -1, -1)
                } otherwise when insert || lirPatchEq(patch, view op, "set") {
                    change near = 0
                    when at < body.order.length { near = l.insts[body.order[at]].at }
                    change inst = LirInst(kind: -1, dst: -1, a: -1, b: -1, c: -1, block: b, pos: 0, at: near)
                    lirPatchInst(patch, edit r, edit l, edit inst)
                    when r.error != 0 { give line }
                    when insert {
                        l.insts@push(inst)
                        lirPatchSplice(edit body, b, at, l.insts.length - 1, 1)
                    } otherwise {
                        hold id = body.order[at]
                        inst.pos = l.insts[id].pos
                        l.insts[id] = inst
                    }
                } otherwise {
                    give line
                }
            }
        }
        when r.error != 0 { give line }
        // Only the end of the line may follow an operation.
        during r.pos < patch.byteLength && (patch@byteAt(r.pos) == 32 || patch@byteAt(r.pos) == 13) { r.pos += 1 }
        when r.pos < patch.byteLength && patch@byteAt(r.pos) != 10 { give line }
        when r.pos < patch.byteLength { r.pos += 1 }
    }
    give 0
}
