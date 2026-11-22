// Native file streams (P0-B): block I/O over the linear File resource.
// Usage: file_streams <existing scratch directory>. Prints file-streams-ok
// and exits 0; any other exit code names the first failed check.

flow sameBytes(a: view List of[Int], b: view List of[Int]) => Bool {
    when a.length != b.length { give false }
    change i = 0
    during i < a.length {
        when a[i] != b[i] { give false }
        i += 1
    }
    give true
}

// Read the whole file through `block`-byte reads into a new list.
flow readAll(path: view Text, block: Int, out: edit List of[Int]) => Int {
    hold f = fileOpen(path, 1)
    when fileStatus(f) != 0 {
        hold status = fileStatus(f)
        fileClose(f)
        give status
    }
    change buf: List of[Int] = List[]
    change k = 0
    during k < block {
        buf@push(0)
        k += 1
    }
    change result = 0
    during true {
        hold n = fileRead(f, buf, block)
        when n < 0 {
            result = n
            leave
        }
        when n == 0 { leave }
        change i = 0
        during i < n {
            out@push(buf[i])
            i += 1
        }
    }
    hold closed = fileClose(f)
    when result != 0 { give result }
    give closed
}

flow sizeOf(f: view File) => Int {
    give fileSize(f)
}

flow binaryChecks(dir: view Text) => Int {
    hold path = "{dir}/streams.bin"
    hold data: List of[Int] = List[0, 1, 2, 255, 10, 13, 128, 65]
    // Create a new file (mode 4) and write binary bytes.
    hold f = fileOpen(path, 4)
    when fileStatus(f) != 0 {
        fileClose(f)
        give 10
    }
    when fileWrite(f, data, 8) != 8 {
        fileClose(f)
        give 11
    }
    when sizeOf(view f) != 8 {
        fileClose(f)
        give 12
    }
    when fileFlush(f) != 0 {
        fileClose(f)
        give 13
    }
    when fileClose(f) != 0 { give 14 }
    // Create-new refuses an existing file.
    hold again = fileOpen(path, 4)
    hold again_status = fileStatus(again)
    fileClose(again)
    when again_status != -4 { give 15 }
    // Block reads of 3 bytes reassemble the exact content; EOF is 0.
    change got: List of[Int] = List[]
    when readAll(path, 3, edit got) != 0 { give 16 }
    when !sameBytes(view got, view data) { give 17 }
    // Seek from the start, the end and the current position.
    hold r = fileOpen(path, 1)
    change one: List of[Int] = List[0]
    when fileSeek(r, 3, 0) != 3 {
        fileClose(r)
        give 18
    }
    when fileRead(r, one, 1) != 1 || one[0] != 255 {
        fileClose(r)
        give 19
    }
    when fileSeek(r, -1, 2) != 7 {
        fileClose(r)
        give 20
    }
    when fileRead(r, one, 1) != 1 || one[0] != 65 {
        fileClose(r)
        give 21
    }
    when fileRead(r, one, 1) != 0 {
        fileClose(r)
        give 22
    }
    when fileSeek(r, -100, 1) != -1 {
        fileClose(r)
        give 23
    }
    when fileSeek(r, 0, 3) != -1 {
        fileClose(r)
        give 24
    }
    // A read-only file rejects writes.
    when fileWrite(r, data, 1) >= 0 {
        fileClose(r)
        give 25
    }
    fileClose(r)
    // Append (mode 3) always writes at the end.
    hold a = fileOpen(path, 3)
    when fileWrite(a, data, 2) != 2 {
        fileClose(a)
        give 26
    }
    when fileSize(a) != 10 {
        fileClose(a)
        give 27
    }
    fileClose(a)
    // Read+write (mode 5) overwrites in place.
    hold rw = fileOpen(path, 5)
    hold patch: List of[Int] = List[7]
    when fileSeek(rw, 9, 0) != 9 || fileWrite(rw, patch, 1) != 1 {
        fileClose(rw)
        give 28
    }
    fileClose(rw)
    change after: List of[Int] = List[]
    when readAll(path, 4, edit after) != 0 { give 29 }
    when after.length != 10 || after[8] != 0 || after[9] != 7 { give 30 }
    // Write (mode 2) truncates.
    hold t = fileOpen(path, 2)
    when fileSize(t) != 0 {
        fileClose(t)
        give 31
    }
    fileClose(t)
    give 0
}

flow errorChecks(dir: view Text) => Int {
    hold missing_path = "{dir}/missing/none.bin"
    hold missing = fileOpen(missing_path, 1)
    hold missing_status = fileStatus(missing)
    change buf: List of[Int] = List[0, 0]
    hold read_missing = fileRead(missing, buf, 1)
    hold size_missing = fileSize(missing)
    // Closing a failed open releases nothing and succeeds.
    hold close_missing = fileClose(missing)
    when missing_status != -2 { give 40 }
    when read_missing != -6 || size_missing != -6 { give 41 }
    when close_missing != 0 { give 42 }
    hold path = "{dir}/errors.bin"
    hold bad_mode = fileOpen(path, 9)
    hold bad_mode_status = fileStatus(bad_mode)
    fileClose(bad_mode)
    when bad_mode_status != -1 { give 43 }
    hold empty_path = ""
    hold no_path = fileOpen(empty_path, 1)
    hold no_path_status = fileStatus(no_path)
    fileClose(no_path)
    when no_path_status != -1 { give 44 }
    hold w = fileOpen(path, 2)
    hold bytes: List of[Int] = List[1, 256]
    // A byte outside 0..255 is rejected before anything is written.
    when fileWrite(w, bytes, 2) != -1 {
        fileClose(w)
        give 45
    }
    // More than the list holds, and a negative count, are rejected.
    when fileWrite(w, bytes, 3) != -1 || fileWrite(w, bytes, -1) != -1 {
        fileClose(w)
        give 46
    }
    when fileSize(w) != 0 {
        fileClose(w)
        give 47
    }
    // Writing nothing is a successful no-op.
    when fileWrite(w, bytes, 0) != 0 {
        fileClose(w)
        give 48
    }
    fileClose(w)
    hold r = fileOpen(path, 1)
    // The read limit must be 1..length of the destination.
    when fileRead(r, buf, 3) != -1 || fileRead(r, buf, 0) != -1 {
        fileClose(r)
        give 49
    }
    // An empty file reads as end of file at once.
    when fileRead(r, buf, 2) != 0 {
        fileClose(r)
        give 50
    }
    fileClose(r)
    give 0
}

// 1 MiB written in 64 KiB blocks, read back in 4093-byte blocks.
flow largeChecks(dir: view Text) => Int {
    hold path = "{dir}/large.bin"
    hold block = 65536
    change chunk: List of[Int] = List[]
    chunk@reserve(block)
    hold w = fileOpen(path, 2)
    change written = 0
    change b = 0
    during b < 16 {
        change i = 0
        during i < block {
            when b == 0 { chunk@push((i * 7 + 3) % 256) }
            otherwise { chunk[i] = (b * block + i) * 7 % 256 }
            i += 1
        }
        when b == 0 {
            change j = 0
            during j < block {
                chunk[j] = j * 7 % 256
                j += 1
            }
        }
        hold n = fileWrite(w, chunk, block)
        when n != block {
            fileClose(w)
            give 60
        }
        written += n
        b += 1
    }
    when fileSize(w) != written || written != 1048576 {
        fileClose(w)
        give 61
    }
    fileClose(w)
    change back: List of[Int] = List[]
    when readAll(path, 4093, edit back) != 0 { give 62 }
    when back.length != 1048576 { give 63 }
    change k = 0
    during k < back.length {
        when back[k] != k * 7 % 256 { give 64 }
        k += 1
    }
    give 0
}

flow main() => Int {
    when processArgCount() != 1 {
        printError("uso: file_streams <directorio>")
        give 2
    }
    choose processArg(0) {
        Ok(dir): {
            hold binary = binaryChecks(view dir)
            when binary != 0 { give binary }
            hold errors = errorChecks(view dir)
            when errors != 0 { give errors }
            hold large = largeChecks(view dir)
            when large != 0 { give large }
            print("file-streams-ok")
            give 0
        },
        Err(code): { give 3 },
    }
}
