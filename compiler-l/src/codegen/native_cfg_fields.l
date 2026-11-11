import lir_tokens
import native_cfg_defs
import native_cfg_types

// Text fields of shapes in the ELE-written CFG backend: projected sources
// of `print`/`append` (`ref pN.k[.j] 0`) and `i dropfield <place> v<flag>|-`
// (kind 17), which releases the Text stored in a field.
//
// Ownership of Text fields is checked with move paths (native_cfg_paths):
// reading a Text field of an owned shape moves it, dropfield releases it,
// and a store may only fill a field whose Text was moved or released.

// `ref <place> 0` as the source of print/append. Returns 0 or a code.
expose flow cfgReadSourceRef(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) => Int {
    hold place = cfgReadPlace(edit p, f, source, edit reader)
    hold exclusive = nativeNumber(source, edit reader)
    when reader.error != 0 || place.variable < 0 || exclusive != 0 { give 13 }
    inst.op = place.variable
    inst.src_field = place.field
    inst.src_sub = place.subfield
    inst.src_ext = place.ext
    give 0
}

// Type of the source of print/append, seen through its place.
expose flow cfgSourcePlaceType(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    when inst.op < 0 { give cfgOperandType(p, f, view inst.a) }
    hold place = CfgPlace(variable: inst.op, field: inst.src_field, subfield: inst.src_sub, ext: inst.src_ext)
    give cfgPlaceType(p, f, view place)
}

expose flow cfgReadDropField(p: edit CfgProgram, f: Int, source: view Text, reader: edit NativeReader, inst: edit CfgInst) {
    inst.kind = 17
    hold place = cfgReadPlace(edit p, f, source, edit reader)
    inst.place_var = place.variable
    inst.place_field = place.field
    inst.place_subfield = place.subfield
    inst.place_ext = place.ext
    change probe = NativeReader(offset: reader.offset, error: 0)
    hold flag = nativeWord(source, edit probe)
    when nativeEquals(source, view flag, "-") {
        reader.offset = probe.offset
        inst.op = -1
    } otherwise {
        inst.op = nativeId(source, edit reader, 118)
    }
}

// A dropfield names a Text or list field (not a whole variable, and not a
// place inside a list) and an optional Bool flag.
expose flow cfgCheckDropField(p: view CfgProgram, f: Int, inst: view CfgInst) => Int {
    hold place = CfgPlace(variable: inst.place_var, field: inst.place_field, subfield: inst.place_subfield, ext: -1)
    when inst.place_field < 0 || inst.place_ext >= 0 || !cfgHeapDirect(p, cfgPlaceType(p, f, view place)) { give 92 }
    when inst.op >= 0 {
        when inst.op >= p.functions[f].vars { give 94 }
        hold first = p.functions[f].first_var
        when p.types_code[first + inst.op] != 1 || p.var_ref[first + inst.op] { give 94 }
    }
    give 0
}

// Whether a value of type `ty` owns heap storage: a Text or a list, directly
// or in a nested field. Only such values need drops; the others may be
// copied bitwise. A list answers without looking at its element, so a shape
// that holds a list of itself terminates.
expose flow cfgOwnsHeap(p: view CfgProgram, ty: Int) => Bool {
    when cfgHeapDirect(p, ty) { give true }
    when ty < 2 || ty - 2 >= p.structs.length { give false }
    hold first = p.structs[ty - 2].first_field
    each k among 0..p.structs[ty - 2].fields {
        when cfgOwnsHeap(p, p.fields[first + k].ty) { give true }
    }
    give false
}
