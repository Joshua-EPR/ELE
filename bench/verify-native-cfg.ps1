# Stage 0/MSVC bootstrap and native CFG backend tests written in ELE.
# Does not claim independent Stage 2 or Rust-free bootstrap.
$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
Push-Location (Join-Path $PSScriptRoot '..')
try {
    cargo test -p project-l --test native_encoder_l --test native_cfg_l --test native_memory_l --test native_layout_l --test native_stack_layout_l --target x86_64-pc-windows-msvc -- --nocapture
    if ($LASTEXITCODE -ne 0) { throw 'ELE native x86-64/CFG tests failed' }
} finally {
    Pop-Location
}
