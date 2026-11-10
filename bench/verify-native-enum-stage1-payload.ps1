$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$target = 'x86_64-pc-windows-msvc'
cargo test -p project-l --test lir_payload_protocol --target $target
if ($LASTEXITCODE -ne 0) { throw 'LIR payload protocol failed' }
cargo test -p project-l --test native_enum_stage1_payload_l --target $target
if ($LASTEXITCODE -ne 0) { throw 'Stage 1 enum payload integration failed' }
Write-Host 'Windows integration passed; run ELF on Linux x86_64 to verify exit code 42.'
