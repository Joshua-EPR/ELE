// The same 200000 buffers, one region per batch of 1000: bump allocation
// inside a few blocks, released together at the end of each batch.
fn main() {
    var total = 0
    for lote in 0..200 {
        region r {
            for k in 0..1000 {
                let i = lote * 1000 + k
                var b = r.bytes(64)
                b.set(i % 64, i % 256)
                total += b.get(i % 64)
            }
        }
    }
    print(total)
}
