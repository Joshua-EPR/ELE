import symbols

pub struct Scope {
    parent: Int
}

pub struct ScopeTree {
    scopes: List<Scope>
    current_scope: Int
}

pub fn scopeTreeNew() -> ScopeTree {
    let s_list: List<Scope> = List[]
    var tree = ScopeTree(scopes: s_list, current_scope: 0)
    tree.scopes.push(Scope(parent: -1))
    return tree
}

pub fn scopePush(tree: &mut ScopeTree) -> Int {
    let id = tree.scopes.length
    tree.scopes.push(Scope(parent: tree.current_scope))
    tree.current_scope = id
    return id
}

pub fn scopePop(tree: &mut ScopeTree) {
    if tree.current_scope > 0 && tree.current_scope < tree.scopes.length {
        tree.current_scope = tree.scopes[tree.current_scope].parent
    }
}

pub fn scopeAddSymbol(tree: &mut ScopeTree, sym_id: Int) {
}

pub fn scopeLookupCurrent(tree: &ScopeTree, sym_table: &SymbolTable, source: &Text, name_start: Int, name_end: Int) -> Int {
    let cur = tree.current_scope
    for i in 0..sym_table.symbols.length {
        let sym = &sym_table.symbols[i]
        if sym.scope_id == cur {
            if symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                return i
            }
        }
    }
    return -1
}

pub fn scopeLookupAll(tree: &ScopeTree, sym_table: &SymbolTable, source: &Text, name_start: Int, name_end: Int) -> Int {
    var cur = tree.current_scope
    while cur >= 0 && cur < tree.scopes.length {
        for i in 0..sym_table.symbols.length {
            let sym = &sym_table.symbols[i]
            if sym.scope_id == cur {
                if symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                    return i
                }
            }
        }
        cur = tree.scopes[cur].parent
    }
    return -1
}

// Duplicate detection within one module: only symbols owned by the same
// module count as colliding, so two modules may each declare a private
// symbol with the same name.
pub fn scopeLookupCurrentModule(tree: &ScopeTree, sym_table: &SymbolTable, source: &Text, name_start: Int, name_end: Int, module_id: Int) -> Int {
    let cur = tree.current_scope
    for i in 0..sym_table.symbols.length {
        let sym = &sym_table.symbols[i]
        if sym.scope_id == cur && sym.module_id == module_id {
            if symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                return i
            }
        }
    }
    return -1
}

// Name resolution with transitive import visibility. Local/current-module
// names shadow imported declarations. Multiple imported public symbols with
// the same unqualified name are ambiguous (return -2), not first-match wins.
pub fn scopeLookupAllVisible(tree: &ScopeTree, sym_table: &SymbolTable, source: &Text, name_start: Int, name_end: Int, module_id: Int, allowed: &List<Int>, module_count: Int) -> Int {
    var cur = tree.current_scope
    while cur >= 0 && cur < tree.scopes.length {
        var imported = -1
        var ambiguous = false
        for i in 0..sym_table.symbols.length {
            let sym = &sym_table.symbols[i]
            if sym.scope_id == cur && symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                if sym.module_id < 0 || sym.module_id == module_id { return i }
                if symbolVisible(sym, module_id, allowed, module_count) {
                    if imported >= 0 {
                        // If the same symbol is reachable through two different
                        // modules we must reject the use instead of silently picking
                        // the first match. This preserves the import-ambiguity
                        // diagnostic required for public symbols from different
                        // modules.
                        if imported != i { ambiguous = true }
                    } else {
                        imported = i
                    }
                }
            }
        }
        if ambiguous { return -2 }
        if imported >= 0 { return imported }
        cur = tree.scopes[cur].parent
    }
    return -1
}
