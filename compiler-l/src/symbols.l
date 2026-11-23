take sema_types

expose choice SymbolKind {
    Var
    Param
    Func
    Struct
    Enum
    Variant
    Field
    Const
}

expose shape Symbol {
    move_path: Int
    kind: SymbolKind
    name_start: Int
    name_end: Int
    type_id: Int
    scope_id: Int
    is_mut: Bool
    is_pub: Bool
    decl_id: Int
    decl_span_start: Int
    decl_span_end: Int
    // Owning module id for top-level declarations, -1 for locals/params.
    module_id: Int
}

expose shape SymbolTable {
    symbols: List of[Symbol]
}

expose flow symbolTableNew() => SymbolTable {
    hold list: List of[Symbol] = List[]
    give SymbolTable(symbols: list)
}

expose flow symbolAdd(table: edit SymbolTable, kind: SymbolKind, name_start: Int, name_end: Int, type_id: Int, scope_id: Int, is_mut: Bool, is_pub: Bool, decl_id: Int, start: Int, end: Int) => Int {
    hold id = table.symbols.length
    table.symbols@push(Symbol(
        move_path: -1,
        kind: kind,
        name_start: name_start,
        name_end: name_end,
        type_id: type_id,
        scope_id: scope_id,
        is_mut: is_mut,
        is_pub: is_pub,
        decl_id: decl_id,
        decl_span_start: start,
        decl_span_end: end,
        module_id: -1,
    ))
    give id
}

expose flow symbolSetModule(table: edit SymbolTable, sym_id: Int, module_id: Int) {
    when sym_id < 0 || sym_id >= table.symbols.length { give }
    table.symbols[sym_id].module_id = module_id
}

// A symbol is visible from `module_id` when it is a local (module -1), from
// the same module, or public. Cross-module access only happens through public
// symbols, which is the visibility rule enforced by the module system.
expose flow symbolVisible(sym: view Symbol, module_id: Int, allowed: view List of[Int], module_count: Int) => Bool {
    when sym.module_id < 0 { give true }
    when sym.module_id == module_id { give true }
    when !sym.is_pub { give false }
    // Without a module loader, preserve existing isolated Stage 1 tests.
    when module_count == 0 { give true }
    when module_id < 0 || module_id >= module_count { give false }
    when sym.module_id >= module_count { give false }
    hold pos = module_id * module_count + sym.module_id
    when pos < 0 || pos >= allowed.length { give false }
    give allowed[pos] == 1
}

expose flow symbolNamesEqual(source: view Text, a_start: Int, a_end: Int, b_start: Int, b_end: Int) => Bool {
    hold len_a = a_end - a_start
    hold len_b = b_end - b_start
    when len_a != len_b { give false }
    when len_a <= 0 { give true }
    when a_start == b_start { give true }
    when a_start < 0 || a_end > source.byteLength { give false }
    when b_start < 0 || b_end > source.byteLength { give false }
    when source@byteAt(a_start) != source@byteAt(b_start) { give false }

    each i among 1..len_a {
        when source@byteAt(a_start + i) != source@byteAt(b_start + i) {
            give false
        }
    }
    give true
}

expose flow symbolNameEqualsText(source: view Text, name_start: Int, name_end: Int, target: view Text) => Bool {
    hold len_a = name_end - name_start
    hold len_t = target.byteLength
    when len_a != len_t { give false }
    when len_a <= 0 { give true }
    when name_start < 0 || name_end > source.byteLength { give false }
    when source@byteAt(name_start) != target@byteAt(0) { give false }

    each i among 1..len_a {
        when source@byteAt(name_start + i) != target@byteAt(i) {
            give false
        }
    }
    give true
}

expose flow symbolName(source: view Text, sym: view Symbol) => Text {
    give "<symbol>"
}

expose flow symbolKindName(kind: SymbolKind) => Text {
    choose kind {
        SymbolKind.Var : { give "Var" }
        SymbolKind.Param : { give "Param" }
        SymbolKind.Func : { give "Func" }
        SymbolKind.Struct : { give "Struct" }
        SymbolKind.Enum : { give "Enum" }
        SymbolKind.Variant : { give "Variant" }
        SymbolKind.Field : { give "Field" }
        SymbolKind.Const : { give "Const" }
    }
}
