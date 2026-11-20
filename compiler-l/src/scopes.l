take symbols

expose shape Scope {
    parent: Int
}

expose shape ScopeTree {
    scopes: List of[Scope]
    current_scope: Int
    scope_head: List of[Int]
    sym_next: List of[Int]
}

expose flow scopeTreeNew() => ScopeTree {
    hold s_list: List of[Scope] = List[]
    hold h_list: List of[Int] = List[]
    hold n_list: List of[Int] = List[]
    change tree = ScopeTree(scopes: s_list, current_scope: 0, scope_head: h_list, sym_next: n_list)
    tree.scopes@push(Scope(parent: -1))
    tree.scope_head@push(-1)
    give tree
}

expose flow scopePush(tree: edit ScopeTree) => Int {
    hold id = tree.scopes.length
    tree.scopes@push(Scope(parent: tree.current_scope))
    during tree.scope_head.length <= id {
        tree.scope_head@push(-1)
    }
    tree.scope_head[id] = -1
    tree.current_scope = id
    give id
}

expose flow scopePop(tree: edit ScopeTree) {
    when tree.current_scope > 0 && tree.current_scope < tree.scopes.length {
        tree.current_scope = tree.scopes[tree.current_scope].parent
    }
}

expose flow scopeAddSymbol(tree: edit ScopeTree, sym_id: Int) {
    hold cur = tree.current_scope
    when cur < 0 { give }
    during tree.scope_head.length <= cur {
        tree.scope_head@push(-1)
    }
    during tree.sym_next.length <= sym_id {
        tree.sym_next@push(-1)
    }
    hold prev = tree.scope_head[cur]
    tree.sym_next[sym_id] = prev
    tree.scope_head[cur] = sym_id
}

expose flow scopeLookupCurrent(tree: view ScopeTree, sym_table: view SymbolTable, source: view Text, name_start: Int, name_end: Int) => Int {
    hold cur = tree.current_scope
    when cur < 0 || cur >= tree.scope_head.length { give -1 }
    change sym_id = tree.scope_head[cur]
    during sym_id >= 0 && sym_id < sym_table.symbols.length {
        hold sym = view sym_table.symbols[sym_id]
        when symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
            give sym_id
        }
        when sym_id >= tree.sym_next.length { leave }
        sym_id = tree.sym_next[sym_id]
    }
    give -1
}

expose flow scopeLookupAll(tree: view ScopeTree, sym_table: view SymbolTable, source: view Text, name_start: Int, name_end: Int) => Int {
    change cur = tree.current_scope
    during cur >= 0 && cur < tree.scopes.length {
        when cur < tree.scope_head.length {
            change sym_id = tree.scope_head[cur]
            during sym_id >= 0 && sym_id < sym_table.symbols.length {
                hold sym = view sym_table.symbols[sym_id]
                when symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                    give sym_id
                }
                when sym_id >= tree.sym_next.length { leave }
                sym_id = tree.sym_next[sym_id]
            }
        }
        cur = tree.scopes[cur].parent
    }
    give -1
}

// Duplicate detection within one module: only symbols owned by the same
// module count as colliding, so two modules may each declare a private
// symbol with the same name.
expose flow scopeLookupCurrentModule(tree: view ScopeTree, sym_table: view SymbolTable, source: view Text, name_start: Int, name_end: Int, module_id: Int) => Int {
    hold cur = tree.current_scope
    when cur < 0 || cur >= tree.scope_head.length { give -1 }
    change sym_id = tree.scope_head[cur]
    during sym_id >= 0 && sym_id < sym_table.symbols.length {
        hold sym = view sym_table.symbols[sym_id]
        when sym.module_id == module_id {
            when symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                give sym_id
            }
        }
        when sym_id >= tree.sym_next.length { leave }
        sym_id = tree.sym_next[sym_id]
    }
    give -1
}

// Name resolution with transitive import visibility. Local/current-module
// names shadow imported declarations. Multiple imported public symbols with
// the same unqualified name are ambiguous (return -2), not first-match wins.
expose flow scopeLookupAllVisible(tree: view ScopeTree, sym_table: view SymbolTable, source: view Text, name_start: Int, name_end: Int, module_id: Int, allowed: view List of[Int], module_count: Int) => Int {
    change cur = tree.current_scope
    during cur >= 0 && cur < tree.scopes.length {
        change imported = -1
        change ambiguous = false
        when cur < tree.scope_head.length {
            change sym_id = tree.scope_head[cur]
            during sym_id >= 0 && sym_id < sym_table.symbols.length {
                hold sym = view sym_table.symbols[sym_id]
                when symbolNamesEqual(source, sym.name_start, sym.name_end, name_start, name_end) {
                    when sym.module_id < 0 || sym.module_id == module_id { give sym_id }
                    when symbolVisible(sym, module_id, allowed, module_count) {
                        when imported >= 0 { ambiguous = true } otherwise { imported = sym_id }
                    }
                }
                when sym_id >= tree.sym_next.length { leave }
                sym_id = tree.sym_next[sym_id]
            }
        }
        when ambiguous { give -2 }
        when imported >= 0 { give imported }
        cur = tree.scopes[cur].parent
    }
    give -1
}
