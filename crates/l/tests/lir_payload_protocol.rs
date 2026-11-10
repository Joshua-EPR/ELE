//! Compatibility tests for the shared primitive-payload LIR extension.
//! A parsed payload operation must remain typed and retain a projection;
//! it may not silently become an unchecked integer load.
use project_l::{cfg::{InstKind, Proj, Rvalue}, lir_protocol};
use std::{fs, path::PathBuf};

fn fixture(name: &str) -> String {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..");
    fs::read_to_string(root.join("examples").join(name)).unwrap()
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
        assert!(insts.iter().any(|i| matches!(
            &i.kind,
            InstKind::Assign(_, Rvalue::Read(place))
                if place.proj == [Proj::Payload(variant, 0)]
        )), "{name}");
        // A variant mismatch is a runtime check, not a parse rejection.
    }
}

#[test]
fn rejects_payload_on_wrong_type_or_variant() {
    for name in [
        "native_cfg_enum_payload_wrong_enum.lir",
        "native_cfg_enum_payload_wrong_variant.lir",
        "native_cfg_enum_payload_unit_variant.lir",
        "native_cfg_enum_payload_type_mismatch.lir",
    ] {
        assert!(lir_protocol::parse(&fixture(name)).is_err(), "{name}");
    }
}

#[test]
fn rejects_payload_with_struct_field_projection() {
    let base = fixture("native_cfg_enum_payload_int.lir");
    assert!(base.contains("payload v1 p0 e0 1"));
    let bad = base.replacen("payload v1 p0 e0 1", "payload v1 p0.0 e0 1", 1);
    assert!(lir_protocol::parse(&bad).is_err());
}

#[test]
fn empty_enum_cannot_be_projected_or_panic_in_protocol_parser() {
    let good = fixture("native_cfg_enum_payload_int.lir");
    let empty = good
        .replacen("variants 2\n", "variants 0\n", 1)
        .replace("variant 4:78,111,110,101 types 0\n", "")
        .replace("variant 4:83,111,109,101 types 1 i\n", "");
    assert!(lir_protocol::parse(&empty).is_err());
}

#[test]
fn rejects_payload_on_reference_root_even_if_nominal_type_matches() {
    // A reference root and a value root serialize to the same `p0` text.
    // The ELE-written backend does not support reference locals: Rust must
    // not silently accept and dereference one in the shared extension.
    let base = fixture("native_cfg_enum_payload_int.lir");
    assert!(base.contains("var v0 val e0"));
    let bad = base.replacen("var v0 val e0", "var v0 ref e0", 1);
    assert!(lir_protocol::parse(&bad).is_err());
}

#[test]
fn rejects_variant_constructor_with_mismatched_payload_arity() {
    let base = fixture("native_cfg_enum_payload_int.lir");
    assert!(base.contains("i variant v0 e0 1 1 ci42"));
    let missing = base.replacen("i variant v0 e0 1 1 ci42", "i variant v0 e0 1 0", 1);
    assert!(lir_protocol::parse(&missing).is_err());
    let excess = base.replacen("i variant v0 e0 1 1 ci42", "i variant v0 e0 0 1 ci42", 1);
    assert!(lir_protocol::parse(&excess).is_err());
}
