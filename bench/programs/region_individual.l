// 200000 buffers of 64 bytes, one region per buffer: one heap block
// reserved and released per buffer (individual allocation pattern).
fn main() {
    var total = 0
    for i in 0..200000 {
        region r {
            var b = r.bytes(64)
            b.set(i % 64, i % 256)
            total += b.get(i % 64)
        }
    }
    print(total)
}
