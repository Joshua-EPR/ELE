enum SemTypeKind {
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
}

struct SemType {
    kind: SemTypeKind
    name_start: Int
    name_end: Int
    elem_type: Int
    nominal_id: Int
}

struct TypeTable {
    types: List<SemType>
}

fn typeTableNew() -> TypeTable {
    let list: List<SemType> = List[]
    var table = TypeTable(types: list)
    table.types.push(SemType(kind: SemTypeKind.Unknown, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.Int, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.Float, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.F32, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.Bool, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.Text, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.Unit, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    table.types.push(SemType(kind: SemTypeKind.Error, name_start: -1, name_end: -1, elem_type: -1, nominal_id: -1))
    return table
}

fn semTypeAdd(table: &mut TypeTable, kind: SemTypeKind, name_start: Int, name_end: Int, elem_type: Int, nominal_id: Int) -> Int {
    let id = table.types.length
    table.types.push(SemType(kind: kind, name_start: name_start, name_end: name_end, elem_type: elem_type, nominal_id: nominal_id))
    return id
}

fn semTypeMakeRef(table: &mut TypeTable, inner_id: Int, is_mut: Bool) -> Int {
    for i in 8..table.types.length {
        let t = &table.types[i]
        if is_mut {
            match t.kind {
                SemTypeKind.MutRef => {
                    if t.elem_type == inner_id { return i }
                }
                _ => {}
            }
        } else {
            match t.kind {
                SemTypeKind.Ref => {
                    if t.elem_type == inner_id { return i }
                }
                _ => {}
            }
        }
    }
    var kind = SemTypeKind.Ref
    if is_mut {
        kind = SemTypeKind.MutRef
    }
    return semTypeAdd(&mut table, kind, -1, -1, inner_id, -1)
}

fn semTypeMakeList(table: &mut TypeTable, elem_id: Int) -> Int {
    for i in 8..table.types.length {
        let t = &table.types[i]
        match t.kind {
            SemTypeKind.List => {
                if t.elem_type == elem_id { return i }
            }
            _ => {}
        }
    }
    return semTypeAdd(&mut table, SemTypeKind.List, -1, -1, elem_id, -1)
}

fn semTypeMakeOption(table: &mut TypeTable, elem_id: Int) -> Int {
    for i in 8..table.types.length {
        let t = &table.types[i]
        match t.kind {
            SemTypeKind.Option => {
                if t.elem_type == elem_id { return i }
            }
            _ => {}
        }
    }
    return semTypeAdd(&mut table, SemTypeKind.Option, -1, -1, elem_id, -1)
}

fn semTypeMakeResult(table: &mut TypeTable, ok_id: Int, err_id: Int) -> Int {
    for i in 8..table.types.length {
        let t = &table.types[i]
        match t.kind {
            SemTypeKind.Result => {
                if t.elem_type == ok_id && t.nominal_id == err_id { return i }
            }
            _ => {}
        }
    }
    return semTypeAdd(&mut table, SemTypeKind.Result, -1, -1, ok_id, err_id)
}

fn semTypeMakeArray(table: &mut TypeTable, elem_id: Int) -> Int {
    for i in 8..table.types.length {
        let t = &table.types[i]
        match t.kind {
            SemTypeKind.Array => {
                if t.elem_type == elem_id { return i }
            }
            _ => {}
        }
    }
    return semTypeAdd(&mut table, SemTypeKind.Array, -1, -1, elem_id, -1)
}

fn semTypeMakeSlice(table: &mut TypeTable, elem_id: Int) -> Int {
    for i in 8..table.types.length {
        let t = &table.types[i]
        match t.kind {
            SemTypeKind.Slice => {
                if t.elem_type == elem_id { return i }
            }
            _ => {}
        }
    }
    return semTypeAdd(&mut table, SemTypeKind.Slice, -1, -1, elem_id, -1)
}

fn semTypeIsNumeric(kind: &SemTypeKind) -> Bool {
    match kind {
        SemTypeKind.Int => { return true }
        SemTypeKind.Float => { return true }
        SemTypeKind.F32 => { return true }
        _ => { return false }
    }
}

fn semTypeIsCopy(kind: &SemTypeKind) -> Bool {
    match kind {
        SemTypeKind.Int => { return true }
        SemTypeKind.Float => { return true }
        SemTypeKind.F32 => { return true }
        SemTypeKind.Bool => { return true }
        SemTypeKind.Unit => { return true }
        _ => { return false }
    }
}

fn semTypeIsMove(kind: &SemTypeKind) -> Bool {
    return !semTypeIsCopy(kind)
}

fn semTypeEquals(table: &TypeTable, a: Int, b: Int) -> Bool {
    if a == b { return true }
    if a == 0 || b == 0 { return true }
    if a == 7 || b == 7 { return true }
    if a < 0 || a >= table.types.length { return false }
    if b < 0 || b >= table.types.length { return false }

    let ta = &table.types[a]
    let tb = &table.types[b]

    match ta.kind {
        SemTypeKind.Int => {
            match tb.kind {
                SemTypeKind.Int => { return true }
                _ => { return false }
            }
        }
        SemTypeKind.Float => {
            match tb.kind {
                SemTypeKind.Float => { return true }
                _ => { return false }
            }
        }
        SemTypeKind.F32 => {
            match tb.kind {
                SemTypeKind.F32 => { return true }
                _ => { return false }
            }
        }
        SemTypeKind.Bool => {
            match tb.kind {
                SemTypeKind.Bool => { return true }
                _ => { return false }
            }
        }
        SemTypeKind.Text => {
            match tb.kind {
                SemTypeKind.Text => { return true }
                _ => { return false }
            }
        }
        SemTypeKind.Unit => {
            match tb.kind {
                SemTypeKind.Unit => { return true }
                _ => { return false }
            }
        }
        SemTypeKind.Struct => {
            match tb.kind {
                SemTypeKind.Struct => { return ta.nominal_id == tb.nominal_id }
                _ => { return false }
            }
        }
        SemTypeKind.Enum => {
            match tb.kind {
                SemTypeKind.Enum => { return ta.nominal_id == tb.nominal_id }
                _ => { return false }
            }
        }
        SemTypeKind.Ref => {
            match tb.kind {
                SemTypeKind.Ref => { return semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ => { return false }
            }
        }
        SemTypeKind.MutRef => {
            match tb.kind {
                SemTypeKind.MutRef => { return semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ => { return false }
            }
        }
        SemTypeKind.Array => {
            match tb.kind {
                SemTypeKind.Array => { return semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ => { return false }
            }
        }
        SemTypeKind.Slice => {
            match tb.kind {
                SemTypeKind.Slice => { return semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ => { return false }
            }
        }
        SemTypeKind.List => {
            match tb.kind {
                SemTypeKind.List => { return semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ => { return false }
            }
        }
        SemTypeKind.Option => {
            match tb.kind {
                SemTypeKind.Option => { return semTypeEquals(table, ta.elem_type, tb.elem_type) }
                _ => { return false }
            }
        }
        SemTypeKind.Result => {
            match tb.kind {
                SemTypeKind.Result => {
                    return semTypeEquals(table, ta.elem_type, tb.elem_type) && semTypeEquals(table, ta.nominal_id, tb.nominal_id)
                }
                _ => { return false }
            }
        }
        _ => { return false }
    }
}

fn semTypeName(table: &TypeTable, source: &Text, type_id: Int) -> Text {
    if type_id < 0 || type_id >= table.types.length {
        return "<invalid>"
    }
    let t = &table.types[type_id]
    match t.kind {
        SemTypeKind.Unknown => { return "Unknown" }
        SemTypeKind.Int => { return "Int" }
        SemTypeKind.Float => { return "Float" }
        SemTypeKind.F32 => { return "F32" }
        SemTypeKind.Bool => { return "Bool" }
        SemTypeKind.Text => { return "Text" }
        SemTypeKind.Unit => { return "()" }
        SemTypeKind.Error => { return "<error>" }
        SemTypeKind.Struct => {
            return "Struct"
        }
        SemTypeKind.Enum => {
            return "Enum"
        }
        SemTypeKind.Ref => {
            let inner = semTypeName(table, source, t.elem_type)
            return "&{inner}"
        }
        SemTypeKind.MutRef => {
            let inner = semTypeName(table, source, t.elem_type)
            return "&mut {inner}"
        }
        SemTypeKind.Array => {
            let inner = semTypeName(table, source, t.elem_type)
            return "[{inner}]"
        }
        SemTypeKind.Slice => {
            let inner = semTypeName(table, source, t.elem_type)
            return "&[{inner}]"
        }
        SemTypeKind.List => {
            let inner = semTypeName(table, source, t.elem_type)
            return "List<{inner}>"
        }
        SemTypeKind.Option => {
            let inner = semTypeName(table, source, t.elem_type)
            return "Option<{inner}>"
        }
        SemTypeKind.Result => {
            let inner = semTypeName(table, source, t.elem_type)
            return "Result<{inner}>"
        }
    }
}
