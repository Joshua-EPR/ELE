// Reachability of module imports, calculated once after dependency-first load.
// A module can see its own declarations and declarations from modules in
// its transitive import closure. Visibility (`pub`) is checked separately.
// The flat matrix is indexed by importer * module_count + defining_module.
// This representation does not store pointers into potentially moved lists.
//
// The loader guarantees dependencies are materialized first, but the visibility
// matrix should not depend on that incidental ordering. Walk each module's
// dependency graph explicitly and propagate the transitive closure from the
// direct imports rather than copying earlier rows via a numeric ordering hack.
fn moduleAccessBuild(module_count: Int, first: &List<Int>, counts: &List<Int>, deps: &List<Int>) -> List<Int> {
    var access: List<Int> = List[]
    for i in 0..(module_count * module_count) { access.push(0) }
    for m in 0..module_count {
        access[m * module_count + m] = 1
    }
    for m in 0..module_count {
        var changed = true
        while changed {
            changed = false
            for dep in 0..module_count {
                let pos = m * module_count + dep
                if pos < 0 || pos >= access.length || access[pos] == 0 { continue }
                if dep >= first.length || dep >= counts.length { continue }
                let dep_start = first[dep]
                let dep_count = counts[dep]
                for i in dep_start..(dep_start + dep_count) {
                    if i < 0 || i >= deps.length { continue }
                    let next = deps[i]
                    if next < 0 || next >= module_count { continue }
                    let next_pos = m * module_count + next
                    if next_pos < 0 || next_pos >= access.length { continue }
                    if access[next_pos] == 0 {
                        access[next_pos] = 1
                        changed = true
                    }
                }
            }
        }
    }
    return access
}
