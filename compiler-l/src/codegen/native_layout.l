// Initial ABI-independent compound-value layout planner for the ELE-written
// native backend. Offsets, size and alignment are checked at every insertion.
// This is a foundation, NOT native struct/enum ownership or heap support.
// The final ABI-specific lowering must verify layouts against the selected
// target and against the Stage 1 type descriptions before using them.
fixed NATIVE_LAYOUT_MAX_BYTES = 1048576
fixed NATIVE_LAYOUT_MAX_ALIGN = 4096
fixed NATIVE_LAYOUT_MAX_FIELDS = 256

expose shape NativeLayout {
    size: Int
    align: Int
    sealed: Bool
    error: Int
    offsets: List of[Int]
    sizes: List of[Int]
    aligns: List of[Int]
    owned: List of[Bool]
}

expose flow nativeLayoutNew() => NativeLayout {
    give NativeLayout(size: 0, align: 1, sealed: false, error: 0,
        offsets: List[], sizes: List[], aligns: List[], owned: List[])
}

// All alignments are powers of two; capping the maximum prevents overflow
// during validation and avoids allocating arbitrarily large padding.
flow nativeLayoutValidAlign(value: Int) => Bool {
    when value < 1 || value > NATIVE_LAYOUT_MAX_ALIGN { give false }
    change power = 1
    during power < value { power *= 2 }
    give power == value
}

flow nativeLayoutRoundUp(value: Int, alignment: Int) => Int {
    hold rem = value % alignment
    when rem == 0 { give value }
    give value + alignment - rem
}

// Insert a field in declaration order. Returns its byte offset, or -1 on
// error. A zero-byte field is permitted (empty aggregate); it still has a
// well-defined offset and may increase aggregate alignment.
expose flow nativeLayoutAdd(layout: edit NativeLayout, size: Int, alignment: Int, owned: Bool) => Int {
    when layout.error != 0 { give -1 }
    when layout.sealed { layout.error = 1; give -1 }
    when layout.offsets.length >= NATIVE_LAYOUT_MAX_FIELDS { layout.error = 2; give -1 }
    when size < 0 || size > NATIVE_LAYOUT_MAX_BYTES || !nativeLayoutValidAlign(alignment) {
        layout.error = 3
        give -1
    }
    // Avoid overflow by verifying the maximal possible padding first.
    when layout.size > NATIVE_LAYOUT_MAX_BYTES - (alignment - 1) {
        layout.error = 4
        give -1
    }
    hold offset = nativeLayoutRoundUp(layout.size, alignment)
    when offset > NATIVE_LAYOUT_MAX_BYTES - size { layout.error = 4; give -1 }
    layout.offsets@push(offset)
    layout.sizes@push(size)
    layout.aligns@push(alignment)
    layout.owned@push(owned)
    layout.size = offset + size
    when alignment > layout.align { layout.align = alignment }
    give offset
}

// Final size includes tail padding required for arrays of this aggregate.
// Idempotent, but adding more fields afterwards is forbidden.
expose flow nativeLayoutSeal(layout: edit NativeLayout) => Int {
    when layout.error != 0 { give -1 }
    when layout.sealed { give layout.size }
    when layout.size > NATIVE_LAYOUT_MAX_BYTES - (layout.align - 1) {
        layout.error = 4
        give -1
    }
    layout.size = nativeLayoutRoundUp(layout.size, layout.align)
    layout.sealed = true
    give layout.size
}

expose flow nativeLayoutOffset(layout: view NativeLayout, field: Int) => Int {
    when field < 0 || field >= layout.offsets.length { give -1 }
    give layout.offsets[field]
}

// Deterministic right-to-left field traversal is the planned destruction
// order. Actual drop instructions and runtime glue remain future work.
expose flow nativeLayoutDropField(layout: view NativeLayout, ordinal: Int) => Int {
    when ordinal < 0 { give -1 }
    change remaining = ordinal
    change i = layout.owned.length
    during i > 0 {
        i -= 1
        when layout.owned[i] {
            when remaining == 0 { give i }
            remaining -= 1
        }
    }
    give -1
}

// Primitive layout helpers. Pointer size is x86-64-specific; this metadata
// does not imply a C or Rust ABI and is not yet bound to a Stage 1 TypeId.
expose flow nativeLayoutInt(layout: edit NativeLayout) => Int {
    give nativeLayoutAdd(edit layout, 8, 8, false)
}

expose flow nativeLayoutBool(layout: edit NativeLayout) => Int {
    give nativeLayoutAdd(edit layout, 1, 1, false)
}

expose flow nativeLayoutPointer(layout: edit NativeLayout, owns: Bool) => Int {
    give nativeLayoutAdd(edit layout, 8, 8, owns)
}

expose flow nativeLayoutNested(layout: edit NativeLayout, child: view NativeLayout, owns: Bool) => Int {
    when child.error != 0 || !child.sealed {
        layout.error = 5
        give -1
    }
    give nativeLayoutAdd(edit layout, child.size, child.align, owns)
}

// Largest aggregate the planner lays out (NATIVE_LAYOUT_MAX_BYTES).
expose flow nativeLayoutMaxBytes() => Int {
    give NATIVE_LAYOUT_MAX_BYTES
}
