import sema_types

enum SymbolKind {
    Var
    Param
    Func
    Struct
    Enum
    Variant
    Field
    Const
}

struct Symbol {
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

struct SymbolTable {
    symbols: List<Symbol>
}

fn symbolTableNew() -> SymbolTable {
    let list: List<Symbol> = List[]
    return SymbolTable(symbols: list)
}

fn symbolAdd(table: &mut SymbolTable, kind: SymbolKind, name_start: Int, name_end: Int, type_id: Int, scope_id: Int, is_mut: Bool, is_pub: Bool, decl_id: Int, start: Int, end: Int) -> Int {
    let id = table.symbols.length
    table.symbols.push(Symbol(
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
    return id
}

fn symbolSetModule(table: &mut SymbolTable, sym_id: Int, module_id: Int) {
    if sym_id < 0 || sym_id >= table.symbols.length { return }
    table.symbols[sym_id].module_id = module_id
}

// A symbol is visible from `module_id` when it is a local (module -1), from
// the same module, or public. Cross-module access only happens through public
// symbols, which is the visibility rule enforced by the module system.
fn symbolVisible(sym: &Symbol, module_id: Int, allowed: &List<Int>, module_count: Int) -> Bool {
    if sym.module_id < 0 { return true }
    if sym.module_id == module_id { return true }
    if !sym.is_pub { return false }
    // Without a module loader, preserve existing isolated Stage 1 tests.
    if module_count == 0 { return true }
    if module_id < 0 || module_id >= module_count { return false }
    if sym.module_id >= module_count { return false }
    let pos = module_id * module_count + sym.module_id
    if pos < 0 || pos >= allowed.length { return false }
    return allowed[pos] == 1
}

fn symbolNamesEqual(source: &Text, a_start: Int, a_end: Int, b_start: Int, b_end: Int) -> Bool {
    let len_a = a_end - a_start
    let len_b = b_end - b_start
    if len_a != len_b { return false }
    if len_a <= 0 { return true }
    if a_start < 0 || a_end > source.byteLength { return false }
    if b_start < 0 || b_end > source.byteLength { return false }

    for i in 0..len_a {
        if source.byteAt(a_start + i) != source.byteAt(b_start + i) {
            return false
        }
    }
    return true
}

fn symbolNameEqualsText(source: &Text, name_start: Int, name_end: Int, target: &Text) -> Bool {
    let len_a = name_end - name_start
    let len_t = target.byteLength
    if len_a != len_t { return false }
    if len_a <= 0 { return true }
    if name_start < 0 || name_end > source.byteLength { return false }

    for i in 0..len_a {
        if source.byteAt(name_start + i) != target.byteAt(i) {
            return false
        }
    }
    return true
}

fn symbolName(source: &Text, sym: &Symbol) -> Text {
    return "<symbol>"
}

fn symbolKindName(kind: SymbolKind) -> Text {
    match kind {
        SymbolKind.Var => { return "Var" }
        SymbolKind.Param => { return "Param" }
        SymbolKind.Func => { return "Func" }
        SymbolKind.Struct => { return "Struct" }
        SymbolKind.Enum => { return "Enum" }
        SymbolKind.Variant => { return "Variant" }
        SymbolKind.Field => { return "Field" }
        SymbolKind.Const => { return "Const" }
    }
}
