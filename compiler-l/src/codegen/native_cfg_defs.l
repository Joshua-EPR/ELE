import lir_tokens

// Restricted, typed, flattened representation of ELE-LIR 1 for the
// independent ELE-written x86-64 bootstrap backend. Supports move-only,
// drop-free structs with primitive fields (including nested structs).
// Also supports tagged enums with zero or one primitive payload per variant.
// Local loans, returned references, floats, arrays and Text inside
// aggregates are explicitly rejected.
// Type IDs: 0 = Int, 1 = Bool, 2+s = nominal struct s,
// 2+struct_count+e = nominal enum e.
// Instruction kinds: 1 use, 2 binary, 3 call, 4 struct, 5 read,
// 6 store, 7 variant, 8 discriminant, 9 checked primitive payload,
// 10 print, 11 textbuf, 12 append, 13 drop (runtime in native_rt),
// 14 len (Text byte length), 15 byteat (bounds-checked Text byte).
// Reference parameters (`var vN ref T`, N < params) occupy one word: the
// address of the referent. `types_code` keeps the referent type and
// `var_ref` marks them; native_cfg_ref documents their rules.
// Unit is type code -2: valid only as a function result, as the `cu`
// constant and as a non-parameter variable that receives a unit call.
// Text is type code -3: a move-only value of three words (address, byte
// length, capacity) valid as variable, parameter, result and literal.
// For kinds 10 and 12 `op` is the variable passed by reference, or -1 when
// the source is operand `a`. For kind 12 `place_var` is the buffer. For
// kind 13 `place_var` is the value and `op` its drop flag, or -1.
// Call arguments live in `CfgProgram.call_args` from `arg_first`.
// Binary operations: 1 add, 2 sub, 3 mul, 4 eq, 5 ne, 6 lt,
// 7 le, 8 gt, 9 ge. Terminators: 1 return, 2 jump, 3 branch.

pub struct CfgInst {
    kind: Int
    dst: Int
    op: Int
    callee: Int
    argc: Int
    a: NativeOperand
    b: NativeOperand
    c: NativeOperand
    d: NativeOperand
    place_var: Int
    place_field: Int
    place_subfield: Int
    arg_first: Int
    // Projections of the `ref` source of print/append (kinds 10, 12) and
    // of the place of dropfield (kind 17 uses place_*), or -1.
    src_field: Int
    src_sub: Int
}

pub struct CfgField {
    ty: Int
    offset: Int
}

pub struct CfgStruct {
    first_field: Int
    fields: Int
    size: Int
    align: Int
}

// Monomorphized tagged enums. This bootstrap subset supports only variants
// with no payload or one primitive Int/Bool payload. Each enum is move-only
// and drop-free. A populated payload slot is always fully initialized,
// including for None/unit variants, so whole-value moves copy defined bytes.
pub struct CfgEnum {
    first_variant: Int
    variants: Int
    size: Int
    align: Int
}

pub struct CfgVariant {
    payload_type: Int
}

pub struct CfgPlace {
    variable: Int
    field: Int
    subfield: Int
}

pub struct CfgBlock {
    first: Int
    count: Int
    term: Int
    value: NativeOperand
    yes: Int
    no: Int
}

pub struct CfgFunc {
    first_var: Int
    vars: Int
    first_block: Int
    blocks: Int
    params: Int
    result_bool: Bool
    result_unit: Bool
    result_text: Bool
    // Result type code; an aggregate (>= 2) is written through the hidden
    // result pointer that the caller pushes after the arguments.
    result_type: Int
}

pub struct CfgProgram {
    error: Int
    main: Int
    functions: List<CfgFunc>
    types_bool: List<Bool>
    types_code: List<Int>
    slot_start: List<Int>
    slot_count: List<Int>
    structs: List<CfgStruct>
    fields: List<CfgField>
    enums: List<CfgEnum>
    variants: List<CfgVariant>
    blocks: List<CfgBlock>
    insts: List<CfgInst>
    // Constructor operands for kind 4. Call arguments remain separate.
    struct_args: List<NativeOperand>
    call_args: List<NativeOperand>
    // Per call argument: -1 by value, 0 shared and 1 exclusive reference.
    // A reference argument keeps its root variable in `call_args[k].value`
    // and its projections in `call_field`/`call_sub` (-1 when absent).
    call_ref: List<Int>
    call_field: List<Int>
    call_sub: List<Int>
    var_ref: List<Bool>
    text_start: List<Int>
    text_length: List<Int>
    text_bytes: List<Int>
}

pub fn cfgEmptyOperand() -> NativeOperand {
    return NativeOperand(is_var: false, value: 0, is_bool: false, is_unit: false, is_text: false)
}

pub fn cfgEmpty() -> CfgProgram {
    return CfgProgram(error: 0, main: -1, functions: List[], types_bool: List[], types_code: List[], slot_start: List[], slot_count: List[], structs: List[], fields: List[], enums: List[], variants: List[], blocks: List[], insts: List[], struct_args: List[], call_args: List[], call_ref: List[], call_field: List[], call_sub: List[], var_ref: List[], text_start: List[], text_length: List[], text_bytes: List[])
}

