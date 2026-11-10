struct LRegion(std::cell::RefCell<Vec<LRegionBlock>>);

struct LRegionBlock(*mut u8, std::alloc::Layout);

impl Drop for LRegionBlock {
    fn drop(&mut self) {
        unsafe { std::alloc::dealloc(self.0, self.1) }
    }
}

impl LRegion {
    fn new() -> Self {
        Self(std::cell::RefCell::new(Vec::new()))
    }

    fn allocate(&self, size: usize, align: usize, line: usize, column: usize) -> *mut u8 {
        let layout = std::alloc::Layout::from_size_align(size.max(1), align)
            .unwrap_or_else(|_| l_panic(line, column, "capacidad de List desbordada"));
        let mut blocks = self.0.borrow_mut();
        if blocks.try_reserve(1).is_err() {
            l_panic(line, column, "memoria insuficiente");
        }
        let ptr = unsafe { std::alloc::alloc_zeroed(layout) };
        if ptr.is_null() {
            l_panic(line, column, "memoria insuficiente");
        }
        blocks.push(LRegionBlock(ptr, layout));
        ptr
    }

    fn bytes(&self, n: i64, line: usize, column: usize) -> LBytes {
        if n < 0 {
            l_panic(line, column, "tamaño de buffer negativo");
        }
        LBytes(self.allocate(n as usize, 8, line, column), n as usize)
    }
}

struct LRegionList<'r, T> {
    region: &'r LRegion,
    data: *mut T,
    len: usize,
    cap: usize,
}

impl<'r, T> LRegionList<'r, T> {
    fn new(region: &'r LRegion) -> Self {
        Self {
            region,
            data: std::ptr::NonNull::dangling().as_ptr(),
            len: 0,
            cap: 0,
        }
    }

    fn capacity(&self) -> usize {
        self.cap
    }

    fn reserve(&mut self, n: i64, min: i64, line: usize, column: usize) {
        if n < 0 {
            l_panic(line, column, "reserve con tamaño negativo");
        }
        if n as usize <= self.cap - self.len {
            return;
        }
        let overflow = || l_panic(line, column, "capacidad de List desbordada");
        let need = (self.len as i64).checked_add(n).unwrap_or_else(overflow);
        let cap = need
            .max((self.cap as i64).checked_mul(2).unwrap_or(need))
            .max(min);
        let bytes = cap
            .checked_mul(std::mem::size_of::<T>().max(1) as i64)
            .unwrap_or_else(overflow);
        let data = self
            .region
            .allocate(bytes as usize, std::mem::align_of::<T>(), line, column)
            .cast();
        // The allocation is disjoint. Ownership of the initialized prefix
        // transfers to data. The obsolete bytes are never read or dropped.
        unsafe { std::ptr::copy_nonoverlapping(self.data, data, self.len) };
        self.data = data;
        self.cap = cap as usize;
    }

    fn push(&mut self, value: T, line: usize, column: usize) {
        self.reserve(1, 4, line, column);
        unsafe { self.data.add(self.len).write(value) };
        self.len += 1;
    }

    fn pop(&mut self) -> Option<T> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        Some(unsafe { self.data.add(self.len).read() })
    }
}

impl<T> std::ops::Deref for LRegionList<'_, T> {
    type Target = [T];

    fn deref(&self) -> &[T] {
        unsafe { std::slice::from_raw_parts(self.data, self.len) }
    }
}

impl<T> std::ops::DerefMut for LRegionList<'_, T> {
    fn deref_mut(&mut self) -> &mut [T] {
        unsafe { std::slice::from_raw_parts_mut(self.data, self.len) }
    }
}

impl<T> Drop for LRegionList<'_, T> {
    fn drop(&mut self) {
        // The region outlives this header. It frees storage after element drops.
        unsafe { std::ptr::drop_in_place(std::ptr::slice_from_raw_parts_mut(self.data, self.len)) }
    }
}
