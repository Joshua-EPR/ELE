$ErrorActionPreference = "Stop"
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
cargo test --target x86_64-pc-windows-msvc -p project-l --test native_nested_struct_l -- --nocapture
if ($LASTEXITCODE -ne 0) { throw "Error al validar structs Copy anidados" }
