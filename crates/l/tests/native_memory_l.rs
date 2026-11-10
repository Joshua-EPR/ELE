//! Stage-0 bootstrap tests for x86-64 memory-address encodings written in ELE.
//! Expected bytes are independently verified against x86-64 disassembly.
mod stage1_support;

use std::process::Command;

#[test]
fn ele_x86_64_memory_addressing_handles_rex_sib_and_signed_offsets() {
    let exe = stage1_support::build("native_memory_cases", false);
    let out = Command::new(exe).output().expect("run memory encoder fixture");
    assert!(
        out.status.success(),
        "stderr={} stdout={}",
        String::from_utf8_lossy(&out.stderr),
        String::from_utf8_lossy(&out.stdout)
    );
    let stdout = String::from_utf8(out.stdout).expect("UTF-8 output");
    let encoded = stdout
        .lines()
        .find_map(|line| line.strip_prefix("ELE_MEMORY_CODE_HEX:"))
        .expect("byte output from ELE fixture");
    let expected: Vec<u8> = [
        "4d8b842410000000", // mov r8,[r12+16]
        "4d898de8ffffff",   // mov [r13-24],r9
        "488b85f8ffffff",   // mov rax,[rbp-8]
        "4889842400000000", // mov [rsp],rax
        "4d0fb6942411000000", // movzx r10,byte [r12+17]
        "4188b5f7ffffff",   // mov byte [r13-9],sil
    ]
    .concat()
    .as_bytes()
    .chunks_exact(2)
    .map(|bytes| u8::from_str_radix(std::str::from_utf8(bytes).unwrap(), 16).unwrap())
    .collect();
    assert_eq!(encoded.len() % 2, 0, "hex string must have pairs");
    let actual: Vec<u8> = encoded
        .as_bytes()
        .chunks_exact(2)
        .map(|bytes| u8::from_str_radix(std::str::from_utf8(bytes).unwrap(), 16).unwrap())
        .collect();
    assert_eq!(actual, expected);
}
