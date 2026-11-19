// Platform builtins through the ELE-written native backend (Linux ELF64):
// processArgCount, printError and writeBytes, compiled by Stage 1 to
// ELE-LIR `i platform` and lowered by codegen/native_cfg_platform.
// Usage: native_platform_stage1 <output file> [more arguments...]
flow main() => Int {
    hold count = processArgCount()
    print(count)
    printError("aviso: plataforma nativa")
    change bytes: List of[Int] = List[]
    bytes@push(69)
    bytes@push(76)
    bytes@push(69)
    bytes@push(10)
    hold path = "native_platform_out.bin"
    hold status = writeBytes(path, bytes)
    print(status)
    change bad: List of[Int] = List[]
    bad@push(256)
    hold rejected = writeBytes(path, bad)
    print(rejected)
    hold empty = ""
    hold no_path = writeBytes(empty, bytes)
    print(no_path)
    hold missing_dir = "no-such-dir/x.bin"
    hold not_created = writeBytes(missing_dir, bytes)
    print(not_created)
    give count + 40
}
