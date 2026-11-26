take lir_tokens

// Restricted, typed, flattened representation of ELE-LIR 1 for the
// independent ELE-written x86-64 bootstrap backend. Supports move-only,
// drop-free structs with primitive fields (including nested structs).
// Also supports tagged enums with zero or one payload per variant: Int, Bool
// or a drop-free shape/choice (laid out by cfgLayoutDecls; extracting an
// aggregate payload moves the enum).
// Local loans, returned references, floats, arrays and Text inside
// aggregates are explicitly rejected.
// Type IDs: 0 = Int, 1 = Bool, 2+s = nominal struct s,
// 2+struct_count+e = nominal enum e.
// Instruction kinds: 1 use, 2 binary, 3 call, 4 struct, 5 read,
// 6 store, 7 variant, 8 discriminant, 9 checked payload,
// 10 print, 11 textbuf, 12 append, 13 drop (runtime in native_rt),
// 14 len (Text byte length), 15 byteat (bounds-checked Text byte),
// 16 unary, 17 dropfield, 18 listlit, 19 listpush, 20 listreserve,
// 21 cap, 22 loan, 23 listpop.
// References (`var vN ref T`: parameters, and locals defined by `loan`,
// kind 22) occupy one word: the address of the referent. `types_code` keeps the referent type and
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
// 7 le, 8 gt, 9 ge. Terminators: 1 return, 2 jump, 3 branch,
// 4 unreachable, 5 returnref.

expose shape CfgInst {
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
    // Projections after the static prefix of the place (`[vN]` and deeper
    // fields): an index into `CfgProgram.ext_first`, or -1. See native_cfg_list.
    place_ext: Int
    src_ext: Int
    // Source position of the record (` @line:col`), 0 when absent. Only the
    // run-time trap diagnostics of native_trap read it.
    line: Int
    col: Int
}

expose shape CfgField {
    ty: Int
    offset: Int
}

expose shape CfgStruct {
    first_field: Int
    fields: Int
    size: Int
    align: Int
}

// Monomorphized tagged enums. Variants carry no payload or one Int, Bool or
// drop-free aggregate payload. Layout: tag word at 0, payload area at 8
// sized by the largest payload (whole words). Each enum is move-only and
// drop-free. The payload area is always fully initialized (zero-filled),
// including for None/unit variants, so whole-value moves copy defined bytes.
expose shape CfgEnum {
    first_variant: Int
    variants: Int
    size: Int
    align: Int
}

expose shape CfgVariant {
    payload_type: Int
}

expose shape CfgPlace {
    variable: Int
    field: Int
    subfield: Int
    ext: Int
}

expose shape CfgBlock {
    first: Int
    count: Int
    term: Int
    value: NativeOperand
    yes: Int
    no: Int
}

expose shape CfgFunc {
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
    // A function returning a reference (`result T 1 m`): -1 for none, 0 shared,
    // 1 exclusive. Then `result_type` is 0, the one-word address in RAX, and
    // `result_ref_type` is the referent type T (native_cfg_returnref).
    result_ref: Int
    result_ref_type: Int
}

expose shape CfgProgram {
    error: Int
    main: Int
    functions: List of[CfgFunc]
    types_bool: List of[Bool]
    types_code: List of[Int]
    slot_start: List of[Int]
    slot_count: List of[Int]
    structs: List of[CfgStruct]
    fields: List of[CfgField]
    enums: List of[CfgEnum]
    variants: List of[CfgVariant]
    blocks: List of[CfgBlock]
    insts: List of[CfgInst]
    // Constructor operands for kind 4. Call arguments remain separate.
    struct_args: List of[NativeOperand]
    call_args: List of[NativeOperand]
    // Per call argument: -1 by value, 0 shared and 1 exclusive reference.
    // A reference argument keeps its root variable in `call_args[k].value`
    // and its projections in `call_field`/`call_sub` (-1 when absent).
    call_ref: List of[Int]
    call_field: List of[Int]
    call_sub: List of[Int]
    call_ext: List of[Int]
    var_ref: List of[Bool]
    text_start: List of[Int]
    text_length: List of[Int]
    text_bytes: List of[Int]
    // Counts declared by the module header. Type codes are fixed by them:
    // list k is 2 + decl_structs + decl_enums + k, known before any
    // declaration is read, so a shape may hold a list of itself.
    decl_structs: Int
    decl_enums: Int
    decl_lists: Int
    // Element type of each `list lK <type>`.
    list_elem: List of[Int]
    // Place extensions: run `ext_first[e]..+ext_count[e]` of projections.
    // proj_kind 0 is a field (proj_value its index) and 1 an index
    // (proj_value the Int variable that holds it).
    ext_first: List of[Int]
    ext_count: List of[Int]
    proj_kind: List of[Int]
    proj_value: List of[Int]
    // Local references, per variable slot (native_cfg_loan): the root
    // variable and static prefix of the place its loan took, and the mode
    // (-1 no loan yet, 0 shared, 1 exclusive).
    ref_root: List of[Int]
    ref_field: List of[Int]
    ref_sub: List of[Int]
    ref_mut: List of[Int]
}

expose flow cfgEmptyOperand() => NativeOperand {
    give NativeOperand(is_var: false, value: 0, is_bool: false, is_unit: false, is_text: false, is_float: false)
}

expose flow cfgEmpty() => CfgProgram {
    give CfgProgram(error: 0, main: -1, functions: List[], types_bool: List[], types_code: List[], slot_start: List[], slot_count: List[], structs: List[], fields: List[], enums: List[], variants: List[], blocks: List[], insts: List[], struct_args: List[], call_args: List[], call_ref: List[], call_field: List[], call_sub: List[], call_ext: List[], var_ref: List[], text_start: List[], text_length: List[], text_bytes: List[], decl_structs: 0, decl_enums: 0, decl_lists: 0, list_elem: List[], ext_first: List[], ext_count: List[], proj_kind: List[], proj_value: List[], ref_root: List[], ref_field: List[], ref_sub: List[], ref_mut: List[])
}

// Index of the list type `ty`, or -1 when it is not a list.
expose flow cfgListIndex(p: view CfgProgram, ty: Int) => Int {
    hold k = ty - 2 - p.decl_structs - p.decl_enums
    when ty >= 2 && k >= 0 && k < p.decl_lists { give k }
    give -1
}

// A value that owns heap storage by itself: Text or a list. Shapes own
// storage through their fields (see cfgOwnsHeap in native_cfg_fields).
expose flow cfgHeapDirect(p: view CfgProgram, ty: Int) => Bool {
    give ty == -3 || cfgListIndex(p, ty) >= 0
}
