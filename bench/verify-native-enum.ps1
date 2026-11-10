$ErrorActionPreference = "Stop"
$env:RUSTUP_TOOLCHAIN = "stable-x86_64-pc-windows-msvc"
cargo test --target x86_64-pc-windows-msvc -p project-l --test native_enum_l -- --nocapture
if ($LASTEXITCODE -ne 0) { throw "Error en pruebas del backend de enums ELE" }
