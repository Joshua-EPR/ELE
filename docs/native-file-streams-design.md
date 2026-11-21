# Native file streams: implementation contract

Status: design for P0-B. The current platform operations are whole-file
`readText` and `writeBytes`; this document does not declare stream support.

## Verified Linux metadata correction in this branch

The ELF64 `writeBytes` backend now queries an existing destination with
`stat`, copies its permission and special bits to the exclusive temporary
with `fchmod`, then writes, syncs, and renames. A missing destination keeps
the existing umask-controlled creation mode. Failure to query or set mode
aborts publication and closes/unlinks the temporary. A native Ubuntu WSL
probe demonstrated the prior behavior (`0600` became `0644`) and the
corrected behavior (`0600` remains `0600`, bytes `45 4c 45 0a`).

## Resource ownership

An open file must be a linear, opaque value. Only `open` creates it. Moving
the value transfers its one owner. `close` consumes it and invalidates all
borrows. The LIR verifier must reject an uninitialized, moved or closed
resource, a second close, and a mutable borrow overlapping another access.
The native handle or descriptor must remain inaccessible as an `Int` to ELE
code. Every failed operation must leave resource ownership explicit; it must
never silently destroy a live handle.

## Operations and results

The eventual standard module should expose explicit open modes, block read,
block write, append, seek/tell, length, flush, close, existence and basic
metadata. Reads return both the bytes obtained and end-of-file information;
writes report the number of bytes accepted or an error, and the library loops
until the requested block is fully written when that is its contract. A zero
byte read at EOF is distinct from an error. Binary data must use a byte
container, never `Text` without UTF-8 validation.

## Native boundary

On Windows, use UTF-16 paths and `CreateFileW`, `ReadFile`, `WriteFile`,
`SetFilePointerEx`, `GetFileSizeEx`, `FlushFileBuffers`, and `CloseHandle`.
On Linux, use direct syscalls with `O_CLOEXEC`, retry `EINTR` where needed,
and close on every failed initialization path. Both backends must bound block
size and offset arithmetic before crossing the ABI. No libc is required at
runtime.

## Publication and metadata

Existing `writeBytes` uses an exclusive temporary in the destination
directory, writes fully, synchronizes it, then publishes through
`MoveFileExW` or `rename`. This protects against partially written output,
but does not alone guarantee directory-entry durability after power loss.
Replacement should retain appropriate file permissions and attributes. An
existing destination must be checked before publication to avoid accidental
overwrite of an unrelated file; the editor must also confirm unsaved changes.

## Validation gates

Use negative LIR cases for forged handles, invalid loans, double close,
use-after-close and wrong argument modes. Run native tests for empty, large,
binary and partial I/O, failed open, repeated save, handle leaks and
simultaneous access. Run Windows and Linux executables, then the Gen 2/Gen 3
fixpoint after changes to Stage 1, LIR, or native backends.
