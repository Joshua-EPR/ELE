# Generate a SHA-256 manifest ("<HASH>  <path>") for all files in a directory.
# Paths are written relative to the manifest's directory (forward slashes) so
# tools/verify_hashes.py can verify it from anywhere. UTF-8 without BOM, LF.
# Fails (non-zero) if the directory is missing or empty. Read-only on inputs.
param(
    [string]$Directory = "target",
    [string]$OutputFile = "build_hashes.sha256"
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
    Write-Error "Directory not found: $Directory"
    exit 1
}
$dirFull = (Resolve-Path -LiteralPath $Directory).Path
$outFull = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutputFile))
$base = [IO.Path]::GetDirectoryName($outFull).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
$lines = New-Object System.Collections.Generic.List[string]
Get-ChildItem -LiteralPath $dirFull -Recurse -File -Force |
    Where-Object { $_.FullName -ne $outFull } |
    Sort-Object FullName | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $name = $_.FullName
        if ($name.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring($base.Length) }
        $lines.Add(("{0}  {1}" -f $hash, ($name -replace '\\', '/')))
    }
if ($lines.Count -eq 0) { Write-Error "No files under $Directory"; exit 1 }
[IO.File]::WriteAllText($outFull, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
Write-Host "Hashes written to $OutputFile ($($lines.Count) files)"
