use project_l::check;

#[test]
fn migrated_text_build_benchmark_uses_canonical_v2_syntax() {
    check(include_str!("../../../bench/programs/text_build.l")).unwrap();
}
