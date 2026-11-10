# Verify the ABI-independent ELE layout planner and x86-64 memory encodings.
# Requires Stage 0 and the Windows MSVC Rust toolchain. Does not prove
# execution of owning structs, heap allocations, or drops in native ELE code.
$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    cargo test -p project-l --test native_layout_l --test native_memory_l --test native_stack_layout_l --target x86_64-pc-windows-msvc -- --nocapture
    if ($LASTEXITCODE -ne 0) { throw 'ELE native memory/layout bootstrap tests failed' }
} finally {
    Pop-Location
}
