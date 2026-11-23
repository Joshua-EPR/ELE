expose choice AstExprKind {
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

expose shape AstExpr {
    kind: AstExprKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
    d: Int
}

expose choice AstStmtKind {
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

expose shape AstStmt {
    kind: AstStmtKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
    d: Int
    e: Int
}

expose choice AstTypeKind {
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

expose shape AstType {
    kind: AstTypeKind
    start: Int
    end: Int
    a: Int
    b: Int
    c: Int
}

expose choice AstDeclKind {
    Function
    Struct
    Enum
    Import
    Const
}

expose shape AstDecl {
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

expose shape AstParam {
    name_start: Int
    name_end: Int
    type_id: Int
    start: Int
    end: Int
}

expose shape AstField {
    name_start: Int
    name_end: Int
    is_public: Bool
    type_id: Int
    default_expr_id: Int
    start: Int
    end: Int
}

expose shape AstVariant {
    name_start: Int
    name_end: Int
    first_payload_index: Int
    payload_count: Int
    start: Int
    end: Int
}

expose choice ParseProblem {
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

expose shape ParseError {
    problem: ParseProblem
    expected_token: Text
    token_start: Int
    token_end: Int
}

expose shape AstTree {
    expressions: List of[AstExpr]
    statements: List of[AstStmt]
    declarations: List of[AstDecl]
    types: List of[AstType]
    params: List of[AstParam]
    fields: List of[AstField]
    variants: List of[AstVariant]
    extra: List of[Int]
    errors: List of[ParseError]
}

expose flow astAppendExtras(tree: edit AstTree, children: view List of[Int], prefixed: Bool) => Int {
    hold first = tree.extra.length
    when prefixed { tree.extra@push(children.length) }
    each child among children { tree.extra@push(child) }
    give first
}

expose flow astNew() => AstTree {
    hold exprs: List of[AstExpr] = List[]
    hold stmts: List of[AstStmt] = List[]
    hold decls: List of[AstDecl] = List[]
    hold types: List of[AstType] = List[]
    hold params: List of[AstParam] = List[]
    hold fields: List of[AstField] = List[]
    hold variants: List of[AstVariant] = List[]
    hold extra: List of[Int] = List[]
    hold errors: List of[ParseError] = List[]
    give AstTree(
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

expose flow astAddExpr(tree: edit AstTree, kind: AstExprKind, start: Int, end: Int, a: Int, b: Int, c: Int, d: Int) => Int {
    hold id = tree.expressions.length
    tree.expressions@push(AstExpr(kind: kind, start: start, end: end, a: a, b: b, c: c, d: d))
    give id
}

expose flow astAddStmt(tree: edit AstTree, kind: AstStmtKind, start: Int, end: Int, a: Int, b: Int, c: Int, d: Int, e: Int) => Int {
    hold id = tree.statements.length
    tree.statements@push(AstStmt(kind: kind, start: start, end: end, a: a, b: b, c: c, d: d, e: e))
    give id
}

expose flow astAddType(tree: edit AstTree, kind: AstTypeKind, start: Int, end: Int, a: Int, b: Int, c: Int) => Int {
    hold id = tree.types.length
    tree.types@push(AstType(kind: kind, start: start, end: end, a: a, b: b, c: c))
    give id
}

expose flow astAddDecl(tree: edit AstTree, kind: AstDeclKind, start: Int, end: Int, is_public: Bool, a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) => Int {
    hold id = tree.declarations.length
    tree.declarations@push(AstDecl(kind: kind, start: start, end: end, is_public: is_public, a: a, b: b, c: c, d: d, e: e, f: f, g: g))
    give id
}

expose flow astAddParam(tree: edit AstTree, name_start: Int, name_end: Int, type_id: Int, start: Int, end: Int) => Int {
    hold id = tree.params.length
    tree.params@push(AstParam(name_start: name_start, name_end: name_end, type_id: type_id, start: start, end: end))
    give id
}

expose flow astAddField(tree: edit AstTree, name_start: Int, name_end: Int, is_public: Bool, type_id: Int, default_expr_id: Int, start: Int, end: Int) => Int {
    hold id = tree.fields.length
    tree.fields@push(AstField(name_start: name_start, name_end: name_end, is_public: is_public, type_id: type_id, default_expr_id: default_expr_id, start: start, end: end))
    give id
}

expose flow astAddVariant(tree: edit AstTree, name_start: Int, name_end: Int, first_payload_index: Int, payload_count: Int, start: Int, end: Int) => Int {
    hold id = tree.variants.length
    tree.variants@push(AstVariant(name_start: name_start, name_end: name_end, first_payload_index: first_payload_index, payload_count: payload_count, start: start, end: end))
    give id
}

expose flow astAddExtra(tree: edit AstTree, val: Int) => Int {
    hold id = tree.extra.length
    tree.extra@push(val)
    give id
}

expose flow astAddError(tree: edit AstTree, problem: ParseProblem, expected_token: Text, token_start: Int, token_end: Int) {
    tree.errors@push(ParseError(problem: problem, expected_token: expected_token, token_start: token_start, token_end: token_end))
}

expose flow astExprEnd(tree: view AstTree, id: Int, fallback: Int) => Int {
    when id >= 0 && id < tree.expressions.length {
        give tree.expressions[id].end
    }
    give fallback
}

expose flow astStmtEnd(tree: view AstTree, id: Int, fallback: Int) => Int {
    when id >= 0 && id < tree.statements.length {
        give tree.statements[id].end
    }
    give fallback
}

expose flow astTypeEnd(tree: view AstTree, id: Int, fallback: Int) => Int {
    when id >= 0 && id < tree.types.length {
        give tree.types[id].end
    }
    give fallback
}

flow astExprKindName(kind: AstExprKind) => Text {
    choose kind {
        AstExprKind.IntLit : { give "IntLit" }
        AstExprKind.BoolLit : { give "BoolLit" }
        AstExprKind.TextLit : { give "TextLit" }
        AstExprKind.Interpolate : { give "Interpolate" }
        AstExprKind.Name : { give "Name" }
        AstExprKind.UnitLit : { give "UnitLit" }
        AstExprKind.Call : { give "Call" }
        AstExprKind.GenericCall : { give "GenericCall" }
        AstExprKind.MethodCall : { give "MethodCall" }
        AstExprKind.GenericMethodCall : { give "GenericMethodCall" }
        AstExprKind.Field : { give "Field" }
        AstExprKind.Index : { give "Index" }
        AstExprKind.Try : { give "Try" }
        AstExprKind.Await : { give "Await" }
        AstExprKind.Spawn : { give "Spawn" }
        AstExprKind.Unary : { give "Unary" }
        AstExprKind.Binary : { give "Binary" }
        AstExprKind.ArrayLit : { give "ArrayLit" }
        AstExprKind.ListLit : { give "ListLit" }
        AstExprKind.Match : { give "Match" }
        AstExprKind.Named : { give "Named" }
    }
}

flow astStmtKindName(kind: AstStmtKind) => Text {
    choose kind {
        AstStmtKind.Let : { give "Let" }
        AstStmtKind.Const : { give "Const" }
        AstStmtKind.Assign : { give "Assign" }
        AstStmtKind.Expr : { give "Expr" }
        AstStmtKind.Return : { give "Return" }
        AstStmtKind.If : { give "If" }
        AstStmtKind.While : { give "While" }
        AstStmtKind.For : { give "For" }
        AstStmtKind.ForEach : { give "ForEach" }
        AstStmtKind.Loop : { give "Loop" }
        AstStmtKind.Break : { give "Break" }
        AstStmtKind.Continue : { give "Continue" }
        AstStmtKind.Block : { give "Block" }
        AstStmtKind.Region : { give "Region" }
    }
}

flow astTypeKindName(kind: AstTypeKind) => Text {
    choose kind {
        AstTypeKind.Int : { give "Int" }
        AstTypeKind.Float : { give "Float" }
        AstTypeKind.F32 : { give "F32" }
        AstTypeKind.Bool : { give "Bool" }
        AstTypeKind.Text : { give "Text" }
        AstTypeKind.Unit : { give "Unit" }
        AstTypeKind.Named : { give "Named" }
        AstTypeKind.Ref : { give "Ref" }
        AstTypeKind.Array : { give "Array" }
        AstTypeKind.Slice : { give "Slice" }
    }
}

flow astDeclKindName(kind: AstDeclKind) => Text {
    choose kind {
        AstDeclKind.Function : { give "Function" }
        AstDeclKind.Struct : { give "Struct" }
        AstDeclKind.Enum : { give "Enum" }
        AstDeclKind.Import : { give "Import" }
        AstDeclKind.Const : { give "Const" }
    }
}

flow astProblemName(problem: ParseProblem) => Text {
    choose problem {
        ParseProblem.ExpectedExpression : { give "se esperaba expresión" }
        ParseProblem.ExpectedIdentifier : { give "se esperaba identificador" }
        ParseProblem.ExpectedType : { give "se esperaba tipo" }
        ParseProblem.ExpectedStatement : { give "se esperaba sentencia" }
        ParseProblem.ExpectedDeclaration : { give "se esperaba declaración" }
        ParseProblem.ExpectedToken : { give "se esperaba token" }
        ParseProblem.UnclosedBlock : { give "bloque sin cerrar" }
        ParseProblem.UnclosedParenthesis : { give "paréntesis sin cerrar" }
        ParseProblem.UnclosedBracket : { give "corchete sin cerrar" }
        ParseProblem.UnclosedInterpolation : { give "expresión interpolada sin cerrar" }
        ParseProblem.ChainedComparisonsProhibited : { give "comparaciones encadenadas prohibidas" }
        ParseProblem.NestingLimitExceeded : { give "límite de anidamiento (128) excedido" }
        ParseProblem.UnexpectedToken : { give "token inesperado" }
    }
}

flow astDumpSummary(tree: view AstTree) {
    hold d = tree.declarations.length
    hold s = tree.statements.length
    hold e = tree.expressions.length
    hold t = tree.types.length
    hold err = tree.errors.length
    print("AstSummary decls={d} stmts={s} exprs={e} types={t} errors={err}")
}

expose flow astDumpCanonical(tree: view AstTree) {
    each i among 0..tree.declarations.length {
        hold decl = view tree.declarations[i]
        change name = "Unknown"
        choose decl.kind {
            AstDeclKind.Function : { name = "Function" }
            AstDeclKind.Struct : { name = "Struct" }
            AstDeclKind.Enum : { name = "Enum" }
            AstDeclKind.Import : { name = "Import" }
            AstDeclKind.Const : { name = "Const" }
        }
        hold s = decl.start
        hold e = decl.end
        hold pubFlag = decl.is_public
        hold a = decl.a
        hold b = decl.b
        hold c = decl.c
        hold d = decl.d
        hold extra_e = decl.e
        hold extra_f = decl.f
        hold extra_g = decl.g
        print("Decl::{name} span={s}..{e} pub={pubFlag} a={a} b={b} c={c} d={d} e={extra_e} f={extra_f} g={extra_g}")
    }
    astDumpSummary(tree)
}
