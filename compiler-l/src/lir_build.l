import sema_types

// ELE LIR (Stage 1): per-function arenas of typed variables, constants,
// places, call arguments and instructions. Instructions are emitted while
// the semantic pass walks the AST, into the CFG block that is current at
// that moment, and remember how many CFG events existed (`pos`) so the drop
// plan can later be spliced exactly where its events happened.
//
// Variables are not SSA: like Stage 0 block LIR, a variable may be assigned
// in several blocks; the verifier checks definite assignment before use.
// Types are Stage 1 semantic type ids; `is_ref` marks a variable holding a
// reference (`Ref(T)` in Stage 0 terms).

const LIR_NONE = -1000000000

// Constant kinds.
const LIR_CONST_INT = 0
const LIR_CONST_BOOL = 1
const LIR_CONST_UNIT = 2
const LIR_CONST_TEXT = 3

// Instruction kinds.
const LIR_USE = 0
const LIR_UNARY = 1
const LIR_BINARY = 2
const LIR_CALL = 3
const LIR_STRUCT = 4
const LIR_READ = 5
const LIR_LOAN = 6
const LIR_TEXTBUF = 7
const LIR_APPEND = 8
const LIR_STORE = 9
const LIR_PRINT = 10
const LIR_DROP = 11
const LIR_DROPFIELD = 12
const LIR_LEN = 13
const LIR_LIST_PUSH = 14
const LIR_LIST_POP = 15
const LIR_LIST_RESERVE = 16
const LIR_BYTE_AT = 17
const LIR_PLATFORM = 18
const LIR_LIST_LIT = 19
const LIR_CAP = 20
const LIR_VARIANT = 21
const LIR_DISC = 22
// Guarded Copy projection from the single active primitive enum payload.
const LIR_PAYLOAD = 23

const LIR_PLATFORM_ARG_COUNT = 0
const LIR_PLATFORM_ARG = 1
const LIR_PLATFORM_READ_TEXT = 2
const LIR_PLATFORM_PRINT_ERROR = 3

// Terminators.
const LIR_T_NONE = 0
const LIR_T_JUMP = 1
const LIR_T_BRANCH = 2
const LIR_T_RETURN = 3
const LIR_T_RETURNREF = 4
const LIR_T_UNREACHABLE = 5

// Operators (same order as Stage 0 `BinOp`).
const LIR_ADD = 0
const LIR_SUB = 1
const LIR_MUL = 2
const LIR_DIV = 3
const LIR_REM = 4
const LIR_EQ = 5
const LIR_NE = 6
const LIR_LT = 7
const LIR_LE = 8
const LIR_GT = 9
const LIR_GE = 10
const LIR_NEG = 0
const LIR_NOT = 1

struct LirVar {
    ty: Int
    is_ref: Bool
}

struct LirConst {
    kind: Int
    value: Int
    // Text: source span of the literal content (escapes not decoded).
    start: Int
    end: Int
}

// A place is a variable plus a chain of struct field projections (local
// field index within the struct). A place rooted at a reference variable
// denotes the referent.
struct LirPlace {
    root: Int
    parent: Int
    field: Int
}

struct LirArg {
    by_ref: Bool
    // Operand (by value) or place (by reference).
    value: Int
    mutable: Bool
}

struct LirInst {
    kind: Int
    dst: Int
    a: Int
    b: Int
    c: Int
    block: Int
    pos: Int
    // Source byte offset reported by runtime diagnostics.
    at: Int
}

struct LirFn {
    vars: List<LirVar>
    consts: List<LirConst>
    places: List<LirPlace>
    args: List<LirArg>
    operands: List<Int>
    insts: List<LirInst>
    // Move path -> variable that holds it (bindings and temporaries).
    path_var: List<Int>
    // Per CFG block: branch condition, swapped successors, return value.
    cond: List<Int>
    swap: List<Bool>
    ret: List<Int>
    ret_ref: List<Bool>
    // Value channel of the expression just inferred: a place or an operand.
    val: Int
    place: Int
    // Place borrowed by the last `&place` (reference argument or loan).
    borrowed: Int
    // First construct the LIR cannot represent (byte offset), or -1.
    unsupported: Int
    params: Int
    // Source offset of the expression or statement being lowered.
    at: Int
}

fn lirFnNew() -> LirFn {
    return LirFn(vars: List[], consts: List[], places: List[], args: List[], operands: List[], insts: List[], path_var: List[], cond: List[], swap: List[], ret: List[], ret_ref: List[], val: LIR_NONE, place: -1, borrowed: -1, unsupported: -1, params: 0, at: 0)
}

fn lirIsVar(operand: Int) -> Bool {
    return operand >= 0
}

fn lirConstId(operand: Int) -> Int {
    return -1 - operand
}

fn lirVar(l: &mut LirFn, ty: Int, is_ref: Bool) -> Int {
    l.vars.push(LirVar(ty: ty, is_ref: is_ref))
    return l.vars.length - 1
}

fn lirConst(l: &mut LirFn, kind: Int, value: Int, start: Int, end: Int) -> Int {
    l.consts.push(LirConst(kind: kind, value: value, start: start, end: end))
    return -l.consts.length
}

fn lirPlaceVar(l: &mut LirFn, slot: Int) -> Int {
    l.places.push(LirPlace(root: slot, parent: -1, field: -1))
    return l.places.length - 1
}

fn lirPlaceField(l: &mut LirFn, base: Int, field: Int) -> Int {
    let slot = l.places[base].root
    l.places.push(LirPlace(root: slot, parent: base, field: field))
    return l.places.length - 1
}

fn lirPlaceIndex(l: &mut LirFn, base: Int, index_var: Int) -> Int {
    let slot = l.places[base].root
    let f = 0 - 2 - index_var
    l.places.push(LirPlace(root: slot, parent: base, field: f))
    return l.places.length - 1
}

fn lirArg(l: &mut LirFn, by_ref: Bool, value: Int, mutable: Bool) -> Int {
    l.args.push(LirArg(by_ref: by_ref, value: value, mutable: mutable))
    return l.args.length - 1
}

fn lirEmit(l: &mut LirFn, kind: Int, dst: Int, a: Int, b: Int, c: Int, block: Int, pos: Int) {
    l.insts.push(LirInst(kind: kind, dst: dst, a: a, b: b, c: c, block: block, pos: pos, at: l.at))
}

// Make sure the per-block tables cover `blocks` CFG blocks.
fn lirBlocks(l: &mut LirFn, blocks: Int) {
    while l.cond.length < blocks {
        l.cond.push(LIR_NONE)
        l.swap.push(false)
        l.ret.push(LIR_NONE)
        l.ret_ref.push(false)
    }
}

fn lirBindPath(l: &mut LirFn, path: Int, slot: Int) {
    if path < 0 { return }
    while l.path_var.length <= path { l.path_var.push(-1) }
    l.path_var[path] = slot
}

fn lirPathVar(l: &LirFn, path: Int) -> Int {
    if path < 0 || path >= l.path_var.length { return -1 }
    return l.path_var[path]
}

fn lirMarkUnsupported(l: &mut LirFn, offset: Int) {
    if l.unsupported < 0 { l.unsupported = offset }
}

// Module tables shared by every function: signatures (parameters and
// result) in function index order and structs with their field types.
struct LirModule {
    fn_first: List<Int>
    fn_count: List<Int>
    param_ty: List<Int>
    param_ref: List<Bool>
    param_mut: List<Bool>
    fn_ret: List<Int>
    fn_ret_ref: List<Bool>
    fn_ret_mut: List<Bool>
    fn_decl: List<Int>
    st_first: List<Int>
    st_count: List<Int>
    field_ty: List<Int>
    st_decl: List<Int>
    list_elem: List<Int>
    unit_enums: List<Int>
    en_decl: List<Int>
    en_first: List<Int>
    en_count: List<Int>
    variant_payload: List<Int>
    variant_type: List<Int>
}

fn lirModuleNew() -> LirModule {
    return LirModule(fn_first: List[], fn_count: List[], param_ty: List[], param_ref: List[], param_mut: List[], fn_ret: List[], fn_ret_ref: List[], fn_ret_mut: List[], fn_decl: List[], st_first: List[], st_count: List[], field_ty: List[], st_decl: List[], list_elem: List[], unit_enums: List[], en_decl: List[], en_first: List[], en_count: List[], variant_payload: List[], variant_type: List[])
}

fn lirListRegister(lm: &mut LirModule, elem: Int) -> Int {
    for k in 0..lm.list_elem.length {
        if lm.list_elem[k] == elem { return k }
    }
    lm.list_elem.push(elem)
    return lm.list_elem.length - 1
}

fn lirIsUnitEnum(types: &TypeTable, lm: &LirModule, ty: Int) -> Bool {
    if ty < 0 || ty >= types.types.length { return false }
    match types.types[ty].kind {
        SemTypeKind.Enum => {
            let decl = types.types[ty].nominal_id
            for k in 0..lm.unit_enums.length {
                if lm.unit_enums[k] == decl { return true }
            }
            return false
        }
        _ => { return false }
    }
}

fn lirTypesCompat(types: &TypeTable, lm: &LirModule, a: Int, b: Int) -> Bool {
    // Nominal enums are not integers, including unit-only enums. Emitting
    // enum values as `ciN` is an obsolete Stage 1 shortcut, not a coercion.
    return a == b && a >= 0
}
