// ELE v2 syntax adapter for source borrowing. Both spellings share
// Stage 1's existing ownership and loan verification without new semantics.
// Returns 0 (not a borrow), 1 (view/shared), or 2 (edit/exclusive).
pub fn semaBorrowSyntaxKind(source: &Text, start: Int, end: Int) -> Int {
    if start < 0 || end <= start || end > source.byteLength { return 0 }
    let first = source.byteAt(start)
    if first == 38 {
        if end - start >= 4 { return 2 }
        return 1
    }
    if end - start == 4 {
        if first == 118 { return 1 }
        if first == 101 { return 2 }
    }
    return 0
}
