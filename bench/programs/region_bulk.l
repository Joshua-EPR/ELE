// The same 200000 buffers in one region: fewest heap blocks, but all
// 12.8 MB stay alive until the region ends (higher peak memory).
fn main() {
    var total = 0
    region r {
        for i in 0..200000 {
            var b = r.bytes(64)
            b.set(i % 64, i % 256)
            total += b.get(i % 64)
        }
    }
    print(total)
}
