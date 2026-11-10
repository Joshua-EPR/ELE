import codegen.native_layout

// Stage 0 integration fixture: verify ABI-independent aggregate offsets,
// padding, field ownership metadata, and explicit errors. This is NOT a
// native struct+drop execution test.
fn main() -> Int {
    var layout = nativeLayoutNew()
    if nativeLayoutAdd(&mut layout, 1, 1, false) != 0 { return 1 }
    if nativeLayoutAdd(&mut layout, 8, 8, true) != 8 { return 2 }
    if nativeLayoutAdd(&mut layout, 2, 2, true) != 16 { return 3 }
    if nativeLayoutSeal(&mut layout) != 24 { return 4 }
    if layout.align != 8 { return 5 }
    if nativeLayoutOffset(&layout, 0) != 0 { return 6 }
    if nativeLayoutOffset(&layout, 1) != 8 { return 7 }
    if nativeLayoutOffset(&layout, 2) != 16 { return 8 }
    if nativeLayoutDropField(&layout, 0) != 2 { return 9 }
    if nativeLayoutDropField(&layout, 1) != 1 { return 10 }
    if nativeLayoutDropField(&layout, 2) != -1 { return 11 }
    if nativeLayoutAdd(&mut layout, 1, 1, false) != -1 { return 12 }
    if layout.error != 1 { return 13 }

    var invalid = nativeLayoutNew()
    if nativeLayoutAdd(&mut invalid, 1, 3, false) != -1 { return 14 }
    if invalid.error != 3 { return 15 }

    var bad_nested = nativeLayoutNew()
    if nativeLayoutNested(&mut bad_nested, &layout, true) != -1 { return 16 }
    if bad_nested.error != 5 { return 26 }
    // The original layout has an error after a prohibited post-seal append.
    var nested = nativeLayoutNew()
    var inner = nativeLayoutNew()
    if nativeLayoutInt(&mut inner) != 0 { return 22 }
    if nativeLayoutBool(&mut inner) != 8 { return 23 }
    if nativeLayoutSeal(&mut inner) != 16 { return 24 }
    if nativeLayoutNested(&mut nested, &inner, true) != 0 { return 25 }
    if nativeLayoutAdd(&mut nested, 1, 1, false) != 16 { return 17 }
    if nativeLayoutSeal(&mut nested) != 24 { return 18 }

    var oversized = nativeLayoutNew()
    if nativeLayoutAdd(&mut oversized, 1048576, 8, true) != 0 { return 19 }
    if nativeLayoutAdd(&mut oversized, 8, 8, false) != -1 { return 20 }
    if oversized.error != 4 { return 21 }
    print("ELE_LAYOUT_OK")
    return 0
}
