take codegen.native_layout

// Stage 0 integration fixture: verify ABI-independent aggregate offsets,
// padding, field ownership metadata, and explicit errors. This is NOT a
// native struct+drop execution test.
flow main() => Int {
    change layout = nativeLayoutNew()
    when nativeLayoutAdd(edit layout, 1, 1, false) != 0 { give 1 }
    when nativeLayoutAdd(edit layout, 8, 8, true) != 8 { give 2 }
    when nativeLayoutAdd(edit layout, 2, 2, true) != 16 { give 3 }
    when nativeLayoutSeal(edit layout) != 24 { give 4 }
    when layout.align != 8 { give 5 }
    when nativeLayoutOffset(view layout, 0) != 0 { give 6 }
    when nativeLayoutOffset(view layout, 1) != 8 { give 7 }
    when nativeLayoutOffset(view layout, 2) != 16 { give 8 }
    when nativeLayoutDropField(view layout, 0) != 2 { give 9 }
    when nativeLayoutDropField(view layout, 1) != 1 { give 10 }
    when nativeLayoutDropField(view layout, 2) != -1 { give 11 }
    when nativeLayoutAdd(edit layout, 1, 1, false) != -1 { give 12 }
    when layout.error != 1 { give 13 }

    change invalid = nativeLayoutNew()
    when nativeLayoutAdd(edit invalid, 1, 3, false) != -1 { give 14 }
    when invalid.error != 3 { give 15 }

    change bad_nested = nativeLayoutNew()
    when nativeLayoutNested(edit bad_nested, view layout, true) != -1 { give 16 }
    when bad_nested.error != 5 { give 26 }
    // The original layout has an error after a prohibited post-seal append.
    change nested = nativeLayoutNew()
    change inner = nativeLayoutNew()
    when nativeLayoutInt(edit inner) != 0 { give 22 }
    when nativeLayoutBool(edit inner) != 8 { give 23 }
    when nativeLayoutSeal(edit inner) != 16 { give 24 }
    when nativeLayoutNested(edit nested, view inner, true) != 0 { give 25 }
    when nativeLayoutAdd(edit nested, 1, 1, false) != 16 { give 17 }
    when nativeLayoutSeal(edit nested) != 24 { give 18 }

    change oversized = nativeLayoutNew()
    when nativeLayoutAdd(edit oversized, 1048576, 8, true) != 0 { give 19 }
    when nativeLayoutAdd(edit oversized, 8, 8, false) != -1 { give 20 }
    when oversized.error != 4 { give 21 }
    print("ELE_LAYOUT_OK")
    give 0
}
