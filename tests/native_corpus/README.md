# Native conformance corpus

Programs and expectations that need **only an ELE compiler binary**: the
ELE-written driver `compiler-l/src/main_driver.l`
(`<driver> build <file.l> --target pe|elf --output <path>`). No cargo,
rustc or Stage 0 is involved, so the corpus keeps working after Stage 0 is
removed.

```text
powershell -NoProfile -ExecutionPolicy Bypass -File tests/native_corpus/run.ps1 <driver.exe>   # PE32+, Windows
sh tests/native_corpus/run.sh <driver>                                                          # ELF64, Linux x86-64
```

- `<name>.l` + `<name>.stdout` + `<name>.exit`: the program is compiled and
  run with stdin at EOF, a timeout and a fresh working directory; stdout must
  match byte for byte and the exit status exactly.
- `reject/<name>.l` + `reject/<name>.diag`: the compiler must exit non-zero,
  produce no output file and print every non-empty line of the `.diag` file
  (a `file.l:line:col: error[CODE]` prefix and a stable message fragment).
- `modules/`: modules imported by cases (`take modules.corpus_math`); not
  cases themselves.
- `known_gaps.txt` / `KNOWN_GAPS.md`: driver gaps that run as XFAIL; an
  unexpected pass (XPASS) fails the run.

Nothing is normalized. Expected files are LF and `.gitattributes` disables
end-of-line conversion; the native runtimes write LF on every target.
During the transition, `crates/l/tests/native_corpus_l.rs` builds the driver
with Stage 0 and runs both runners from `cargo test`.

All sources use ELE v2 syntax only; `crates/l/tests/ele_v2_legacy_ratchet.rs`
audits this tree as fully migrated.
