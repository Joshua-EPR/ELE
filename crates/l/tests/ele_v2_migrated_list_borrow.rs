use project_l::check;

#[test]
fn migrated_list_borrow_benchmarks_use_canonical_v2_syntax() {
    check(include_str!("../../../bench/programs/list_iter_1m.l")).unwrap();
    check(include_str!("../../../bench/programs/list_search_1m.l")).unwrap();
}
