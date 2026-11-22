// Reachability of module imports, calculated once after the loader has built
// the dependency graph. An importer can see its own declarations and public
// declarations in its transitive import closure.
//
// The matrix is indexed by importer * module_count + defining_module.
// Each source runs a bounded graph traversal: one queue entry per reachable
// module, even if multiple import paths reach it (diamonds or cycles). This
// does not depend on module numbering or a fixed-point scan of every module.
pub fn moduleAccessBuild(module_count: Int, first: &List<Int>, counts: &List<Int>, deps: &List<Int>) -> List<Int> {
    var access: List<Int> = List[]
    for i in 0..(module_count * module_count) { access.push(0) }

    for m in 0..module_count {
        let base = m * module_count
        access[base + m] = 1

        var queue: List<Int> = List[]
        queue.push(m)
        var head = 0
        while head < queue.length {
            let dep = queue[head]
            head += 1
            if dep < 0 || dep >= first.length || dep >= counts.length { continue }

            let start = first[dep]
            let count = counts[dep]
            // Malformed dependency metadata must never grant visibility.
            // Iterate with a remaining counter to avoid start + count overflow.
            if start < 0 || start > deps.length || count < 0 { continue }
            // Reject an out-of-range count instead of scanning into another
            // module's adjacency slice and accidentally granting access.
            if count > deps.length - start { continue }
            if dep + 1 < first.length {
                let next_start = first[dep + 1]
                if next_start < start || next_start > deps.length { continue }
                if count > next_start - start { continue }
            }
            var i = start
            var remaining = count
            while remaining > 0 {
                let next = deps[i]
                if next >= 0 && next < module_count {
                    let pos = base + next
                    if access[pos] == 0 {
                        access[pos] = 1
                        queue.push(next)
                    }
                }
                i += 1
                remaining -= 1
            }
        }
    }
    return access
}
