$ErrorActionPreference = 'Stop'
$env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
$target = 'x86_64-pc-windows-msvc'

cargo test -p project-l --test lir_payload_protocol --target $target
if ($LASTEXITCODE -ne 0) { throw 'ELE-LIR variant/payload protocol tests failed' }

cargo test -p project-l --test native_enum_stage1_payload_l --target $target
if ($LASTEXITCODE -ne 0) { throw 'Stage 1 enum match/payload tests failed' }

Write-Host 'Tests passed on Windows. Execute the emitted ELF on Linux x86-64 or WSL as a separate verification.'
