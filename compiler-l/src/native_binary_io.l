// File-I/O contract fixture, in ELE.  Uses writeBytes without UTF-8 conversion.
// Usage: native-binary-io <output-path> [invalid]
fn main() -> Int {
    if processArgCount() < 1 || processArgCount() > 2 { return 2 }
    match processArg(0) {
        Ok(path) => {
            var bytes: List<Int> = List[0, 127, 128, 255, 10]
            if processArgCount() == 2 { bytes.push(256) }
            let status = writeBytes(path, bytes)
            if processArgCount() == 2 {
                if status == 1 { return 0 }
                return 3
            }
            return status
        }
        Err(code) => { return 4 }
    }
}
