//! Stage-0 bootstrap tests for native layout planning written in ELE.
//! No native heap, struct lowering, or Stage 2 is claimed by this fixture.
mod stage1_support;

use std::process::Command;

#[test]
fn ele_native_layout_aligns_nests_and_plans_drops() {
    let exe = stage1_support::build("native_layout_cases", false);
    let out = Command::new(exe).output().expect("run native-layout ELE fixture");
    assert!(
        out.status.success(),
        "stderr={} stdout={}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(
        String::from_utf8_lossy(&out.stdout).contains("ELE_LAYOUT_OK"),
        "expected successful ELE-produced layout checks"
    );
}
