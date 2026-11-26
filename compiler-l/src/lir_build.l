take sema_types

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

expose fixed LIR_NONE = -1000000000

// Constant kinds.
expose fixed LIR_CONST_INT = 0
expose fixed LIR_CONST_BOOL = 1
expose fixed LIR_CONST_UNIT = 2
expose fixed LIR_CONST_TEXT = 3
// Float: `value` is the IEEE-754 binary64 bit pattern as a signed Int.
expose fixed LIR_CONST_FLOAT = 4

// Instruction kinds.
expose fixed LIR_USE = 0
expose fixed LIR_UNARY = 1
expose fixed LIR_BINARY = 2
expose fixed LIR_CALL = 3
expose fixed LIR_STRUCT = 4
expose fixed LIR_READ = 5
expose fixed LIR_LOAN = 6
expose fixed LIR_TEXTBUF = 7
expose fixed LIR_APPEND = 8
expose fixed LIR_STORE = 9
expose fixed LIR_PRINT = 10
expose fixed LIR_DROP = 11
expose fixed LIR_DROPFIELD = 12
expose fixed LIR_LEN = 13
expose fixed LIR_LIST_PUSH = 14
expose fixed LIR_LIST_POP = 15
expose fixed LIR_LIST_RESERVE = 16
expose fixed LIR_BYTE_AT = 17
expose fixed LIR_PLATFORM = 18
expose fixed LIR_LIST_LIT = 19
expose fixed LIR_CAP = 20
expose fixed LIR_VARIANT = 21
expose fixed LIR_DISC = 22
// Guarded Copy projection from the single active primitive enum payload.
expose fixed LIR_PAYLOAD = 23

expose fixed LIR_PLATFORM_ARG_COUNT = 0
expose fixed LIR_PLATFORM_ARG = 1
expose fixed LIR_PLATFORM_READ_TEXT = 2
expose fixed LIR_PLATFORM_PRINT_ERROR = 3
expose fixed LIR_PLATFORM_WRITE_BYTES = 4
expose fixed LIR_PLATFORM_SAME_FILE = 5
// consoleInputMode(mode: Int) -> Int and readConsoleEvent() -> Int: the raw
// console input pair. Both take and give plain Int, so they never borrow.
expose fixed LIR_PLATFORM_CONSOLE_MODE = 6
expose fixed LIR_PLATFORM_READ_EVENT = 7
// Binary-safe stdout write: shared List<Int> loan, Int status.
expose fixed LIR_PLATFORM_WRITE_CONSOLE = 8
// File streams (P0-B): the File operand is a shared ref to the linear
// File, except for the consuming close, which takes it by value.
expose fixed LIR_PLATFORM_FILE_OPEN = 9
expose fixed LIR_PLATFORM_FILE_READ = 10
expose fixed LIR_PLATFORM_FILE_WRITE = 11
expose fixed LIR_PLATFORM_FILE_SEEK = 12
expose fixed LIR_PLATFORM_FILE_SIZE = 13
expose fixed LIR_PLATFORM_FILE_FLUSH = 14
expose fixed LIR_PLATFORM_FILE_CLOSE = 15
expose fixed LIR_PLATFORM_FILE_STATUS = 16
// Native windows (P0-D): the linear Window, same rules as File.
expose fixed LIR_PLATFORM_WINDOW_OPEN = 17
expose fixed LIR_PLATFORM_WINDOW_STATUS = 18
expose fixed LIR_PLATFORM_WINDOW_NEXT = 19
expose fixed LIR_PLATFORM_WINDOW_FILL = 20
expose fixed LIR_PLATFORM_WINDOW_TEXT = 21
expose fixed LIR_PLATFORM_WINDOW_PRESENT = 22
expose fixed LIR_PLATFORM_WINDOW_SEND = 23
expose fixed LIR_PLATFORM_WINDOW_PIXEL = 24
expose fixed LIR_PLATFORM_WINDOW_CLOSE = 25
// Font cell size (width + height * 65536) and text drawn from UTF-8 bytes
// of a List of[Int] (edit ors keep documents as bytes, not Text).
expose fixed LIR_PLATFORM_WINDOW_CELL = 26
expose fixed LIR_PLATFORM_WINDOW_TEXT_BYTES = 27
// UTF-8 clipboard transfer; returns a status or the number of bytes read.
expose fixed LIR_PLATFORM_CLIPBOARD_WRITE = 28
expose fixed LIR_PLATFORM_CLIPBOARD_READ = 29
expose fixed LIR_PLATFORM_TEXT_FROM_BYTES = 30
// Kernel intrinsics (`take nucleo.cpu`, `take nucleo.mem`): each one is
// inline code, never a runtime routine. Every argument is a `val` Int; the
// result is Int or Unit (lirIntrinsicHasResult).
//   31 hlt  32 cli  33 sti  34 pause                       -> Unit
//   35 in8  36 in16  37 in32  (puerto)                     -> Int
//   38 out8 39 out16 40 out32 (puerto, valor)              -> Unit
//   41 ld8  42 ld16  43 ld32  44 ld64  (dir)               -> Int, zero-extended
//   45 st8  46 st16  47 st32  48 st64  (dir, valor)        -> Unit, truncated
// Static storage (`--target kernel` only; constant arguments):
//   49 reservar (bytes, alineacion) -> Int, zeroed .bss
//   50 datos64 (w0, w1, ...)        -> Int, initialized .data, 8-aligned
//   51 cadena: (bytes, w0, ...) of a Text literal -> Int, .rodata record
//      [bytes: u64][UTF-8 bytes], 8-aligned
// CPU:
//   52 cpuid (hoja, subhoja, dir): EAX EBX ECX EDX as four u32 at dir
//   53 rdtsc -> Int   54 rdmsr (msr) -> Int   55 wrmsr (msr, valor)
//   56..59 leerCr0/2/3/4 -> Int   60..62 escribirCr0/3/4 (valor)
//   63 lgdt (dir)  64 lidt (dir)  65 ltr (selector)
//   66 recargarSegmentos (codigo, datos): far return to CS, DS=ES=SS=FS=GS
//   67 invlpg (dir)  68 fxsave (dir)  69 fxrstor (dir)  70 wbinvd
//   71 stubInterrupcion (vector) -> Int  (`--target kernel` only)
//   72 leerRflags -> Int   73 int3 (breakpoint #BP, returns)
// Packed single SSE on XMM6..XMM15 (Float code uses XMM0..XMM5); the
// register arguments must be constants:
//   74 xmmCero (r)   75 xmmCargar (r, dir)   76 xmmGuardar (dir, r)
//   77 xmmDifundir (r, dir)   78 xmmCopiar (d, s)
//   79 xmmMultiplicar (d, s)  80 xmmSumar (d, s)
//   81 xmmMulSumar4 (acc, a, dir, desp): acc+j += a * [dir + desp + 16j],
//      j = 0..3 (desp constant)
//   82 xmmDifundirEn (r, dir, desp): [dir + desp] to the four lanes of r
expose fixed LIR_PLATFORM_INTRINSIC_FIRST = 31
expose fixed LIR_PLATFORM_INTRINSIC_LAST = 82

expose flow lirIsIntrinsicOp(op: Int) => Bool {
    give op >= LIR_PLATFORM_INTRINSIC_FIRST && op <= LIR_PLATFORM_INTRINSIC_LAST
}

// -1: variable, 1..256 arguments (datos64, cadena).
expose flow lirIntrinsicArity(op: Int) => Int {
    when op <= 34 { give 0 }
    when op <= 37 { give 1 }
    when op <= 40 { give 2 }
    when op <= 44 { give 1 }
    when op <= 49 { give 2 }
    when op <= 51 { give -1 }
    when op == 52 { give 3 }
    when op == 53 { give 0 }
    when op == 54 { give 1 }
    when op == 55 { give 2 }
    when op <= 59 { give 0 }
    when op <= 65 { give 1 }
    when op == 66 { give 2 }
    when op <= 69 { give 1 }
    when op == 70 { give 0 }
    when op == 71 { give 1 }
    when op == 74 { give 1 }
    when op == 81 { give 4 }
    when op == 82 { give 3 }
    when op >= 75 { give 2 }
    give 0
}

expose flow lirIntrinsicHasResult(op: Int) => Bool {
    when (op >= 35 && op <= 37) || (op >= 41 && op <= 44) { give true }
    when op >= 49 && op <= 51 { give true }
    when op == 53 || op == 54 || (op >= 56 && op <= 59) { give true }
    give op == 71 || op == 72
}

// LIR text name of an intrinsic code (the native backend parses it back).
expose flow lirIntrinsicName(op: Int) => Text {
    when op == 31 { give "hlt" }
    when op == 32 { give "cli" }
    when op == 33 { give "sti" }
    when op == 34 { give "pause" }
    when op == 35 { give "in8" }
    when op == 36 { give "in16" }
    when op == 37 { give "in32" }
    when op == 38 { give "out8" }
    when op == 39 { give "out16" }
    when op == 40 { give "out32" }
    when op == 41 { give "ld8" }
    when op == 42 { give "ld16" }
    when op == 43 { give "ld32" }
    when op == 44 { give "ld64" }
    when op == 45 { give "st8" }
    when op == 46 { give "st16" }
    when op == 47 { give "st32" }
    when op == 48 { give "st64" }
    when op == 49 { give "reservar" }
    when op == 50 { give "datos64" }
    when op == 51 { give "cadena" }
    when op == 52 { give "cpuid" }
    when op == 53 { give "rdtsc" }
    when op == 54 { give "rdmsr" }
    when op == 55 { give "wrmsr" }
    when op == 56 { give "rdcr0" }
    when op == 57 { give "rdcr2" }
    when op == 58 { give "rdcr3" }
    when op == 59 { give "rdcr4" }
    when op == 60 { give "wrcr0" }
    when op == 61 { give "wrcr3" }
    when op == 62 { give "wrcr4" }
    when op == 63 { give "lgdt" }
    when op == 64 { give "lidt" }
    when op == 65 { give "ltr" }
    when op == 66 { give "reloadseg" }
    when op == 67 { give "invlpg" }
    when op == 68 { give "fxsave" }
    when op == 69 { give "fxrstor" }
    when op == 70 { give "wbinvd" }
    when op == 71 { give "isrstub" }
    when op == 72 { give "rdflags" }
    when op == 73 { give "int3" }
    when op == 74 { give "xzero" }
    when op == 75 { give "xload" }
    when op == 76 { give "xstore" }
    when op == 77 { give "xbcast" }
    when op == 78 { give "xmov" }
    when op == 79 { give "xmul" }
    when op == 80 { give "xadd" }
    when op == 81 { give "xmuladd4" }
    give "xbcastd"
}

// ---- Linear resource operation table ------------------------------------
// Each resource family is a small table shared by sema (argument checking
// and lowering) and the LIR verifier: which ops belong to it, their arity,
// which op opens (its result is the resource), which op closes (it takes
// the resource by value), and the kind of each argument. Ref arguments
// only ever sit at positions 0..3, so the native backend can compute their
// addresses before loading value arguments into R8/R9.
//
// Argument kinds: 0 val Int, 1 shared ref resource, 2 shared ref
// List<Int>, 3 exclusive ref List<Int>, 4 shared ref Text, 5 val resource.

expose flow lirIsResourceOp(op: Int) => Bool {
    give op >= LIR_PLATFORM_FILE_OPEN && op <= LIR_PLATFORM_WINDOW_TEXT_BYTES
}

expose flow lirIsWindowOp(op: Int) => Bool {
    give op >= LIR_PLATFORM_WINDOW_OPEN && op <= LIR_PLATFORM_WINDOW_TEXT_BYTES
}

expose flow lirResourceOpens(op: Int) => Bool {
    give op == LIR_PLATFORM_FILE_OPEN || op == LIR_PLATFORM_WINDOW_OPEN
}

expose flow lirResourceArity(op: Int) => Int {
    when op == LIR_PLATFORM_FILE_OPEN { give 2 }
    when op == LIR_PLATFORM_FILE_READ || op == LIR_PLATFORM_FILE_WRITE || op == LIR_PLATFORM_FILE_SEEK { give 3 }
    when op == LIR_PLATFORM_WINDOW_OPEN || op == LIR_PLATFORM_WINDOW_PIXEL { give 3 }
    when op == LIR_PLATFORM_WINDOW_FILL || op == LIR_PLATFORM_WINDOW_TEXT_BYTES { give 6 }
    when op == LIR_PLATFORM_WINDOW_TEXT { give 5 }
    when op == LIR_PLATFORM_WINDOW_SEND { give 4 }
    give 1
}

expose flow lirResourceArgKind(op: Int, i: Int) => Int {
    when op == LIR_PLATFORM_FILE_OPEN || op == LIR_PLATFORM_WINDOW_OPEN {
        when i == 0 { give 4 }
        give 0
    }
    when op == LIR_PLATFORM_FILE_CLOSE || op == LIR_PLATFORM_WINDOW_CLOSE { give 5 }
    when i == 0 { give 1 }
    when i == 1 && op == LIR_PLATFORM_FILE_READ { give 3 }
    when i == 1 && op == LIR_PLATFORM_FILE_WRITE { give 2 }
    when i == 3 && op == LIR_PLATFORM_WINDOW_TEXT { give 4 }
    when i == 3 && op == LIR_PLATFORM_WINDOW_TEXT_BYTES { give 2 }
    give 0
}

// Terminators.
expose fixed LIR_T_NONE = 0
expose fixed LIR_T_JUMP = 1
expose fixed LIR_T_BRANCH = 2
expose fixed LIR_T_RETURN = 3
expose fixed LIR_T_RETURNREF = 4
expose fixed LIR_T_UNREACHABLE = 5

// Operators (same order as Stage 0 `BinOp`).
expose fixed LIR_ADD = 0
expose fixed LIR_SUB = 1
expose fixed LIR_MUL = 2
expose fixed LIR_DIV = 3
expose fixed LIR_REM = 4
expose fixed LIR_EQ = 5
expose fixed LIR_NE = 6
expose fixed LIR_LT = 7
expose fixed LIR_LE = 8
expose fixed LIR_GT = 9
expose fixed LIR_GE = 10
// Bitwise and wrapping Int operators (driver only; Stage 0 has none).
// Shifts trap when the count is outside 0..63; the others never trap.
expose fixed LIR_BAND = 11
expose fixed LIR_BOR = 12
expose fixed LIR_BXOR = 13
expose fixed LIR_SHL = 14
expose fixed LIR_SHR = 15
expose fixed LIR_WADD = 16
expose fixed LIR_WSUB = 17
expose fixed LIR_WMUL = 18
expose fixed LIR_NEG = 0
expose fixed LIR_NOT = 1
// Explicit conversions Float(Int) and Int(Float): Int(x) truncates toward
// zero and saturates, NaN gives 0 (Stage 0 `fcvt_to_sint_sat`).
expose fixed LIR_ITOF = 2
expose fixed LIR_FTOI = 3
// Bitwise not of an Int (`~x`).
expose fixed LIR_BNOT = 4

expose shape LirVar {
    ty: Int
    is_ref: Bool
}

expose shape LirConst {
    kind: Int
    value: Int
    // Text: source span of the literal content (escapes not decoded).
    start: Int
    end: Int
}

// A place is a variable plus a chain of struct field projections (local
// field index within the struct). A place rooted at a reference variable
// denotes the referent.
expose shape LirPlace {
    root: Int
    parent: Int
    field: Int
    // Source offset of the list index operator that introduced this place,
    // or -1 when it has no indexed projection.
    bounds_at: Int
}

expose shape LirArg {
    by_ref: Bool
    // Operand (by value) or place (by reference).
    value: Int
    mutable: Bool
}

expose shape LirInst {
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

expose shape LirFn {
    vars: List of[LirVar]
    consts: List of[LirConst]
    places: List of[LirPlace]
    args: List of[LirArg]
    operands: List of[Int]
    insts: List of[LirInst]
    // Move path -> variable that holds it (bindings and temporaries).
    path_var: List of[Int]
    // Per CFG block: branch condition, swapped successors, return value.
    cond: List of[Int]
    swap: List of[Bool]
    ret: List of[Int]
    ret_ref: List of[Bool]
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

expose flow lirFnNew() => LirFn {
    give LirFn(vars: List[], consts: List[], places: List[], args: List[], operands: List[], insts: List[], path_var: List[], cond: List[], swap: List[], ret: List[], ret_ref: List[], val: LIR_NONE, place: -1, borrowed: -1, unsupported: -1, params: 0, at: 0)
}

expose flow lirIsVar(operand: Int) => Bool {
    give operand >= 0
}

expose flow lirConstId(operand: Int) => Int {
    give -1 - operand
}

expose flow lirVar(l: edit LirFn, ty: Int, is_ref: Bool) => Int {
    l.vars@push(LirVar(ty: ty, is_ref: is_ref))
    give l.vars.length - 1
}

expose flow lirConst(l: edit LirFn, kind: Int, value: Int, start: Int, end: Int) => Int {
    l.consts@push(LirConst(kind: kind, value: value, start: start, end: end))
    give -l.consts.length
}

expose flow lirPlaceVar(l: edit LirFn, slot: Int) => Int {
    l.places@push(LirPlace(root: slot, parent: -1, field: -1, bounds_at: -1))
    give l.places.length - 1
}

expose flow lirPlaceField(l: edit LirFn, base: Int, field: Int) => Int {
    hold slot = l.places[base].root
    hold bounds_at = l.places[base].bounds_at
    l.places@push(LirPlace(root: slot, parent: base, field: field, bounds_at: bounds_at))
    give l.places.length - 1
}

expose flow lirPlaceIndex(l: edit LirFn, base: Int, index_var: Int) => Int {
    give lirPlaceIndexAt(edit l, base, index_var, -1)
}

expose flow lirPlaceIndexAt(l: edit LirFn, base: Int, index_var: Int, bounds_at: Int) => Int {
    hold slot = l.places[base].root
    hold f = 0 - 2 - index_var
    l.places@push(LirPlace(root: slot, parent: base, field: f, bounds_at: bounds_at))
    give l.places.length - 1
}

// Bounds diagnostics are attached to the indexed projection. Field
// projections preserve the location so reads, stores and loans through a
// directly indexed place point at the operator rather than the expression's
// base identifier.
expose flow lirPlaceBoundsAt(l: view LirFn, place: Int) => Int {
    when place < 0 || place >= l.places.length { give -1 }
    give l.places[place].bounds_at
}

expose flow lirArg(l: edit LirFn, by_ref: Bool, value: Int, mutable: Bool) => Int {
    l.args@push(LirArg(by_ref: by_ref, value: value, mutable: mutable))
    give l.args.length - 1
}

expose flow lirEmit(l: edit LirFn, kind: Int, dst: Int, a: Int, b: Int, c: Int, block: Int, pos: Int) {
    l.insts@push(LirInst(kind: kind, dst: dst, a: a, b: b, c: c, block: block, pos: pos, at: l.at))
}

// Make sure the per-block tables cover `blocks` CFG blocks.
expose flow lirBlocks(l: edit LirFn, blocks: Int) {
    during l.cond.length < blocks {
        l.cond@push(LIR_NONE)
        l.swap@push(false)
        l.ret@push(LIR_NONE)
        l.ret_ref@push(false)
    }
}

expose flow lirBindPath(l: edit LirFn, path: Int, slot: Int) {
    when path < 0 { give }
    during l.path_var.length <= path { l.path_var@push(-1) }
    l.path_var[path] = slot
}

expose flow lirPathVar(l: view LirFn, path: Int) => Int {
    when path < 0 || path >= l.path_var.length { give -1 }
    give l.path_var[path]
}

expose flow lirMarkUnsupported(l: edit LirFn, offset: Int) {
    when l.unsupported < 0 { l.unsupported = offset }
}

// Module tables shared by every function: signatures (parameters and
// result) in function index order and structs with their field types.
expose shape LirModule {
    fn_first: List of[Int]
    fn_count: List of[Int]
    param_ty: List of[Int]
    param_ref: List of[Bool]
    param_mut: List of[Bool]
    fn_ret: List of[Int]
    fn_ret_ref: List of[Bool]
    fn_ret_mut: List of[Bool]
    fn_decl: List of[Int]
    st_first: List of[Int]
    st_count: List of[Int]
    field_ty: List of[Int]
    st_decl: List of[Int]
    list_elem: List of[Int]
    unit_enums: List of[Int]
    en_decl: List of[Int]
    // -1 for a nominal enum, otherwise the concrete Option/Result type id.
    en_builtin: List of[Int]
    en_first: List of[Int]
    en_count: List of[Int]
    variant_payload: List of[Int]
    variant_type: List of[Int]
}

expose flow lirModuleNew() => LirModule {
    give LirModule(fn_first: List[], fn_count: List[], param_ty: List[], param_ref: List[], param_mut: List[], fn_ret: List[], fn_ret_ref: List[], fn_ret_mut: List[], fn_decl: List[], st_first: List[], st_count: List[], field_ty: List[], st_decl: List[], list_elem: List[], unit_enums: List[], en_decl: List[], en_builtin: List[], en_first: List[], en_count: List[], variant_payload: List[], variant_type: List[])
}

expose flow lirListRegister(lm: edit LirModule, elem: Int) => Int {
    each k among 0..lm.list_elem.length {
        when lm.list_elem[k] == elem { give k }
    }
    lm.list_elem@push(elem)
    give lm.list_elem.length - 1
}

expose flow lirIsUnitEnum(types: view TypeTable, lm: view LirModule, ty: Int) => Bool {
    when ty < 0 || ty >= types.types.length { give false }
    choose types.types[ty].kind {
        SemTypeKind.Enum : {
            hold decl = types.types[ty].nominal_id
            each k among 0..lm.unit_enums.length {
                when lm.unit_enums[k] == decl { give true }
            }
            give false
        }
        _ : { give false }
    }
}

expose flow lirTypesCompat(types: view TypeTable, lm: view LirModule, a: Int, b: Int) => Bool {
    // Nominal enums are not integers, including unit-only enums. Emitting
    // enum values as `ciN` is an obsolete Stage 1 shortcut, not a coercion.
    give a == b && a >= 0
}
