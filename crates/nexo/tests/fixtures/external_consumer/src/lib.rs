//! Fixture para pruebas negativas de compilación desde un crate externo.

#[cfg(feature = "call-test-craft-handle")]
pub fn call_craft_handle(p: &nexo::physical::PhysicalPool) {
    let _ = p.__test_craft_handle(0, 1);
}

#[cfg(feature = "call-craft-handle-for-test")]
pub fn call_craft_handle_for_test(p: &nexo::physical::PhysicalPool) {
    let _ = p.craft_handle_for_test(0, 1);
}

#[cfg(feature = "construct-handle-struct")]
pub fn construct_handle() {
    let _h = nexo::physical::Handle {
        pool: 0,
        slot: 0,
        generation: 1,
    };
}

#[cfg(feature = "construct-hole-token")]
pub fn construct_hole_token() {
    let _t = nexo::physical::HoleToken {
        pool: 0,
        slot: 0,
        generation: 1,
    };
}

#[cfg(feature = "construct-link-struct")]
pub fn construct_link() {
    let _l = nexo::physical::Link {
        pool: 0,
        slot: 0,
        generation: 1,
    };
}

#[cfg(feature = "construct-objref-struct")]
pub fn construct_objref() {
    let _o = nexo::physical::ObjRef {
        pool: 0,
        slot: 0,
        generation: 1,
    };
}

#[cfg(feature = "clone-handle")]
pub fn clone_handle(h: &nexo::physical::Handle) {
    let _h2: nexo::physical::Handle = Clone::clone(h);
}

#[cfg(feature = "clone-hole-token")]
pub fn clone_hole_token(t: &nexo::physical::HoleToken) {
    let _t2: nexo::physical::HoleToken = Clone::clone(t);
}

#[cfg(feature = "call-test-corrupt-live")]
pub fn call_corrupt_live(p: &mut nexo::physical::PhysicalPool) {
    p.__test_corrupt_live(0);
}

#[cfg(feature = "call-corrupt-live-for-test")]
pub fn call_corrupt_live_for_test(p: &mut nexo::physical::PhysicalPool) {
    p.corrupt_live_for_test(0);
}
