//! Compatibility tests for the shared primitive-payload LIR extension.
//! A parsed payload operation must remain typed and retain a projection;
//! it may not silently become an unchecked integer load.
use project_l::{
    cfg::{InstKind, Proj, Rvalue},
    lir_protocol,
};
use std::{fs, path::PathBuf};

fn fixture(name: &str) -> String {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    // Git on Windows may check out CRLF fixtures; line-based edits below
    // assume LF so that every `replacen` really changes the fixture.
    fs::read_to_string(root.join("examples").join(name))
        .unwrap()
        .replace("\r\n", "\n")
}

/// Line (1-based) of `needle` in `text`: rejections must point at the edit.
fn line_of(text: &str, needle: &str) -> usize {
    1 + text
        .lines()
        .position(|l| l.starts_with(needle))
        .unwrap_or_else(|| panic!("no line starts with {needle:?}"))
}

/// A negative case must fail for its own reason: on the expected line and
/// with the expected diagnostic, not merely with *some* error.
fn assert_rejects(what: &str, text: &str, line: usize, message: &str) {
    let err = lir_protocol::parse(text)
        .err()
        .unwrap_or_else(|| panic!("{what}: accepted"));
    assert_eq!(err.line, line, "{what}: wrong line: {err:?}");
    assert!(
        err.message.contains(message),
        "{what}: expected {message:?}, got {err:?}"
    );
}

fn edit(base: &str, from: &str, to: &str) -> String {
    assert!(base.contains(from), "fixture lacks {from:?}");
    let out = base.replacen(from, to, 1);
    assert_ne!(out, base);
    out
}

#[test]
fn parses_checked_primitive_payloads_with_nominal_projection() {
    for (name, variant) in [
        ("native_cfg_enum_payload_int.lir", 1),
        ("native_cfg_enum_payload_bool.lir", 1),
        ("native_cfg_enum_payload_wrong_active.lir", 1),
    ] {
        let module = lir_protocol::parse(&fixture(name)).unwrap();
        let insts = &module.funcs[module.main].blocks[0].insts;
        assert!(
            insts.iter().any(|i| matches!(
                &i.kind,
                InstKind::Assign(_, Rvalue::Read(place))
                    if place.proj == [Proj::Payload(variant, 0)]
            )),
            "{name}"
        );
        // A variant mismatch is a runtime check, not a parse rejection.
    }
}

#[test]
fn rejects_payload_on_wrong_type_or_variant() {
    for (name, message) in [
        // `e1` does not exist: the module declares a single enum.
        (
            "native_cfg_enum_payload_wrong_enum.lir",
            "identificador inválido: 'e1'",
        ),
        // Variant 2 of a two-variant enum.
        (
            "native_cfg_enum_payload_wrong_variant.lir",
            "cantidad inválida o excesiva: '2'",
        ),
        // Variant 0 (`None`) has no payload field.
        (
            "native_cfg_enum_payload_unit_variant.lir",
            "payload requiere un único campo representable del tipo exacto",
        ),
        // The payload is Int; the destination is Bool.
        (
            "native_cfg_enum_payload_type_mismatch.lir",
            "payload requiere un único campo representable del tipo exacto",
        ),
    ] {
        let text = fixture(name);
        assert_rejects(name, &text, line_of(&text, "i payload "), message);
    }
}

#[test]
fn rejects_payload_with_struct_field_projection() {
    let base = fixture("native_cfg_enum_payload_int.lir");
    let bad = edit(&base, "payload v1 p0 e0 1", "payload v1 p0.0 e0 1");
    // An enum root has no fields, so the generic place parser rejects the
    // projection before the payload-specific guard runs. That guard
    // (enum reached through a struct field) is NOT exercised here.
    assert_rejects(
        "projected payload",
        &bad,
        line_of(&bad, "i payload "),
        "proyección inválida en 'p0.0'",
    );
}

#[test]
fn empty_enum_cannot_be_projected_or_panic_in_protocol_parser() {
    // Git on Windows may check out CRLF fixtures. Normalize before editing:
    // otherwise the replacements are no-ops and the test checks a valid enum.
    let good = fixture("native_cfg_enum_payload_int.lir");
    let empty = good
        .replacen("variants 2\n", "variants 0\n", 1)
        .replace("variant 4:78,111,110,101 types 0\n", "")
        .replace("variant 4:83,111,109,101 types 1 i\n", "");
    assert_ne!(empty, good, "el fixture de enum vacío no se modificó");
    assert!(empty.contains("variants 0\n"));
    assert_rejects(
        "empty enum",
        &empty,
        line_of(&empty, "enum e0 "),
        "un enum debe declarar al menos una variante",
    );
}

#[test]
fn rejects_payload_on_reference_root_even_if_nominal_type_matches() {
    // A reference root and a value root serialize to the same `p0` text.
    // The ELE-written backend does not support reference locals: Rust must
    // not silently accept and dereference one in the shared extension.
    // The constructor writes the root first, so build the enum in a value
    // local (v3) and only borrow-type the root that `payload` reads (v0):
    // otherwise the `variant` line, not `payload`, would be what fails.
    let base = fixture("native_cfg_enum_payload_int.lir");
    let bad = edit(&base, "var v0 val e0", "var v0 ref e0");
    let bad = edit(&bad, "i variant v0 e0 1 1 ci42", "i variant v3 e0 1 1 ci42");
    assert_rejects(
        "payload through ref root",
        &bad,
        line_of(&bad, "i payload "),
        "payload requiere un enum directo por valor del tipo indicado",
    );
}

#[test]
fn rejects_variant_constructor_with_mismatched_payload_arity() {
    let base = fixture("native_cfg_enum_payload_int.lir");
    let at = line_of(&base, "i variant v0 e0 1 1 ci42");
    let missing = edit(&base, "i variant v0 e0 1 1 ci42", "i variant v0 e0 1 0");
    assert_rejects(
        "missing payload",
        &missing,
        at,
        "aridad de payload incompatible con la variante",
    );
    let excess = edit(
        &base,
        "i variant v0 e0 1 1 ci42",
        "i variant v0 e0 0 1 ci42",
    );
    assert_rejects(
        "payload on unit variant",
        &excess,
        at,
        "aridad de payload incompatible con la variante",
    );
}

#[test]
fn discriminant_requires_direct_enum_value_and_integer_destination() {
    let source = fixture("native_cfg_enum_unit.lir");
    assert!(lir_protocol::parse(&source).is_ok());
    let at = line_of(&source, "i disc v2 p1");
    const DISC: &str = "disc requiere un enum directo y un destino Int";

    // All consumers of ELE-LIR must reject projecting a discriminant from a
    // field or borrowing a root until the native backend supports those modes.
    // As for `payload`, an enum root has no fields: the place parser rejects
    // this before the `disc`-specific projection guard is reached.
    let projected = edit(&source, "i disc v2 p1", "i disc v2 p1.0");
    assert_rejects(
        "projected disc",
        &projected,
        at,
        "proyección inválida en 'p1.0'",
    );

    let borrowed = edit(&source, "var v1 val e0", "var v1 ref e0");
    assert_rejects("disc through ref root", &borrowed, at, DISC);

    // A discriminant is Int, never the enum value itself.
    let wrong_destination = edit(&source, "i disc v2 p1", "i disc v0 p1");
    assert_rejects("disc into enum", &wrong_destination, at, DISC);
}
