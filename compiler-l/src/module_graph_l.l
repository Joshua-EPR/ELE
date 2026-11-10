// Reachability of module imports, calculated once after dependency-first load.
// A module can see its own declarations and declarations from modules in
// its transitive import closure. Visibility (`pub`) is checked separately.
// The flat matrix is indexed by importer * module_count + defining_module.
// This representation does not store pointers into potentially moved lists.
fn moduleAccessBuild(module_count: Int, first: &List<Int>, counts: &List<Int>, deps: &List<Int>) -> List<Int> {
    var access: List<Int> = List[]
    for i in 0..(module_count * module_count) { access.push(0) }
    for m in 0..module_count {
        access[m * module_count + m] = 1
        if m < first.length && m < counts.length {
            let start = first[m]
            let count = counts[m]
            for i in start..(start + count) {
                if i >= 0 && i < deps.length {
                    let dep = deps[i]
                    // Dependencies are loaded before importers, so their
                    // complete transitive closure has already been computed.
                    if dep >= 0 && dep < m {
                        for k in 0..module_count {
                            if access[dep * module_count + k] == 1 {
                                access[m * module_count + k] = 1
                            }
                        }
                    }
                }
            }
        }
    }
    return access
}
