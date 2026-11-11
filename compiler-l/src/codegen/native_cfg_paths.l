import native_cfg_defs

// Move paths for partial moves out of owned shapes.
//
// Reading an aggregate-typed field (`i read vD pN.k` or `pN.k.j` whose type
// is a shape or a choice) moves that field out of `vN`. The verifier tracks
// one extra "initialized" bit per aggregate-typed field and subfield of
// every owned shape variable, in the same dataflow as the variables:
// - a read of an aggregate place kills the bits within it;
// - a store to a place, or a new whole value of the variable, sets them;
// - a whole move of the variable kills all of them;
// - using a place, or the whole variable, requires every bit within it and
//   the bit of its enclosing field.
// Primitive fields are copied, so they have no bit of their own.

expose shape CfgPaths {
    var_of: List<Int>
    field: List<Int>
    sub: List<Int>
}

// Every aggregate-typed field `vN.k` and subfield `vN.k.j` of the owned
// shape variables of function `f`.
expose flow cfgPathsOf(p: view CfgProgram, f: Int) => CfgPaths {
    change paths = CfgPaths(var_of: List[], field: List[], sub: List[])
    hold first = p.functions[f].first_var
    each v among 0..p.functions[f].vars {
        hold ty = p.types_code[first + v]
        when !p.var_ref[first + v] && ty >= 2 && ty - 2 < p.structs.length {
            hold first_field = p.structs[ty - 2].first_field
            each k among 0..p.structs[ty - 2].fields {
                hold field_ty = p.fields[first_field + k].ty
                when field_ty >= 2 {
                    paths.var_of@push(v)
                    paths.field@push(k)
                    paths.sub@push(-1)
                }
                when field_ty >= 2 && field_ty - 2 < p.structs.length {
                    hold child_first = p.structs[field_ty - 2].first_field
                    each j among 0..p.structs[field_ty - 2].fields {
                        when p.fields[child_first + j].ty >= 2 {
                            paths.var_of@push(v)
                            paths.field@push(k)
                            paths.sub@push(j)
                        }
                    }
                }
            }
        }
    }
    give paths
}

// Path `k` lies inside place (v, field, sub): a read of an aggregate place
// kills it and a store to the place initializes it again. Field -1 is the
// whole variable.
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
