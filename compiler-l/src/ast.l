pub enum AstExprKind {
    IntLit
    BoolLit
    TextLit
    Interpolate
    Name
    UnitLit
    Call
    GenericCall
    MethodCall
    GenericMethodCall
    Field
    Index
    Try
    Await
    Spawn
    Unary
    Binary
    ArrayLit
    ListLit
    Match
    Named
}

pub struct AstExpr {
    kind: AstExprKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
    d: Int
}

pub enum AstStmtKind {
    Let
    Const
    Assign
    Expr
    Return
    If
    While
    For
    ForEach
    Loop
    Break
    Continue
    Block
    Region
}

pub struct AstStmt {
    kind: AstStmtKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
    d: Int
    e: Int
}

pub enum AstTypeKind {
    Int
    Float
    F32
    Bool
    Text
    Unit
    Named
    Ref
    Array
    Slice
}

pub struct AstType {
    kind: AstTypeKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
}

pub enum AstDeclKind {
    Function
    Struct
    Enum
    Import
    Const
}

pub struct AstDecl {
    kind: AstDeclKind
    start: Int
    end: Int
    is_public: Bool
    a: Int
    b: Int
    c: Int
    d: Int
    e: Int
    f: Int
    g: Int
}

pub struct AstParam {
    name_start: Int
    name_end: Int
    type_id: Int
    start: Int
    end: Int
}

pub struct AstField {
    name_start: Int
    name_end: Int
    is_public: Bool
    type_id: Int
    default_expr_id: Int
    start: Int
    end: Int
}

pub struct AstVariant {
    name_start: Int
    name_end: Int
    first_payload_index: Int
    payload_count: Int
    start: Int
    end: Int
}

pub enum ParseProblem {
    ExpectedExpression
    ExpectedIdentifier
    ExpectedType
    ExpectedStatement
    ExpectedDeclaration
    ExpectedToken
    UnclosedBlock
    UnclosedParenthesis
    UnclosedBracket
    UnclosedInterpolation
    ChainedComparisonsProhibited
    NestingLimitExceeded
    UnexpectedToken
}

pub struct ParseError {
    problem: ParseProblem
    expected_token: Text
    token_start: Int
    token_end: Int
}

pub struct AstTree {
    expressions: List<AstExpr>
    statements: List<AstStmt>
    declarations: List<AstDecl>
    types: List<AstType>
    params: List<AstParam>
    fields: List<AstField>
    variants: List<AstVariant>
    extra: List<Int>
    errors: List<ParseError>
}

fn astAppendExtras(tree: &mut AstTree, children: &List<Int>, prefixed: Bool) -> Int {
    let first = tree.extra.length
    if prefixed { tree.extra.push(children.length) }
    for child in children { tree.extra.push(child) }
    return first
}

fn astNew() -> AstTree {
    let exprs: List<AstExpr> = List[]
    let stmts: List<AstStmt> = List[]
    let decls: List<AstDecl> = List[]
    let types: List<AstType> = List[]
    let params: List<AstParam> = List[]
    let fields: List<AstField> = List[]
    let variants: List<AstVariant> = List[]
    let extra: List<Int> = List[]
    let errors: List<ParseError> = List[]
    return AstTree(
        expressions: exprs,
        statements: stmts,
        declarations: decls,
        types: types,
        params: params,
        fields: fields,
        variants: variants,
        extra: extra,
        errors: errors,
    )
}

fn astAddExpr(tree: &mut AstTree, kind: AstExprKind, start: Int, end: Int, a: Int, b: Int, c: Int, d: Int) -> Int {
    let id = tree.expressions.length
    tree.expressions.push(AstExpr(kind: kind, start: start, end: end, a: a, b: b, c: c, d: d))
    return id
}

fn astAddStmt(tree: &mut AstTree, kind: AstStmtKind, start: Int, end: Int, a: Int, b: Int, c: Int, d: Int, e: Int) -> Int {
    let id = tree.statements.length
    tree.statements.push(AstStmt(kind: kind, start: start, end: end, a: a, b: b, c: c, d: d, e: e))
    return id
}

fn astAddType(tree: &mut AstTree, kind: AstTypeKind, start: Int, end: Int, a: Int, b: Int, c: Int) -> Int {
    let id = tree.types.length
    tree.types.push(AstType(kind: kind, start: start, end: end, a: a, b: b, c: c))
    return id
}

fn astAddDecl(tree: &mut AstTree, kind: AstDeclKind, start: Int, end: Int, is_public: Bool, a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> Int {
    let id = tree.declarations.length
    tree.declarations.push(AstDecl(kind: kind, start: start, end: end, is_public: is_public, a: a, b: b, c: c, d: d, e: e, f: f, g: g))
    return id
}

fn astAddParam(tree: &mut AstTree, name_start: Int, name_end: Int, type_id: Int, start: Int, end: Int) -> Int {
    let id = tree.params.length
    tree.params.push(AstParam(name_start: name_start, name_end: name_end, type_id: type_id, start: start, end: end))
    return id
}

fn astAddField(tree: &mut AstTree, name_start: Int, name_end: Int, is_public: Bool, type_id: Int, default_expr_id: Int, start: Int, end: Int) -> Int {
    let id = tree.fields.length
    tree.fields.push(AstField(name_start: name_start, name_end: name_end, is_public: is_public, type_id: type_id, default_expr_id: default_expr_id, start: start, end: end))
    return id
}

fn astAddVariant(tree: &mut AstTree, name_start: Int, name_end: Int, first_payload_index: Int, payload_count: Int, start: Int, end: Int) -> Int {
    let id = tree.variants.length
    tree.variants.push(AstVariant(name_start: name_start, name_end: name_end, first_payload_index: first_payload_index, payload_count: payload_count, start: start, end: end))
    return id
}

fn astAddExtra(tree: &mut AstTree, val: Int) -> Int {
    let id = tree.extra.length
    tree.extra.push(val)
    return id
}

fn astAddError(tree: &mut AstTree, problem: ParseProblem, expected_token: Text, token_start: Int, token_end: Int) {
    tree.errors.push(ParseError(problem: problem, expected_token: expected_token, token_start: token_start, token_end: token_end))
}

fn astExprEnd(tree: &AstTree, id: Int, fallback: Int) -> Int {
    if id >= 0 && id < tree.expressions.length {
        return tree.expressions[id].end
    }
    return fallback
}

fn astStmtEnd(tree: &AstTree, id: Int, fallback: Int) -> Int {
    if id >= 0 && id < tree.statements.length {
        return tree.statements[id].end
    }
    return fallback
}

fn astTypeEnd(tree: &AstTree, id: Int, fallback: Int) -> Int {
    if id >= 0 && id < tree.types.length {
        return tree.types[id].end
    }
    return fallback
}

fn astExprKindName(kind: AstExprKind) -> Text {
    match kind {
        AstExprKind.IntLit => { return "IntLit" }
        AstExprKind.BoolLit => { return "BoolLit" }
        AstExprKind.TextLit => { return "TextLit" }
        AstExprKind.Interpolate => { return "Interpolate" }
        AstExprKind.Name => { return "Name" }
        AstExprKind.UnitLit => { return "UnitLit" }
        AstExprKind.Call => { return "Call" }
        AstExprKind.GenericCall => { return "GenericCall" }
        AstExprKind.MethodCall => { return "MethodCall" }
        AstExprKind.GenericMethodCall => { return "GenericMethodCall" }
        AstExprKind.Field => { return "Field" }
        AstExprKind.Index => { return "Index" }
        AstExprKind.Try => { return "Try" }
        AstExprKind.Await => { return "Await" }
        AstExprKind.Spawn => { return "Spawn" }
        AstExprKind.Unary => { return "Unary" }
        AstExprKind.Binary => { return "Binary" }
        AstExprKind.ArrayLit => { return "ArrayLit" }
        AstExprKind.ListLit => { return "ListLit" }
        AstExprKind.Match => { return "Match" }
        AstExprKind.Named => { return "Named" }
    }
}

fn astStmtKindName(kind: AstStmtKind) -> Text {
    match kind {
        AstStmtKind.Let => { return "Let" }
        AstStmtKind.Const => { return "Const" }
        AstStmtKind.Assign => { return "Assign" }
        AstStmtKind.Expr => { return "Expr" }
        AstStmtKind.Return => { return "Return" }
        AstStmtKind.If => { return "If" }
        AstStmtKind.While => { return "While" }
        AstStmtKind.For => { return "For" }
        AstStmtKind.ForEach => { return "ForEach" }
        AstStmtKind.Loop => { return "Loop" }
        AstStmtKind.Break => { return "Break" }
        AstStmtKind.Continue => { return "Continue" }
        AstStmtKind.Block => { return "Block" }
        AstStmtKind.Region => { return "Region" }
    }
}

fn astTypeKindName(kind: AstTypeKind) -> Text {
    match kind {
        AstTypeKind.Int => { return "Int" }
        AstTypeKind.Float => { return "Float" }
        AstTypeKind.F32 => { return "F32" }
        AstTypeKind.Bool => { return "Bool" }
        AstTypeKind.Text => { return "Text" }
        AstTypeKind.Unit => { return "Unit" }
        AstTypeKind.Named => { return "Named" }
        AstTypeKind.Ref => { return "Ref" }
        AstTypeKind.Array => { return "Array" }
        AstTypeKind.Slice => { return "Slice" }
    }
}

fn astDeclKindName(kind: AstDeclKind) -> Text {
    match kind {
        AstDeclKind.Function => { return "Function" }
        AstDeclKind.Struct => { return "Struct" }
        AstDeclKind.Enum => { return "Enum" }
        AstDeclKind.Import => { return "Import" }
        AstDeclKind.Const => { return "Const" }
    }
}

fn astProblemName(problem: ParseProblem) -> Text {
    match problem {
        ParseProblem.ExpectedExpression => { return "se esperaba expresión" }
        ParseProblem.ExpectedIdentifier => { return "se esperaba identificador" }
        ParseProblem.ExpectedType => { return "se esperaba tipo" }
        ParseProblem.ExpectedStatement => { return "se esperaba sentencia" }
        ParseProblem.ExpectedDeclaration => { return "se esperaba declaración" }
        ParseProblem.ExpectedToken => { return "se esperaba token" }
        ParseProblem.UnclosedBlock => { return "bloque sin cerrar" }
        ParseProblem.UnclosedParenthesis => { return "paréntesis sin cerrar" }
        ParseProblem.UnclosedBracket => { return "corchete sin cerrar" }
        ParseProblem.UnclosedInterpolation => { return "expresión interpolada sin cerrar" }
        ParseProblem.ChainedComparisonsProhibited => { return "comparaciones encadenadas prohibidas" }
        ParseProblem.NestingLimitExceeded => { return "límite de anidamiento (128) excedido" }
        ParseProblem.UnexpectedToken => { return "token inesperado" }
    }
}

fn astDumpSummary(tree: &AstTree) {
    let d = tree.declarations.length
    let s = tree.statements.length
    let e = tree.expressions.length
    let t = tree.types.length
    let err = tree.errors.length
    print("AstSummary decls={d} stmts={s} exprs={e} types={t} errors={err}")
}

fn astDumpCanonical(tree: &AstTree) {
    for i in 0..tree.declarations.length {
        let decl = &tree.declarations[i]
        var name = "Unknown"
        match decl.kind {
            AstDeclKind.Function => { name = "Function" }
            AstDeclKind.Struct => { name = "Struct" }
            AstDeclKind.Enum => { name = "Enum" }
            AstDeclKind.Import => { name = "Import" }
            AstDeclKind.Const => { name = "Const" }
        }
        let s = decl.start
        let e = decl.end
        let pubFlag = decl.is_public
        let a = decl.a
        let b = decl.b
        let c = decl.c
        let d = decl.d
        let extra_e = decl.e
        let extra_f = decl.f
        let extra_g = decl.g
        print("Decl::{name} span={s}..{e} pub={pubFlag} a={a} b={b} c={c} d={d} e={extra_e} f={extra_f} g={extra_g}")
    }
    astDumpSummary(tree)
}
