import native_cfg_defs

// Move paths for partial moves out of shapes and for their Text fields.
//
// Every field and subfield of a shape variable whose type is a shape, a
// choice or Text has an "initialized" bit in the verifier's dataflow, next
// to the bits of the variables (intersection at joins):
// - reading the place out of an owned shape (`i read`) moves it: its bits
//   die; through a reference the read is a copy and changes nothing;
// - `i dropfield` releases a Text field: its bit dies;
// - `i store` to a place, or a new whole value of the variable, sets them;
// - a whole move of the variable kills all of them;
// - using a place, or the whole variable, requires every bit within it and
//   the bit of its enclosing field.
// Text bits also carry ownership: a live Text field of a live variable at
// `return` leaks (59); storing a Text over a live one leaks (59); and a
// reference parameter must give its referent back whole (95).
// Primitive fields are copied, so they have no bit of their own.

expose shape CfgPaths {
    var_of: List<Int>
    field: List<Int>
    sub: List<Int>
    text: List<Bool>
}

flow cfgTracked(p: view CfgProgram, ty: Int) => Bool {
    give ty >= 2 || ty == -3
}

flow cfgPathPush(paths: edit CfgPaths, v: Int, field: Int, sub: Int, text: Bool) {
    paths.var_of@push(v)
    paths.field@push(field)
    paths.sub@push(sub)
    paths.text@push(text)
}

// Every aggregate- or Text-typed field `vN.k` and subfield `vN.k.j` of the
// shape variables (owned or referenced) of function `f`.
expose flow cfgPathsOf(p: view CfgProgram, f: Int) => CfgPaths {
    change paths = CfgPaths(var_of: List[], field: List[], sub: List[], text: List[])
    hold first = p.functions[f].first_var
    each v among 0..p.functions[f].vars {
        hold ty = p.types_code[first + v]
        when ty >= 2 && ty - 2 < p.structs.length {
            hold first_field = p.structs[ty - 2].first_field
            each k among 0..p.structs[ty - 2].fields {
                hold field_ty = p.fields[first_field + k].ty
                when cfgTracked(p, field_ty) {
                    cfgPathPush(edit paths, v, k, -1, field_ty == -3)
                }
                when field_ty >= 2 && field_ty - 2 < p.structs.length {
                    hold child_first = p.structs[field_ty - 2].first_field
                    each j among 0..p.structs[field_ty - 2].fields {
                        hold sub_ty = p.fields[child_first + j].ty
                        when cfgTracked(p, sub_ty) {
                            cfgPathPush(edit paths, v, k, j, sub_ty == -3)
                        }
                    }
                }
            }
        }
    }
    give paths
}

// Path `k` lies inside place (v, field, sub): a move or a release of the
// place kills it and a store to the place initializes it again. Field -1
// is the whole variable.
expose flow cfgPathWithin(paths: view CfgPaths, k: Int, v: Int, field: Int, sub: Int) => Bool {
    when paths.var_of[k] != v { give false }
    when field < 0 { give true }
    when paths.field[k] != field { give false }
    give sub < 0 || paths.sub[k] == sub
}

// Path `k` must be initialized to use place (v, field, sub): the paths
// inside it and the enclosing field `v.field` when the place is a subfield.
expose flow cfgPathNeeded(paths: view CfgPaths, k: Int, v: Int, field: Int, sub: Int) => Bool {
    when cfgPathWithin(paths, k, v, field, sub) { give true }
    give paths.var_of[k] == v && field >= 0 && sub >= 0 && paths.field[k] == field && paths.sub[k] < 0
}

// Every path needed by place (v, field, sub) is set in `live`, whose path
// bits start at index `vars`.
expose flow cfgPathsLive(paths: view CfgPaths, vars: Int, live: view List of[Bool], v: Int, field: Int, sub: Int) => Bool {
    each k among 0..paths.var_of.length {
        when cfgPathNeeded(paths, k, v, field, sub) && !live[vars + k] { give false }
    }
    give true
}

// Some Text path inside place (v, field, sub) is still live.
expose flow cfgTextLiveWithin(paths: view CfgPaths, vars: Int, live: view List of[Bool], v: Int, field: Int, sub: Int) => Bool {
    each k among 0..paths.var_of.length {
        when paths.text[k] && cfgPathWithin(paths, k, v, field, sub) && live[vars + k] { give true }
    }
    give false
}
