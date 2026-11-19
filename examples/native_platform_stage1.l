// Platform builtins through the ELE-written native backend (Linux ELF64):
// processArgCount, printError and writeBytes, compiled by Stage 1 to
// ELE-LIR `i platform` and lowered by codegen/native_cfg_platform.
// Usage: native_platform_stage1 <output file> [more arguments...]
fn main() -> Int {
    let count = processArgCount()
    print(count)
    printError("aviso: plataforma nativa")
    var bytes: List<Int> = List[]
    bytes.push(69)
    bytes.push(76)
    bytes.push(69)
    bytes.push(10)
    let path = "native_platform_out.bin"
    let status = writeBytes(path, bytes)
    print(status)
    var bad: List<Int> = List[]
    bad.push(256)
    let rejected = writeBytes(path, bad)
    print(rejected)
    let empty = ""
    let no_path = writeBytes(empty, bytes)
    print(no_path)
    let missing_dir = "no-such-dir/x.bin"
    let not_created = writeBytes(missing_dir, bytes)
    print(not_created)
    return count + 40
}
