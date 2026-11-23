// Reachability of module imports, calculated once after the loader has built
// the dependency graph. An importer can see its own declarations and public
// declarations in its transitive import closure.
//
// The matrix is indexed by importer * module_count + defining_module.
// Each source runs a bounded graph traversal: one queue entry per reachable
// module, even if multiple import paths reach it (diamonds or cycles). This
// does not depend on module numbering or a fixed-point scan of every module.
expose flow moduleAccessBuild(module_count: Int, first: view List of[Int], counts: view List of[Int], deps: view List of[Int]) => List of[Int] {
    change access: List of[Int] = List[]
    each i among 0..(module_count * module_count) { access@push(0) }

    each m among 0..module_count {
        hold base = m * module_count
        access[base + m] = 1

        change queue: List of[Int] = List[]
        queue@push(m)
        change head = 0
        during head < queue.length {
            hold dep = queue[head]
            head += 1
            when dep < 0 || dep >= first.length || dep >= counts.length { proceed }

            hold start = first[dep]
            hold count = counts[dep]
            // Malformed dependency metadata must never grant visibility.
            // Iterate with a remaining counter to avoid start + count overflow.
            when start < 0 || start > deps.length || count < 0 { proceed }
            // Reject an out-of-range count instead of scanning into another
            // module's adjacency slice and accidentally granting access.
            when count > deps.length - start { proceed }
            when dep + 1 < first.length {
                hold next_start = first[dep + 1]
                when next_start < start || next_start > deps.length { proceed }
                when count > next_start - start { proceed }
            }
            change i = start
            change remaining = count
            during remaining > 0 {
                hold next = deps[i]
                when next >= 0 && next < module_count {
                    hold pos = base + next
                    when access[pos] == 0 {
                        access[pos] = 1
                        queue@push(next)
                    }
                }
                i += 1
                remaining -= 1
            }
        }
    }
    give access
}
