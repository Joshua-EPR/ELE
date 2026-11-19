
# Generate SHA-256 hashes for all files in a directory
param(
    [string]$Directory = "target",
    [string]$OutputFile = "build_hashes.sha256"
)

Get-ChildItem -Path $Directory -Recurse -File | ForEach-Object {
    $hash = Get-FileHash -Path $_.FullName -Algorithm SHA256
    "$($hash.Hash)  $($_.FullName)"
} | Out-File -FilePath $OutputFile
Write-Host "Hashes written to $OutputFile"
