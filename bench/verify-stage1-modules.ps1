# Runs the actual Stage 0 / Stage 1 compiler integration tests on Windows.
# Unlike the Python static audit, these are real compiler and native execution tests.
param([switch] $FullSuite)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    $env:RUSTUP_TOOLCHAIN = 'stable-x86_64-pc-windows-msvc'
    $env:RUSTC = 'rustc'
    $env:RUSTDOC = 'rustdoc'
    $target = 'x86_64-pc-windows-msvc'
    if ($FullSuite) {
        & cargo test --target $target
    } else {
        & cargo test -p project-l --target $target --test modules_l -- --nocapture
    }
    if ($LASTEXITCODE -ne 0) { throw "Cargo test failed ($LASTEXITCODE)" }
    & cargo fmt --all --check
    if ($LASTEXITCODE -ne 0) { throw "cargo fmt failed ($LASTEXITCODE)" }
    & cargo clippy --target $target --all-targets -- -D warnings
    if ($LASTEXITCODE -ne 0) { throw "cargo clippy failed ($LASTEXITCODE)" }
    Write-Host 'ELE Stage 1 module compilation and tests: PASS'
} finally {
    Pop-Location
}
