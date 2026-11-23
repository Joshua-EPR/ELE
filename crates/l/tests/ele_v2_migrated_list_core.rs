use project_l::check;

#[test]
fn migrated_list_core_benchmarks_use_canonical_v2_syntax() {
    check(include_str!("../../../bench/programs/list_push_1m.l")).unwrap();
    check(include_str!("../../../bench/programs/list_index_1m.l")).unwrap();
}
