// File-I/O contract fixture, in ELE.  Uses writeBytes without UTF-8 conversion.
// Usage: native-binary-io <output-path> [invalid]
flow main() => Int {
    when processArgCount() < 1 || processArgCount() > 2 { give 2 }
    choose processArg(0) {
        Ok(path) : {
            change bytes: List of[Int] = List[0, 127, 128, 255, 10]
            when processArgCount() == 2 { bytes@push(256) }
            hold status = writeBytes(path, bytes)
            when processArgCount() == 2 {
                when status == 1 { give 0 }
                give 3
            }
            give status
        }
        Err(code) : { give 4 }
    }
}
