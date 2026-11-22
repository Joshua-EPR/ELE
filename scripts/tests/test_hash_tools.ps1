# Self-contained tests for tools/generate_hashes.ps1 and tools/verify_hashes.py.
# No network. Works only inside a temp dir created under scripts/tests/.tmp-*
# and removes only that dir. Exit 0 = all pass, 1 = failure, 2 = python missing.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$verify = Join-Path $repo 'tools\verify_hashes.py'
$gen = Join-Path $repo 'tools\generate_hashes.ps1'
$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) { $py = Get-Command py -ErrorAction SilentlyContinue }
if (-not $py) { Write-Host 'SKIP: python not found'; exit 2 }
$tmp = Join-Path $PSScriptRoot ('.tmp-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$script:fail = 0
function Write-Utf8([string]$p, [string]$t) { [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($false))) }
function Invoke-Verify([string]$m) {
    $ErrorActionPreference = 'Continue'   # python writes diagnostics to stderr
    $null = & $py.Source $verify $m 2>&1
    return $LASTEXITCODE
}
function Test-Case([string]$name, [int]$got, [bool]$wantZero) {
    $ok = if ($wantZero) { $got -eq 0 } else { $got -ne 0 }
    if ($ok) { Write-Host "PASS $name (exit $got)" } else { Write-Host "FAIL $name (exit $got)"; $script:fail++ }
}
try {
    $d = Join-Path $tmp 'data dir'   # space in path on purpose
    New-Item -ItemType Directory -Path $d | Out-Null
    Write-Utf8 (Join-Path $d 'a.txt') 'alpha'
    Write-Utf8 (Join-Path $d 'b.txt') 'beta'
    $good = (Get-FileHash (Join-Path $d 'a.txt') -Algorithm SHA256).Hash.ToLower()
    $goodB = (Get-FileHash (Join-Path $d 'b.txt') -Algorithm SHA256).Hash.ToLower()
    $zeros = '0' * 64

    Write-Utf8 (Join-Path $tmp 'ok.sha256') "$good  data dir/a.txt`n$goodB  data dir/b.txt`n"
    Test-Case 'valid manifest' (Invoke-Verify (Join-Path $tmp 'ok.sha256')) $true

    Write-Utf8 (Join-Path $tmp 'missing.sha256') "$good  data dir/a.txt`n$goodB  data dir/nope.txt`n"
    Test-Case 'missing file' (Invoke-Verify (Join-Path $tmp 'missing.sha256')) $false

    Write-Utf8 (Join-Path $tmp 'malformed.sha256') "$good  data dir/a.txt`nthis is not a hash line`n"
    Test-Case 'malformed line' (Invoke-Verify (Join-Path $tmp 'malformed.sha256')) $false

    Write-Utf8 (Join-Path $tmp 'badhex.sha256') (('z' * 64) + "  data dir/a.txt`n")
    Test-Case 'non-hex digest' (Invoke-Verify (Join-Path $tmp 'badhex.sha256')) $false

    Write-Utf8 (Join-Path $tmp 'mismatch.sha256') "$zeros  data dir/a.txt`n"
    Test-Case 'mismatched hash' (Invoke-Verify (Join-Path $tmp 'mismatch.sha256')) $false

    Write-Utf8 (Join-Path $tmp 'empty.sha256') ''
    Test-Case 'empty manifest' (Invoke-Verify (Join-Path $tmp 'empty.sha256')) $false

    Test-Case 'nonexistent manifest' (Invoke-Verify (Join-Path $tmp 'absent.sha256')) $false

    [IO.File]::WriteAllText((Join-Path $tmp 'utf16.sha256'), "$good  data dir/a.txt`n", [Text.Encoding]::Unicode)
    Test-Case 'UTF-16 manifest fails cleanly' (Invoke-Verify (Join-Path $tmp 'utf16.sha256')) $false

    # Round trip through the generator (relative paths, spaces in path).
    Push-Location $tmp
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $gen -Directory 'data dir' -OutputFile 'gen.sha256' | Out-Null
        Test-Case 'generator exit' $LASTEXITCODE $true
    } finally { Pop-Location }
    Test-Case 'generated manifest verifies' (Invoke-Verify (Join-Path $tmp 'gen.sha256')) $true
    Write-Utf8 (Join-Path $d 'a.txt') 'tampered'
    Test-Case 'tampered file after generate' (Invoke-Verify (Join-Path $tmp 'gen.sha256')) $false
} finally {
    if ((Test-Path -LiteralPath $tmp) -and $tmp.StartsWith($PSScriptRoot)) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
if ($script:fail -gt 0) { Write-Host "$($script:fail) test(s) FAILED"; exit 1 }
Write-Host 'All hash tool tests passed'
exit 0
