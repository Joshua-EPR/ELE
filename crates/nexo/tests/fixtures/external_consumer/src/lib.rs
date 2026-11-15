//! Fixture para pruebas negativas de compilación desde un crate externo.

#[cfg(feature = "call-test-craft-handle")]
pub fn call_craft_handle(p: &nexo::physical::PhysicalPool) {
    let _ = p.__test_craft_handle(0, 1);
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

#[cfg(feature = "call-test-corrupt-live")]
pub fn call_corrupt_live(p: &mut nexo::physical::PhysicalPool) {
    p.__test_corrupt_live(0);
}
