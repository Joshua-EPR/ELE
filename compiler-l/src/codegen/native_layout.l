// Initial ABI-independent compound-value layout planner for the ELE-written
// native backend. Offsets, size and alignment are checked at every insertion.
// This is a foundation, NOT native struct/enum ownership or heap support.
// The final ABI-specific lowering must verify layouts against the selected
// target and against the Stage 1 type descriptions before using them.
const NATIVE_LAYOUT_MAX_BYTES = 1048576
const NATIVE_LAYOUT_MAX_ALIGN = 4096
const NATIVE_LAYOUT_MAX_FIELDS = 256

pub struct NativeLayout {
    size: Int
    align: Int
    sealed: Bool
    error: Int
    offsets: List<Int>
    sizes: List<Int>
    aligns: List<Int>
    owned: List<Bool>
}

pub fn nativeLayoutNew() -> NativeLayout {
    return NativeLayout(size: 0, align: 1, sealed: false, error: 0,
        offsets: List[], sizes: List[], aligns: List[], owned: List[])
}

// All alignments are powers of two; capping the maximum prevents overflow
// during validation and avoids allocating arbitrarily large padding.
fn nativeLayoutValidAlign(value: Int) -> Bool {
    if value < 1 || value > NATIVE_LAYOUT_MAX_ALIGN { return false }
    var power = 1
    while power < value { power *= 2 }
    return power == value
}

fn nativeLayoutRoundUp(value: Int, alignment: Int) -> Int {
    let rem = value % alignment
    if rem == 0 { return value }
    return value + alignment - rem
}

// Insert a field in declaration order. Returns its byte offset, or -1 on
// error. A zero-byte field is permitted (empty aggregate); it still has a
// well-defined offset and may increase aggregate alignment.
pub fn nativeLayoutAdd(layout: &mut NativeLayout, size: Int, alignment: Int, owned: Bool) -> Int {
    if layout.error != 0 { return -1 }
    if layout.sealed { layout.error = 1; return -1 }
    if layout.offsets.length >= NATIVE_LAYOUT_MAX_FIELDS { layout.error = 2; return -1 }
    if size < 0 || size > NATIVE_LAYOUT_MAX_BYTES || !nativeLayoutValidAlign(alignment) {
        layout.error = 3
        return -1
    }
    // Avoid overflow by verifying the maximal possible padding first.
    if layout.size > NATIVE_LAYOUT_MAX_BYTES - (alignment - 1) {
        layout.error = 4
        return -1
    }
    let offset = nativeLayoutRoundUp(layout.size, alignment)
    if offset > NATIVE_LAYOUT_MAX_BYTES - size { layout.error = 4; return -1 }
    layout.offsets.push(offset)
    layout.sizes.push(size)
    layout.aligns.push(alignment)
    layout.owned.push(owned)
    layout.size = offset + size
    if alignment > layout.align { layout.align = alignment }
    return offset
}

// Final size includes tail padding required for arrays of this aggregate.
// Idempotent, but adding more fields afterwards is forbidden.
pub fn nativeLayoutSeal(layout: &mut NativeLayout) -> Int {
    if layout.error != 0 { return -1 }
    if layout.sealed { return layout.size }
    if layout.size > NATIVE_LAYOUT_MAX_BYTES - (layout.align - 1) {
        layout.error = 4
        return -1
    }
    layout.size = nativeLayoutRoundUp(layout.size, layout.align)
    layout.sealed = true
    return layout.size
}

pub fn nativeLayoutOffset(layout: &NativeLayout, field: Int) -> Int {
    if field < 0 || field >= layout.offsets.length { return -1 }
    return layout.offsets[field]
}

// Deterministic right-to-left field traversal is the planned destruction
// order. Actual drop instructions and runtime glue remain future work.
pub fn nativeLayoutDropField(layout: &NativeLayout, ordinal: Int) -> Int {
    if ordinal < 0 { return -1 }
    var remaining = ordinal
    var i = layout.owned.length
    while i > 0 {
        i -= 1
        if layout.owned[i] {
            if remaining == 0 { return i }
            remaining -= 1
        }
    }
    return -1
}

// Primitive layout helpers. Pointer size is x86-64-specific; this metadata
// does not imply a C or Rust ABI and is not yet bound to a Stage 1 TypeId.
pub fn nativeLayoutInt(layout: &mut NativeLayout) -> Int {
    return nativeLayoutAdd(&mut layout, 8, 8, false)
}

pub fn nativeLayoutBool(layout: &mut NativeLayout) -> Int {
    return nativeLayoutAdd(&mut layout, 1, 1, false)
}

pub fn nativeLayoutPointer(layout: &mut NativeLayout, owns: Bool) -> Int {
    return nativeLayoutAdd(&mut layout, 8, 8, owns)
}

pub fn nativeLayoutNested(layout: &mut NativeLayout, child: &NativeLayout, owns: Bool) -> Int {
    if child.error != 0 || !child.sealed {
        layout.error = 5
        return -1
    }
    return nativeLayoutAdd(&mut layout, child.size, child.align, owns)
}

// Largest aggregate the planner lays out (NATIVE_LAYOUT_MAX_BYTES).
expose flow nativeLayoutMaxBytes() => Int {
    give NATIVE_LAYOUT_MAX_BYTES
}
