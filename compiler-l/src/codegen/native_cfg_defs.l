import lir_tokens

// Restricted, typed, flattened representation of ELE-LIR 1 for the
// independent ELE-written x86-64 bootstrap backend. Supports move-only,
// drop-free structs with primitive fields (including nested structs).
// Also supports tagged enums with zero or one primitive payload per variant.
// Loans, floats, arrays and Text inside aggregates are explicitly rejected.
// Type IDs: 0 = Int, 1 = Bool, 2+s = nominal struct s,
// 2+struct_count+e = nominal enum e.
// Instruction kinds: 1 use, 2 binary, 3 call, 4 struct, 5 read,
// 6 store, 7 variant, 8 discriminant, 9 checked primitive payload,
// 10 print, 11 textbuf, 12 append, 13 drop (runtime in native_rt).
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
    call_args: List<NativeOperand>
    text_start: List<Int>
    text_length: List<Int>
    text_bytes: List<Int>
}

pub fn cfgEmptyOperand() -> NativeOperand {
    return NativeOperand(is_var: false, value: 0, is_bool: false, is_unit: false, is_text: false)
}

pub fn cfgEmpty() -> CfgProgram {
    return CfgProgram(error: 0, main: -1, functions: List[], types_bool: List[], types_code: List[], slot_start: List[], slot_count: List[], structs: List[], fields: List[], enums: List[], variants: List[], blocks: List[], insts: List[], call_args: List[], text_start: List[], text_length: List[], text_bytes: List[])
}

