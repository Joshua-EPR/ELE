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

#[cfg(feature = "implement-sealed-authority")]
pub struct ExternalAuthority;

#[cfg(feature = "implement-sealed-authority")]
impl nexo::next::CompactPoolAuthority for ExternalAuthority {
    fn compact_id(&self) -> u8 {
        1
    }
    fn slot_capacity(&self) -> u32 {
        10
    }
    fn current_compact_generation(
        &self,
        _slot: u32,
    ) -> Result<u8, nexo::next::CompactRevalidateError> {
        Ok(1)
    }
}

#[cfg(feature = "implement-sealed-authority-64")]
pub struct ExternalAuthority64;

#[cfg(feature = "implement-sealed-authority-64")]
impl nexo::next::CompactPoolAuthority64 for ExternalAuthority64 {
    fn compact_id(&self) -> u16 {
        1
    }
    fn slot_capacity(&self) -> u32 {
        10
    }
    fn current_compact_generation(
        &self,
        _slot: u32,
    ) -> Result<u16, nexo::next::CompactRevalidateError> {
        Ok(1)
    }
}

#[cfg(feature = "construct-compact-token")]
pub fn construct_token() {
    let _t = nexo::next::CompactPoolToken {
        id: 1,
        physical_pool_id: 100,
    };
}

#[cfg(feature = "construct-compact-token16")]
pub fn construct_token16() {
    let _t = nexo::next::CompactPoolToken16 {
        id: 1,
        physical_pool_id: 100,
    };
}

#[cfg(feature = "access-mock-compact-pool")]
pub fn access_mock() {
    let _m = nexo::next::compact::testing::MockCompactPool {
        id: 1,
        capacity: 10,
        generations: vec![1],
    };
}

#[cfg(feature = "convert-compact-objref-to-handle")]
pub fn convert_objref_to_handle(obj: &nexo::next::CompactObjRef<'_>) {
    let _h: nexo::physical::Handle = obj.to_handle();
}

#[cfg(feature = "retain-compact-objref-past-pool")]
pub fn retain_objref_past_pool() -> nexo::next::CompactObjRef<'static> {
    use nexo::next::CompactPoolAuthority;
    let config = nexo::physical::PoolConfig {
        fields: 2,
        slot_size: 64,
        max_superpages: 1,
        initial_generation: 0,
        fail_reserve: false,
        fail_commit_at: None,
        reclaim: nexo::physical::ReclaimPolicy::Aggressive,
        protect_before_discard: true,
    };
    let pool = nexo::physical::PhysicalPool::new(config).unwrap();
    let token = nexo::next::CompactPoolRegistry::register_pool(&pool).unwrap();
    let adapter = nexo::next::CompactPhysicalPool::new(&pool, &token).unwrap();
    let link = nexo::next::CompactLink::new(token.id(), 0, 1).unwrap();
    adapter.revalidate_compact(link).unwrap()
}

#[cfg(feature = "mutate-pool-while-borrowed")]
pub fn mutate_pool_while_borrowed() {
    use nexo::next::CompactPoolAuthority;
    let config = nexo::physical::PoolConfig {
        fields: 2,
        slot_size: 64,
        max_superpages: 1,
        initial_generation: 0,
        fail_reserve: false,
        fail_commit_at: None,
        reclaim: nexo::physical::ReclaimPolicy::Aggressive,
        protect_before_discard: true,
    };
    let mut pool = nexo::physical::PhysicalPool::new(config).unwrap();
    let token = nexo::next::CompactPoolRegistry::register_pool(&pool).unwrap();
    let adapter = nexo::next::CompactPhysicalPool::new(&pool, &token).unwrap();
    let link = nexo::next::CompactLink::new(token.id(), 0, 1).unwrap();
    let _obj = adapter.revalidate_compact(link).unwrap();
    let _ = pool.allocate();
    let _ = _obj.slot();
}

#[cfg(feature = "call-acquire-token-for")]
pub fn call_acquire_token_for() {
    let _ = nexo::next::CompactPoolRegistry::acquire_token_for(1);
}

#[cfg(feature = "call-acquire-token")]
pub fn call_acquire_token() {
    let _ = nexo::next::CompactPoolRegistry::acquire_token();
}
