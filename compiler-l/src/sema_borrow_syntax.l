// ELE v2 syntax adapter for source borrowing. Both spellings share
// Stage 1's existing ownership and loan verification without new semantics.
// Returns 0 (not a borrow), 1 (view/shared), or 2 (edit/exclusive).
expose flow semaBorrowSyntaxKind(source: view Text, start: Int, end: Int) => Int {
    when start < 0 || end <= start || end > source.byteLength { give 0 }
    hold first = source@byteAt(start)
    when first == 38 {
        when end - start >= 4 { give 2 }
        give 1
    }
    when end - start == 4 {
        when first == 118 { give 1 }
        when first == 101 { give 2 }
    }
    give 0
}
