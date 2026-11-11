import lir_tokens
import native_cfg_defs
import native_cfg_types

// Local loans of the ELE-written CFG backend: `i loan vD <place> <0|1>`
// (kind 22) gives the local reference `vD` (`var vD ref T`, D >= params) the
// address of a place, shared (0) or exclusive (1).
//
// Stage 1 proves lifetimes on the source. This backend does not trust that
// proof: it accepts a loan only under rules it can check on the LIR itself.
// - A local reference is defined by exactly one `loan` instruction, so the
//   storage it may point into is known statically: the root variable of the
//   loaned place and its static prefix (field, subfield). A loan through
//   another local reference takes that reference's root, whole.
// - The reference is a place root only. It is never a value: it cannot be
//   copied, moved, stored, returned or dropped, so it cannot escape.
// - The verifier keeps one "valid" bit per local reference in its dataflow
//   (intersection at joins). The loan sets it. It dies when the root is
//   moved, dropped or given a new value, and when overlapping storage is
//   written: a store, an append, a push or reserve (which may move a list
//   buffer), a dropfield, an exclusive reference argument or an exclusive
//   loan, each through the root or through another reference to it.
//   Using a dead reference is rejected (57).
// - Writing through a local reference needs an exclusive loan (98), and an
//   exclusive loan of a reference parameter makes that parameter exclusive.
// - A field cannot be released through a local reference (95): the owner's
//   move paths would not see it.
//
// Rejection code 96: malformed loan, or a local reference without one.

expose flow cfgReadLoan(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) {
    inst.kind = 22
    inst.dst = nativeId(source, edit reader, 118)
    hold place = cfgReadPlace(edit p, f, source, edit reader)
    inst.place_var = place.variable
    inst.place_field = place.field
    inst.place_subfield = place.subfield
    inst.place_ext = place.ext
    inst.op = nativeNumber(source, edit reader)
}

// Checks a well-formed loan and records the root of its reference.
expose flow cfgCheckLoan(p: edit CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold first = p.functions[f].first_var
    hold params = p.functions[f].params
    hold slot = first + inst.dst
    when !p.var_ref[slot] || inst.dst < params || p.ref_mut[slot] >= 0 { give 96 }
    when inst.op != 0 && inst.op != 1 { give 96 }
    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: inst.place_ext)
    when cfgPlaceType(p, f, view place) != p.types_code[slot] { give 96 }
    change root = inst.place_var
    change field = inst.place_field
    change sub = inst.place_subfield
    hold through = first + inst.place_var
    when p.var_ref[through] && inst.place_var >= params {
        // A reborrow: valid while the first reference is, over its root.
        when p.ref_root[through] < 0 || inst.place_var == inst.dst { give 96 }
        when inst.op == 1 && p.ref_mut[through] != 1 { give 98 }
        root = p.ref_root[through]
        field = -1
        sub = -1
    }
    p.ref_root[slot] = root
    p.ref_field[slot] = field
    p.ref_sub[slot] = sub
    p.ref_mut[slot] = inst.op
    give 0
}

flow cfgLoanOverlap(fa: Int, sa: Int, fb: Int, sb: Int) => Bool {
    when fa >= 0 && fb >= 0 && fa != fb { give false }
    when fa >= 0 && fb >= 0 && sa >= 0 && sb >= 0 && sa != sb { give false }
    give true
}

// A write through place root `w` with static prefix (wf, ws) may touch the
// storage that local reference `l` points into.
flow cfgWriteKills(p: view CfgProgram, f: Int, l: Int, w: Int, wf: Int, ws: Int) => Bool {
    when w == l || w < 0 { give false }
    hold first = p.functions[f].first_var
    change root = w
    change rf = wf
    change rs = ws
    when p.var_ref[first + w] && w >= p.functions[f].params {
        root = p.ref_root[first + w]
        rf = p.ref_field[first + w]
        rs = p.ref_sub[first + w]
    }
    when root != p.ref_root[first + l] { give false }
    give cfgLoanOverlap(rf, rs, p.ref_field[first + l], p.ref_sub[first + l])
}

// `inst` writes storage that local reference `l` may point into. Moves and
// new values of the root are the verifier's part (it knows what moves).
expose flow cfgLoanKilledBy(p: view CfgProgram, f: Int, inst: view CfgInst, l: Int) => Bool {
    hold kind = inst.kind
    hold writes = kind == 6 || kind == 12 || kind == 17 || kind == 19 || kind == 20
    when writes {
        when cfgWriteKills(p, f, l, inst.place_var, inst.place_field, inst.place_subfield) { give true }
    }
    when kind == 22 && inst.dst != l {
        hold first = p.functions[f].first_var
        // A shared loan also invalidates an overlapping older exclusive
        // loan: otherwise two usable references alias the same storage.
        when inst.op == 1 || p.ref_mut[first + l] == 1 {
            // Reborrowing directly through l must suspend its old access.
            when inst.place_var == l { give true }
            when cfgWriteKills(p, f, l, inst.place_var, inst.place_field, inst.place_subfield) { give true }
        }
    }
    when kind == 3 {
        each n among 0..inst.argc {
            hold k = inst.arg_first + n
            when p.call_ref[k] == 1 && cfgWriteKills(p, f, l, p.call_args[k].value, p.call_field[k], p.call_sub[k]) { give true }
        }
    }
    give false
}

// `v` is a local reference of function `f` that is not exclusive.
flow cfgSharedLocal(p: view CfgProgram, f: Int, v: Int) => Bool {
    when v < p.functions[f].params || v >= p.functions[f].vars { give false }
    hold slot = p.functions[f].first_var + v
    give p.var_ref[slot] && p.ref_mut[slot] != 1
}

// Every write through a local reference of `f` goes through an exclusive
// loan, and no field is released through one.
expose flow cfgCheckLoanModes(p: view CfgProgram, f: Int) => Int {
    hold first_block = p.functions[f].first_block
    each b among first_block..(first_block + p.functions[f].blocks) {
        hold first = p.blocks[b].first
        each i among first..(first + p.blocks[b].count) {
            hold kind = p.insts[i].kind
            hold target = p.insts[i].place_var
            when kind == 17 && target >= p.functions[f].params && p.var_ref[p.functions[f].first_var + target] { give 95 }
            when (kind == 6 || kind == 12 || kind == 19 || kind == 20) && cfgSharedLocal(p, f, target) { give 98 }
            when kind == 3 {
                each n among 0..p.insts[i].argc {
                    hold k = p.insts[i].arg_first + n
                    when p.call_ref[k] == 1 && cfgSharedLocal(p, f, p.call_args[k].value) { give 98 }
                }
            }
        }
    }
    give 0
}
