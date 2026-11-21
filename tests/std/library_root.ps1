# Run from anywhere: .\tests\std\library_root.ps1 -Ele <absolute ele.exe path>
param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$elePath = (Resolve-Path $Ele).Path
$source = Join-Path $root 'apps\elepad\src\console_import_smoke.l'
$out = Join-Path ([IO.Path]::GetTempPath()) ('ele-libroot-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    # Without --lib, this must not silently find the repository-wide std module.
    & $elePath build $source --target pe -o $out 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) { throw 'Cross-directory import unexpectedly compiled without --lib' }
    if (Test-Path $out) { Remove-Item $out -Force }
    & $elePath build $source --lib $root --target pe -o $out 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw 'Cross-directory import with --lib failed' }
    & $out | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Cross-directory import executable failed' }
    Write-Host 'PASS std library root from ELEPad'
} finally { if (Test-Path $out) { Remove-Item $out -Force } }
