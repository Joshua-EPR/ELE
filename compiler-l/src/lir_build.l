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

pub const LIR_NONE = -1000000000

// Constant kinds.
pub const LIR_CONST_INT = 0
pub const LIR_CONST_BOOL = 1
pub const LIR_CONST_UNIT = 2
pub const LIR_CONST_TEXT = 3

// Instruction kinds.
pub const LIR_USE = 0
pub const LIR_UNARY = 1
pub const LIR_BINARY = 2
pub const LIR_CALL = 3
pub const LIR_STRUCT = 4
pub const LIR_READ = 5
pub const LIR_LOAN = 6
pub const LIR_TEXTBUF = 7
pub const LIR_APPEND = 8
pub const LIR_STORE = 9
pub const LIR_PRINT = 10
pub const LIR_DROP = 11
pub const LIR_DROPFIELD = 12
pub const LIR_LEN = 13
pub const LIR_LIST_PUSH = 14
pub const LIR_LIST_POP = 15
pub const LIR_LIST_RESERVE = 16
pub const LIR_BYTE_AT = 17
pub const LIR_PLATFORM = 18
pub const LIR_LIST_LIT = 19
pub const LIR_CAP = 20
pub const LIR_VARIANT = 21
pub const LIR_DISC = 22
// Guarded Copy projection from the single active primitive enum payload.
pub const LIR_PAYLOAD = 23

pub const LIR_PLATFORM_ARG_COUNT = 0
pub const LIR_PLATFORM_ARG = 1
pub const LIR_PLATFORM_READ_TEXT = 2
pub const LIR_PLATFORM_PRINT_ERROR = 3

// Terminators.
pub const LIR_T_NONE = 0
pub const LIR_T_JUMP = 1
pub const LIR_T_BRANCH = 2
pub const LIR_T_RETURN = 3
pub const LIR_T_RETURNREF = 4
pub const LIR_T_UNREACHABLE = 5

// Operators (same order as Stage 0 `BinOp`).
pub const LIR_ADD = 0
pub const LIR_SUB = 1
pub const LIR_MUL = 2
pub const LIR_DIV = 3
pub const LIR_REM = 4
pub const LIR_EQ = 5
pub const LIR_NE = 6
pub const LIR_LT = 7
pub const LIR_LE = 8
pub const LIR_GT = 9
pub const LIR_GE = 10
pub const LIR_NEG = 0
pub const LIR_NOT = 1

pub struct LirVar {
    ty: Int
    is_ref: Bool
}

pub struct LirConst {
    kind: Int
    value: Int
    // Text: source span of the literal content (escapes not decoded).
    start: Int
    end: Int
}

// A place is a variable plus a chain of struct field projections (local
// field index within the struct). A place rooted at a reference variable
// denotes the referent.
pub struct LirPlace {
    root: Int
    parent: Int
    field: Int
}

pub struct LirArg {
    by_ref: Bool
    // Operand (by value) or place (by reference).
    value: Int
    mutable: Bool
}

pub struct LirInst {
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

pub struct LirFn {
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

pub fn lirFnNew() -> LirFn {
    return LirFn(vars: List[], consts: List[], places: List[], args: List[], operands: List[], insts: List[], path_var: List[], cond: List[], swap: List[], ret: List[], ret_ref: List[], val: LIR_NONE, place: -1, borrowed: -1, unsupported: -1, params: 0, at: 0)
}

pub fn lirIsVar(operand: Int) -> Bool {
    return operand >= 0
}

pub fn lirConstId(operand: Int) -> Int {
    return -1 - operand
}

pub fn lirVar(l: &mut LirFn, ty: Int, is_ref: Bool) -> Int {
    l.vars.push(LirVar(ty: ty, is_ref: is_ref))
    return l.vars.length - 1
}

pub fn lirConst(l: &mut LirFn, kind: Int, value: Int, start: Int, end: Int) -> Int {
    l.consts.push(LirConst(kind: kind, value: value, start: start, end: end))
    return -l.consts.length
}

pub fn lirPlaceVar(l: &mut LirFn, slot: Int) -> Int {
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

pub fn lirArg(l: &mut LirFn, by_ref: Bool, value: Int, mutable: Bool) -> Int {
    l.args.push(LirArg(by_ref: by_ref, value: value, mutable: mutable))
    return l.args.length - 1
}

pub fn lirEmit(l: &mut LirFn, kind: Int, dst: Int, a: Int, b: Int, c: Int, block: Int, pos: Int) {
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

pub fn lirBindPath(l: &mut LirFn, path: Int, slot: Int) {
    if path < 0 { return }
    while l.path_var.length <= path { l.path_var.push(-1) }
    l.path_var[path] = slot
}

pub fn lirPathVar(l: &LirFn, path: Int) -> Int {
    if path < 0 || path >= l.path_var.length { return -1 }
    return l.path_var[path]
}

expose flow lirMarkUnsupported(l: &mut LirFn, offset: Int) {
    if l.unsupported < 0 { l.unsupported = offset }
}

// Module tables shared by every function: signatures (parameters and
// result) in function index order and structs with their field types.
pub struct LirModule {
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
    // -1 for a nominal enum, otherwise the concrete Option/Result type id.
    en_builtin: List<Int>
    en_first: List<Int>
    en_count: List<Int>
    variant_payload: List<Int>
    variant_type: List<Int>
}

pub fn lirModuleNew() -> LirModule {
    return LirModule(fn_first: List[], fn_count: List[], param_ty: List[], param_ref: List[], param_mut: List[], fn_ret: List[], fn_ret_ref: List[], fn_ret_mut: List[], fn_decl: List[], st_first: List[], st_count: List[], field_ty: List[], st_decl: List[], list_elem: List[], unit_enums: List[], en_decl: List[], en_builtin: List[], en_first: List[], en_count: List[], variant_payload: List[], variant_type: List[])
}

pub fn lirListRegister(lm: &mut LirModule, elem: Int) -> Int {
    for k in 0..lm.list_elem.length {
        if lm.list_elem[k] == elem { return k }
    }
    lm.list_elem.push(elem)
    return lm.list_elem.length - 1
}

pub fn lirIsUnitEnum(types: &TypeTable, lm: &LirModule, ty: Int) -> Bool {
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
