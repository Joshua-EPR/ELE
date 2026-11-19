
# Clean build and remove old artifacts
Write-Host "Cleaning build..."
cargo clean
Write-Host "Cleaning target directory..."
if (Test-Path "target") {
    Remove-Item -Recurse -Force "target"
}
Write-Host "Build directory cleaned."
