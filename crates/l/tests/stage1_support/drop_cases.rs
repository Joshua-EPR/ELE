//! Drop-elaboration programs shared by `drops_l.rs` (path-by-path plans)
//! and `lir_l.rs` (compiled from Stage 1 LIR).

#[allow(dead_code)]
pub const PRELUDE: &str = "fn take(t: Text) -> Int = 1\nfn mk() -> Text = \"q\"\n";

/// Programs exercising every drop rule of the Stage 1 subset.
#[allow(dead_code)]
pub const DROP_CASES: &[(&str, &str)] = &[
    ("owned_local", "fn f() { let a = \"x\"\n print(a)\n}"),
    (
        "two_owned_reverse_order",
        "fn f() { let a = \"x\"\n let b = \"y\"\n let n = 3\n print(n)\n}",
    ),
    (
        "move_transfers_ownership",
        "fn f() { let a = \"x\"\n let b = a\n print(b)\n}",
    ),
    (
        "move_into_call",
        "fn f() { let a = \"x\"\n let b = \"y\"\n print(take(a))\n}",
    ),
    (
        "partial_move",
        "struct U { n: Text, c: Text, e: Int }\nfn f() { let u = U(n: \"a\", c: \"b\", e: 1)\n let n = u.n\n print(u.c)\n}",
    ),
    (
        "nested_partial_maybe",
        "struct I { a: Text, b: Text }\nstruct O { i: I, t: Text }\nfn f(k: Bool) { let o = O(i: I(a: \"1\", b: \"2\"), t: \"3\")\n if k { take(o.i.a); }\n}",
    ),
    (
        "reinit_after_move",
        "fn f() { var a = \"x\"\n take(a);\n a = \"y\"\n print(a)\n}",
    ),
    (
        "reassign_drops_old",
        "fn f() { var a = \"x\"\n a = \"y\"\n a = \"z\"\n print(a)\n}",
    ),
    (
        "reassign_maybe_moved",
        "fn f(c: Bool) { var b = \"y\"\n if c { take(b); }\n b = \"z\"\n let d = b\n}",
    ),
    (
        "reassign_field_and_whole",
        "struct U { n: Text, c: Text }\nfn f(k: Bool) { var u = U(n: \"a\", c: \"b\")\n u.c = \"z\"\n if k { take(u.n); }\n u = U(n: \"x\", c: \"y\")\n}",
    ),
    (
        "reinit_field_after_move",
        "struct U { n: Text, c: Text }\nfn f() { var u = U(n: \"a\", c: \"b\")\n take(u.n);\n u.n = \"r\"\n print(u.n)\n}",
    ),
    (
        "early_return",
        "fn f(c: Bool) -> Int { let a = \"x\"\n var b = \"y\"\n if c { return 2 }\n print(a)\n return 1\n}",
    ),
    (
        "if_else_moves",
        "fn f(c: Bool) { let a = \"x\"\n if c { take(a); } else { print(a) }\n let z = \"w\"\n}",
    ),
    (
        "move_both_branches",
        "fn f(c: Bool) { let a = \"x\"\n if c { take(a); } else { let b = a }\n}",
    ),
    (
        "while_per_iteration",
        "fn f(c: Bool) { var i = 0\n while i < 3 { let t = \"w\"\n i = i + 1\n }\n let after = \"z\"\n}",
    ),
    (
        "while_break_continue",
        "fn f(c: Bool) { var i = 0\n while i < 3 { let t = \"w\"\n if c { break }\n let s = \"v\"\n i = i + 1\n if c { continue }\n }\n}",
    ),
    (
        "for_loop_locals",
        "fn f() { for i in 0..3 { let t = \"w\"\n if i == 1 { continue }\n let u = \"v\" }\n}",
    ),
    (
        "loop_break_owned",
        "fn f(c: Bool) { let outer = \"o\"\n loop { let t = \"w\"\n if c { break }\n let u = \"v\" }\n}",
    ),
    (
        "nested_loops_return",
        "fn f(c: Bool) -> Int { let a = \"x\"\n var i = 0\n while i < 2 { let t = \"t\"\n var j = 0\n while j < 2 { let u = \"u\"\n if c { return 1 }\n j = j + 1 }\n i = i + 1 }\n return 0\n}",
    ),
    (
        "owned_params",
        "struct U { n: Text, c: Text }\nfn f(p: U, t: Text, n: Int) { print(t)\n}",
    ),
    (
        "param_moved",
        "fn f(t: Text, c: Bool) { if c { take(t); }\n}",
    ),
    (
        "return_owned_local",
        "fn f() -> Text { let a = \"x\"\n let b = \"y\"\n return a\n}",
    ),
    (
        "return_owned_field",
        "struct U { n: Text, c: Text }\nfn f() -> Text { let u = U(n: \"a\", c: \"b\")\n return u.c\n}",
    ),
    (
        "return_constructed",
        "struct U { n: Text, c: Text }\nfn f(t: Text) -> U { return U(n: t, c: \"b\")\n}",
    ),
    (
        "many_returns",
        "fn f(a: Bool, b: Bool) -> Int { let x = \"x\"\n if a { let y = \"y\"\n if b { return 1 }\n return 2 }\n let z = \"z\"\n if b { return 3 }\n return 4\n}",
    ),
    (
        "nested_scopes",
        "fn f() { let a = \"a\"\n { let b = \"b\"\n { let c = \"c\" }\n let d = \"d\" }\n let e = \"e\"\n}",
    ),
    (
        "shadowing",
        "fn f() { let a = \"a\"\n { let a = \"b\"\n print(a) }\n print(a)\n}",
    ),
    (
        "temporaries",
        "fn f() { mk();\n print(mk())\n print(\"lit\")\n let z = 3\n print(\"a{mk()}b{z}\")\n}",
    ),
    (
        "temporary_in_condition_call",
        "fn g(t: Text) -> Bool = true\nfn f() { if g(mk()) { print(1) }\n}",
    ),
    (
        "list_owned",
        "fn f() { let l = List[\"x\", \"y\"]\n let m = List[1, 2]\n let k = l\n}",
    ),
    (
        "enum_payload_param",
        "enum E { A(Text), B }\nfn f(e: E, g: E) { print(1)\n}",
    ),
    (
        "enum_plain_param",
        "enum K { A, B }\nfn f(k: K) { print(1)\n}",
    ),
    (
        "shared_borrow_owner_drop",
        "fn f() { let t = \"x\"\n let r = &t\n print(r)\n}",
    ),
    (
        "mutable_borrow_write_through",
        "fn f() { var t = \"a\"\n let r = &mut t\n r = \"b\"\n print(t)\n}",
    ),
    (
        "nll_then_move",
        "fn f() { let t = \"a\"\n let r = &t\n print(r)\n take(t);\n}",
    ),
    (
        "write_through_param",
        "struct U { n: Text, c: Text }\nfn g(u: &mut U) { u.n = \"w\"\n}\nfn h(t: &mut Text) { t = \"w\"\n}",
    ),
    (
        "borrowed_return_owner",
        "fn pick(n: &Text) -> &Text { return n }\nfn f() { let t = \"a\"\n let r = pick(&t)\n print(r)\n}",
    ),
    (
        "struct_param_partial_move",
        "struct U { n: Text, c: Text }\nfn f(u: U, c: Bool) { if c { take(u.c); }\n}",
    ),
    (
        "short_circuit",
        "fn g(t: Text) -> Bool = true\nfn f(a: Bool) { let t = \"x\"\n if a && g(mk()) { take(t); }\n}",
    ),
];
