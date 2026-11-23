expose choice SemTypeKind {
    Unknown
    Int
    Float
    F32
    Bool
    Text
    Unit
    Error
    Struct
    Enum
    Ref
    MutRef
    Array
    Slice
    List
    Option
    Result
    // Opaque, linear handle of an open file (P0-B). Below sema it is an Int.
    File
    // Opaque, linear native window (P0-D). Below sema it is an Int.
    Window
}

expose shape SemType {
    kind: SemTypeKind
    name_start: Int
    name_end: Int
    elem_type: Int
    nominal_id: Int
}

expose shape TypeTable {
    types: List of[SemType]
}

expose flow typeTableNew() => TypeTable {
    hold list: List of[SemType] = List[]
    change table = TypeTable(types: list)
    table.types@push(SemType(kind: SemTypeKind.Unknown, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.Int, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.Float, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.F32, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.Bool, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.Text, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.Unit, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types@push(SemType(kind: SemTypeKind.Error, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    give table
}

expose flow semTypeAdd(table: edit TypeTable, kind: SemTypeKind, name_start: Int, name_end: Int, elem_type: Int, nominal_id: Int) => Int {
    hold id = table.types.length
    table.types@push(SemType(kind: kind, name_start: name_start, name_end: name_end, elem_type: elem_type, nominal_id: nominal_id))
    give id
}

expose flow semTypeMakeRef(table: edit TypeTable, inner_id: Int, is_mut: Bool) => Int {
    each i among 8..table.types.length {
        hold t = view table.types[i]
        when is_mut {
            choose t.kind {
                SemTypeKind.MutRef : {
                    when t.elem_type == inner_id { give i }
                }
                _ : {}
            }
        } otherwise {
            choose t.kind {
                SemTypeKind.Ref : {
                    when t.elem_type == inner_id { give i }
                }
                _ : {}
            }
        }
    }
    change kind = SemTypeKind.Ref
    when is_mut {
        kind = SemTypeKind.MutRef
    }
    give semTypeAdd(edit table, kind, -1, -1, inner_id, -1)
}

// The single File type: created on first use, so programs without files
// keep their type tables (and LIR) unchanged.
expose flow semTypeMakeFile(table: edit TypeTable) => Int {
    hold found = semTypeFindFile(table)
    when found >= 0 { give found }
    give semTypeAdd(edit table, SemTypeKind.File, -1, -1, -1, -1)
}

// The File type id, or -1 when the program never named or produced one.
expose flow semTypeFindFile(table: view TypeTable) => Int {
    each i among 8..table.types.length {
        choose table.types[i].kind {
            SemTypeKind.File : { give i }
            _ : {}
        }
    }
    give -1
}

expose flow semTypeIsFile(table: view TypeTable, ty: Int) => Bool {
    when ty < 8 || ty >= table.types.length { give false }
    choose table.types[ty].kind {
        SemTypeKind.File : { give true }
        _ : { give false }
    }
}

// ---- Linear resources --------------------------------------------------
// A linear type owns an operating-system resource that only its close
// operation may release: ownership tracks it like any owner, but an
// implicit drop of a (maybe) live value is a compile error, and it can
// never be stored in an aggregate. Below sema it is one machine word.
// Adding a resource kind means extending semTypeIsLinear and
// semTypeCloser; flow analysis, the aggregate rule and drops then apply to
// it unchanged. Its LIR identity is not inherited: lirTypeCode and the native
// reader (cfgType, cfgIsLinear) need a code of their own for each kind.

// The single Window type, created on first use like File.
expose flow semTypeMakeWindow(table: edit TypeTable) => Int {
    each i among 8..table.types.length {
        when semTypeIsWindow(table, i) { give i }
    }
    give semTypeAdd(edit table, SemTypeKind.Window, -1, -1, -1, -1)
}

expose flow semTypeIsWindow(table: view TypeTable, ty: Int) => Bool {
    when ty < 8 || ty >= table.types.length { give false }
    choose table.types[ty].kind {
        SemTypeKind.Window : { give true }
        _ : { give false }
    }
}

expose flow semTypeIsLinear(table: view TypeTable, ty: Int) => Bool {
    give semTypeIsFile(table, ty) || semTypeIsWindow(table, ty)
}

// The source name of linear type `ty`, for diagnostics.
expose flow semTypeLinearName(table: view TypeTable, ty: Int) => Text {
    when semTypeIsFile(table, ty) { give "File" }
    when semTypeIsWindow(table, ty) { give "Window" }
    give "recurso"
}

// The operation that consumes a value of linear type `ty`, for diagnostics.
expose flow semTypeCloser(table: view TypeTable, ty: Int) => Text {
    when semTypeIsFile(table, ty) { give "fileClose" }
    when semTypeIsWindow(table, ty) { give "windowClose" }
    give "su operación de cierre"
}

// Every linear type id present in the table (for flow analysis).
expose flow semTypeLinearIds(table: view TypeTable) => List of[Int] {
    change ids: List of[Int] = List[]
    each i among 8..table.types.length {
        when semTypeIsLinear(table, i) { ids@push(i) }
    }
    give ids
}

expose flow semTypeMakeList(table: edit TypeTable, elem_id: Int) => Int {
    each i among 8..table.types.length {
        hold t = view table.types[i]
        choose t.kind {
            SemTypeKind.List : {
                when t.elem_type == elem_id { give i }
            }
            _ : {}
        }
    }
    give semTypeAdd(edit table, SemTypeKind.List, -1, -1, elem_id, -1)
}

expose flow semTypeMakeOption(table: edit TypeTable, elem_id: Int) => Int {
    each i among 8..table.types.length {
        hold t = view table.types[i]
        choose t.kind {
            SemTypeKind.Option : {
                when t.elem_type == elem_id { give i }
            }
            _ : {}
        }
    }
    give semTypeAdd(edit table, SemTypeKind.Option, -1, -1, elem_id, -1)
}

expose flow semTypeMakeResult(table: edit TypeTable, ok_id: Int, err_id: Int) => Int {
    each i among 8..table.types.length {
        hold t = view table.types[i]
        choose t.kind {
            SemTypeKind.Result : {
                when t.elem_type == ok_id && t.nominal_id == err_id { give i }
            }
            _ : {}
        }
    }
    give semTypeAdd(edit table, SemTypeKind.Result, -1, -1, ok_id, err_id)
}

expose flow semTypeMakeArray(table: edit TypeTable, elem_id: Int) => Int {
    each i among 8..table.types.length {
        hold t = view table.types[i]
        choose t.kind {
            SemTypeKind.Array : {
                when t.elem_type == elem_id { give i }
            }
            _ : {}
        }
    }
    give semTypeAdd(edit table, SemTypeKind.Array, -1, -1, elem_id, -1)
}

expose flow semTypeMakeSlice(table: edit TypeTable, elem_id: Int) => Int {
    each i among 8..table.types.length {
        hold t = view table.types[i]
        choose t.kind {
            SemTypeKind.Slice : {
                when t.elem_type == elem_id { give i }
            }
            _ : {}
        }
    }
    give semTypeAdd(edit table, SemTypeKind.Slice, -1, -1, elem_id, -1)
}

expose flow semTypeIsNumeric(kind: view SemTypeKind) => Bool {
    choose kind {
        SemTypeKind.Int : { give true }
        SemTypeKind.Float : { give true }
        SemTypeKind.F32 : { give true }
        _ : { give false }
    }
}

expose flow semTypeIsCopy(kind: view SemTypeKind) => Bool {
    choose kind {
        SemTypeKind.Int : { give true }
        SemTypeKind.Float : { give true }
        SemTypeKind.F32 : { give true }
        SemTypeKind.Bool : { give true }
        SemTypeKind.Unit : { give true }
        _ : { give false }
    }
}

expose flow semTypeIsMove(kind: view SemTypeKind) => Bool {
    give !semTypeIsCopy(kind)
}

expose flow semTypeEquals(table: view TypeTable, a: Int, b: Int) => Bool {
    when a == b { give true }
    when a == 0 || b == 0 { give true }
    when a == 7 || b == 7 { give true }
    when a < 0 || a >= table.types.length { give false }
    when b < 0 || b >= table.types.length { give false }

    hold ta = view table.types[a]
    hold tb = view table.types[b]

    choose ta.kind {
        SemTypeKind.Int : {
            choose tb.kind {
                SemTypeKind.Int : { give true }
                _ : { give false }
            }
        }
        SemTypeKind.Float : {
            choose tb.kind {
                SemTypeKind.Float : { give true }
                _ : { give false }
            }
        }
        SemTypeKind.F32 : {
            choose tb.kind {
                SemTypeKind.F32 : { give true }
                _ : { give false }
            }
        }
        SemTypeKind.Bool : {
            choose tb.kind {
                SemTypeKind.Bool : { give true }
                _ : { give false }
            }
        }
        SemTypeKind.Text : {
            choose tb.kind {
                SemTypeKind.Text : { give true }
                _ : { give false }
            }
        }
        SemTypeKind.Unit : {
            choose tb.kind {
                SemTypeKind.Unit : { give true }
                _ : { give false }
            }
        }
        SemTypeKind.Struct : {
            choose tb.kind {
                SemTypeKind.Struct : { give ta.nominal_id == tb.nominal_id }
                _ : { give false }
            }
        }
        SemTypeKind.Enum : {
            choose tb.kind {
                SemTypeKind.Enum : { give ta.nominal_id == tb.nominal_id }
                _ : { give false }
            }
        }
        SemTypeKind.Ref : {
            choose tb.kind {
                SemTypeKind.Ref : { give semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ : { give false }
            }
        }
        SemTypeKind.MutRef : {
            choose tb.kind {
                SemTypeKind.MutRef : { give semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ : { give false }
            }
        }
        SemTypeKind.Array : {
            choose tb.kind {
                SemTypeKind.Array : { give semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ : { give false }
            }
        }
        SemTypeKind.Slice : {
            choose tb.kind {
                SemTypeKind.Slice : { give semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ : { give false }
            }
        }
        SemTypeKind.List : {
            choose tb.kind {
                SemTypeKind.List : { give semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ : { give false }
            }
        }
        SemTypeKind.Option : {
            choose tb.kind {
                SemTypeKind.Option : { give semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ : { give false }
            }
        }
        SemTypeKind.Result : {
            choose tb.kind {
                SemTypeKind.Result : {
                    give semTypeEquals(table, ta.elem_type, tb.elem_type) && semTypeEquals(table, ta.nominal_id, tb.nominal_id)
                }
                _ : { give false }
            }
        }
        _ : { give false }
    }
}

expose flow semTypeName(table: view TypeTable, source: view Text, type_id: Int) => Text {
    when type_id < 0 || type_id >= table.types.length {
        give "<invalid>"
    }
    when semTypeIsFile(table, type_id) { give "File" }
    when semTypeIsWindow(table, type_id) { give "Window" }
    hold t = view table.types[type_id]
    choose t.kind {
        SemTypeKind.Unknown : { give "Unknown" }
        SemTypeKind.Int : { give "Int" }
        SemTypeKind.Float : { give "Float" }
        SemTypeKind.F32 : { give "F32" }
        SemTypeKind.Bool : { give "Bool" }
        SemTypeKind.Text : { give "Text" }
        SemTypeKind.Unit : { give "()" }
        SemTypeKind.Error : { give "<error>" }
        SemTypeKind.Struct : {
            give "Struct"
        }
        SemTypeKind.Enum : {
            give "Enum"
        }
        SemTypeKind.Ref : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "&{inner}"
        }
        SemTypeKind.MutRef : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "&mut {inner}"
        }
        SemTypeKind.Array : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "[{inner}]"
        }
        SemTypeKind.Slice : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "&[{inner}]"
        }
        SemTypeKind.List : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "List<{inner}>"
        }
        SemTypeKind.Option : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "Option<{inner}>"
        }
        SemTypeKind.Result : {
            hold inner = semTypeName(table, source, t.elem_type)
            give "Result<{inner}>"
        }
        SemTypeKind.File : { give "File" }
        SemTypeKind.Window : { give "Window" }
    }
}
