<#
.SYNOPSIS
    Stage-0-free ELE bootstrap from a hash-pinned seed driver (Windows, PE32+).

.DESCRIPTION
    Starting from a seed ELE driver binary whose SHA-256 is pinned by the caller:

      1. verify the seed hash (refuse on mismatch);
      2. seed   builds Gen1' from compiler-l/src/main_driver.l;
      3. Gen1'  builds Gen2;
      4. Gen2   builds Gen3;
      5. require Gen2 == Gen3 bitwise (print both hashes and the first
         differing offsets otherwise);
      6. Gen3 compiles and runs the smoke set in scripts/bootstrap/smoke/cases.txt
         and compares exact stdout bytes and exit codes with the checked-in
         expectations;
      7. Gen3 must reject every program in scripts/bootstrap/smoke/reject.txt;
      8. write provenance.json and SHA256SUMS to the output directory.

    This script never runs cargo, rustc, rustup, Stage 0 (`l`), cl, link, gcc,
    clang or ld. Every child process goes through Invoke-EleImage, which only
    executes images that live inside the output directory (the verified copy
    of the seed, the generations and the smoke programs) and refuses names of
    toolchain programs. Resolvable toolchain programs on PATH are recorded in
    provenance.json for information only; with -ForbidToolchainOnPath (or
    ELE_BOOTSTRAP_FORBID_TOOLCHAIN=1) cargo/rustc/rustup on PATH are an error.

.EXAMPLE
    ./scripts/bootstrap/ele_seed_bootstrap.ps1 -Seed .\seed\main_driver.exe `
        -SeedSha256 <64 hex> -Target pe -OutDir .\out\bootstrap
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Seed,
    [Parameter(Mandatory = $true)][string]$SeedSha256,
    [ValidateSet('pe')][string]$Target = 'pe',
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$RepoRoot = '',
    [switch]$ForbidToolchainOnPath,
    [int]$TimeoutSeconds = 600
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Programs this bootstrap must never execute. Stage 0's binary is `l`.
$ForbiddenTools = @('cargo', 'rustc', 'rustup', 'l', 'cl', 'link', 'gcc', 'clang', 'ld', 'lld', 'ld.lld', 'cc')
# Programs whose mere presence on PATH is an error under -ForbidToolchainOnPath.
$RustTools = @('cargo', 'rustc', 'rustup')
$DriverSource = 'compiler-l/src/main_driver.l'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-UtcStamp { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
function Write-Step([string]$Message) { Write-Host "==> $Message" }
function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

if (-not $RepoRoot) { $RepoRoot = Join-Path $PSScriptRoot '..\..' }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$state = [ordered]@{
    schema       = 'ele-seed-bootstrap/v1'
    status       = 'failed'
    failure      = $null
    target       = $Target
    host         = [ordered]@{ os = 'windows'; script = 'scripts/bootstrap/ele_seed_bootstrap.ps1'; powershell = $PSVersionTable.PSVersion.ToString() }
    started_utc  = Get-UtcStamp
    finished_utc = $null
    source       = $null
    seed         = $null
    guard        = $null
    generations  = @()
    fixpoint     = $null
    smoke        = @()
    reject       = @()
}

# ---------------------------------------------------------------- output dir
# Never overwrite earlier results: the directory must be new or empty.
if (Test-Path -LiteralPath $OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        throw "refusing: output path '$OutDir' exists and is not a directory"
    }
    if (@(Get-ChildItem -LiteralPath $OutDir -Force).Count -ne 0) {
        throw "refusing: output directory '$OutDir' is not empty; choose a new directory (existing outputs are never overwritten)"
    }
} else {
    New-Item -ItemType Directory -Path $OutDir | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$LogDir = Join-Path $OutDir 'logs'
$SmokeDir = Join-Path $OutDir 'smoke'
New-Item -ItemType Directory -Path $LogDir, $SmokeDir | Out-Null
$ProvenancePath = Join-Path $OutDir 'provenance.json'

function Assert-Fresh([string]$Path) {
    if (Test-Path -LiteralPath $Path) { throw "refusing to overwrite existing output '$Path'" }
}

function Save-Provenance {
    $state.finished_utc = Get-UtcStamp
    $json = $state | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText($ProvenancePath, $json + "`n", $Utf8NoBom)
}

# ------------------------------------------------------------- exec guard
function Assert-AllowedImage([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $OutDir.TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "guard: refusing to execute '$full': only images inside the bootstrap output directory may run"
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($full).ToLowerInvariant()
    if ($ForbiddenTools -contains $name) {
        throw "guard: refusing to execute '$full': '$name' is a forbidden toolchain program"
    }
    return $full
}

function ConvertTo-ArgString([string[]]$Arguments) {
    ($Arguments | ForEach-Object {
            if ($_ -match '"') { throw "guard: argument contains a double quote: $_" }
            if ($_ -match '[\s]') { '"' + $_ + '"' } else { $_ }
        }) -join ' '
}

# Runs an ELE-produced image; returns exit code and exact stdout bytes.
function Invoke-EleImage([string]$Image, [string[]]$Arguments, [string]$WorkDir, [string]$LogName) {
    $full = Assert-AllowedImage $Image
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $full
    $psi.Arguments = ConvertTo-ArgString $Arguments
    $psi.WorkingDirectory = $WorkDir
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Close()
    $stdout = New-Object System.IO.MemoryStream
    $stdoutTask = $proc.StandardOutput.BaseStream.CopyToAsync($stdout)
    $stderrMem = New-Object System.IO.MemoryStream
    $stderrTask = $proc.StandardError.BaseStream.CopyToAsync($stderrMem)
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "timeout: '$full $($psi.Arguments)' exceeded $TimeoutSeconds s"
    }
    $proc.WaitForExit()
    $stdoutTask.Wait(); $stderrTask.Wait()
    $outBytes = $stdout.ToArray()
    $errBytes = $stderrMem.ToArray()
    [IO.File]::WriteAllBytes((Join-Path $LogDir "$LogName.stdout"), $outBytes)
    [IO.File]::WriteAllBytes((Join-Path $LogDir "$LogName.stderr"), $errBytes)
    [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $outBytes
        Stderr   = $Utf8NoBom.GetString($errBytes)
    }
}

function Compare-Bytes([byte[]]$A, [byte[]]$B) {
    if ($A.Length -ne $B.Length) { return $false }
    for ($i = 0; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Get-DiffReport([string]$PathA, [string]$PathB) {
    $a = [IO.File]::ReadAllBytes($PathA); $b = [IO.File]::ReadAllBytes($PathB)
    $n = [Math]::Min($a.Length, $b.Length)
    $diffs = 0; $first = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $n; $i++) {
        if ($a[$i] -ne $b[$i]) {
            $diffs++
            if ($first.Count -lt 16) { $first.Add(('0x{0:X8}: {1:X2} != {2:X2}' -f $i, $a[$i], $b[$i])) }
        }
    }
    [ordered]@{
        size_a                 = $a.Length
        size_b                 = $b.Length
        differing_bytes_common = $diffs
        first_differences      = @($first)
    }
}

# ------------------------------------------------------------------ main
$exitCode = 1
try {
    # Guard: record (information only) which toolchain programs resolve here.
    Write-Step 'guard: toolchain programs on PATH (recorded for information; never executed)'
    $info = [ordered]@{}
    foreach ($tool in $ForbiddenTools) {
        $cmd = Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $info[$tool] = if ($cmd) { $cmd.Source } else { $null }
        Write-Host ("    {0,-7} {1}" -f $tool, $(if ($cmd) { $cmd.Source } else { '(not found)' }))
    }
    $forbid = $ForbidToolchainOnPath.IsPresent -or ($env:ELE_BOOTSTRAP_FORBID_TOOLCHAIN -eq '1')
    $state.guard = [ordered]@{
        never_executed               = $ForbiddenTools
        executes_only_inside_out_dir = $true
        rust_toolchain_forbidden     = $forbid
        host_tools_info              = $info
    }
    if ($forbid) {
        $present = @($RustTools | Where-Object { $info[$_] })
        if ($present.Count -gt 0) {
            throw "guard: Rust toolchain resolvable on PATH but forbidden: $($present -join ', ')"
        }
    }

    # Source provenance.
    $commit = $null; $commitFrom = 'unknown'; $dirty = $null
    # An explicit ELE_SOURCE_COMMIT wins and skips git entirely.
    if ($env:ELE_SOURCE_COMMIT) { $commit = $env:ELE_SOURCE_COMMIT; $commitFrom = 'env:ELE_SOURCE_COMMIT' }
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $commit -and $git) {
        $c = & $git.Source -C $RepoRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $c) {
            $commit = "$c".Trim(); $commitFrom = 'git'
            $porcelain = & $git.Source -C $RepoRoot status --porcelain --untracked-files=no 2>$null
            $dirty = [bool]($porcelain)
        }
    }
    if (-not $commit -and $env:GITHUB_SHA) { $commit = $env:GITHUB_SHA; $commitFrom = 'env:GITHUB_SHA' }
    $driverPath = Join-Path $RepoRoot $DriverSource
    if (-not (Test-Path -LiteralPath $driverPath)) { throw "driver source not found: $driverPath" }
    $state.source = [ordered]@{
        commit               = $commit
        commit_from          = $commitFrom
        tracked_files_dirty  = $dirty
        driver_source        = $DriverSource
        driver_source_sha256 = Get-Sha256 $driverPath
    }

    # Seed verification: hash, copy into the output dir, re-hash the copy.
    Write-Step "verify seed '$Seed'"
    if ($SeedSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'SeedSha256 must be 64 hex characters' }
    $expected = $SeedSha256.ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $Seed -PathType Leaf)) { throw "seed not found: $Seed" }
    $seedName = [IO.Path]::GetFileNameWithoutExtension($Seed).ToLowerInvariant()
    if ($ForbiddenTools -contains $seedName) { throw "guard: seed '$Seed' is named like a forbidden toolchain program ('$seedName')" }
    $actual = Get-Sha256 $Seed
    $state.seed = [ordered]@{ file_name = [IO.Path]::GetFileName($Seed); sha256_expected = $expected; sha256_actual = $actual; size = (Get-Item -LiteralPath $Seed).Length }
    if ($actual -ne $expected) { throw "seed hash mismatch: expected $expected, got $actual" }
    $seedCopy = Join-Path $OutDir 'seed.exe'
    Assert-Fresh $seedCopy
    Copy-Item -LiteralPath $Seed -Destination $seedCopy
    if ((Get-Sha256 $seedCopy) -ne $expected) { throw 'seed copy hash mismatch (file changed while copying)' }
    Write-Host "    seed sha256 $actual (matches pin)"
    $help = Invoke-EleImage $seedCopy @('--help') $RepoRoot 'seed-help'
    if ($help.ExitCode -ne 0 -or -not $Utf8NoBom.GetString($help.Stdout).Contains('ELE Compiler Driver')) {
        throw 'seed does not identify as the ELE compiler driver (--help)'
    }

    # Generations.
    $chain = @(
        @{ name = 'gen1prime'; by = 'seed'; compiler = $seedCopy },
        @{ name = 'gen2'; by = 'gen1prime'; compiler = (Join-Path $OutDir 'gen1prime.exe') },
        @{ name = 'gen3'; by = 'gen2'; compiler = (Join-Path $OutDir 'gen2.exe') }
    )
    $gens = @()
    foreach ($g in $chain) {
        $out = Join-Path $OutDir "$($g.name).exe"
        Assert-Fresh $out
        Write-Step "$($g.by) builds $($g.name)"
        $t0 = Get-Date; $s0 = Get-UtcStamp
        $r = Invoke-EleImage $g.compiler @('build', $DriverSource, '--target', $Target, '--output', $out) $RepoRoot "build-$($g.name)"
        $secs = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
        if ($r.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $out)) {
            throw "$($g.by) failed to build $($g.name) (exit $($r.ExitCode)): $($r.Stderr)"
        }
        $head = [IO.File]::ReadAllBytes($out)
        if ($head.Length -lt 2 -or $head[0] -ne 0x4D -or $head[1] -ne 0x5A) { throw "$($g.name) is not a PE image (no MZ)" }
        $sha = Get-Sha256 $out
        Write-Host "    $($g.name) sha256 $sha ($($head.Length) bytes, $secs s)"
        $gens += [ordered]@{ name = $g.name; built_by = $g.by; file = "$($g.name).exe"; sha256 = $sha; size = $head.Length; started_utc = $s0; finished_utc = Get-UtcStamp; seconds = $secs }
        $state.generations = $gens
    }

    # Fixpoint.
    $g1 = $gens[0].sha256; $g2 = $gens[1].sha256; $g3 = $gens[2].sha256
    $equal = Compare-Bytes ([IO.File]::ReadAllBytes((Join-Path $OutDir 'gen2.exe'))) ([IO.File]::ReadAllBytes((Join-Path $OutDir 'gen3.exe')))
    $state.fixpoint = [ordered]@{ gen2_sha256 = $g2; gen3_sha256 = $g3; gen2_equals_gen3 = $equal; gen1prime_equals_gen2 = ($g1 -eq $g2) }
    Write-Step 'fixpoint check Gen2 == Gen3'
    Write-Host "    gen2 $g2"
    Write-Host "    gen3 $g3"
    if (-not $equal) {
        $report = Get-DiffReport (Join-Path $OutDir 'gen2.exe') (Join-Path $OutDir 'gen3.exe')
        $state.fixpoint['difference'] = $report
        Write-Host "    sizes: gen2 $($report.size_a) bytes, gen3 $($report.size_b) bytes; differing bytes in common prefix: $($report.differing_bytes_common)"
        $report.first_differences | ForEach-Object { Write-Host "    $_" }
        throw 'NOT A FIXPOINT: Gen2 and Gen3 differ bitwise (see differences above and provenance.json)'
    }
    Write-Host "    BITWISE EQUAL (gen1prime == gen2: $($g1 -eq $g2))"
    $gen3 = Join-Path $OutDir 'gen3.exe'

    # Smoke set: exact stdout bytes and exit codes.
    $smokeRoot = Join-Path $RepoRoot 'scripts/bootstrap/smoke'
    $smokeFailures = 0
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $smokeRoot 'cases.txt'))) {
        if ($line -match '^\s*(#|$)') { continue }
        $name, $src, $exp = $line.Split('|')
        $exe = Join-Path $SmokeDir "$name.exe"
        Assert-Fresh $exe
        Write-Step "smoke $name ($src)"
        $b = Invoke-EleImage $gen3 @('build', $src, '--target', $Target, '--output', $exe) $RepoRoot "smoke-build-$name"
        $entry = [ordered]@{ name = $name; source = $src; build_exit = $b.ExitCode; expected_exit = [int]$exp; actual_exit = $null; stdout_match = $false; ok = $false }
        if ($b.ExitCode -eq 0 -and (Test-Path -LiteralPath $exe)) {
            $run = Invoke-EleImage $exe @() $SmokeDir "smoke-run-$name"
            $want = [IO.File]::ReadAllBytes((Join-Path $smokeRoot "expected/$name.stdout"))
            $entry.actual_exit = $run.ExitCode
            $entry.stdout_match = Compare-Bytes $run.Stdout $want
            $entry.ok = $entry.stdout_match -and ($run.ExitCode -eq [int]$exp)
        } else {
            Write-Host "    build failed: $($b.Stderr)"
        }
        Write-Host ("    exit {0} (want {1}), stdout {2} -> {3}" -f $entry.actual_exit, $exp, $(if ($entry.stdout_match) { 'match' } else { 'MISMATCH' }), $(if ($entry.ok) { 'ok' } else { 'FAIL' }))
        if (-not $entry.ok) { $smokeFailures++ }
        $state.smoke = @($state.smoke) + $entry
    }

    # Programs Gen3 must reject.
    $rejectFailures = 0
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $smokeRoot 'reject.txt'))) {
        if ($line -match '^\s*(#|$)') { continue }
        $name, $src, $exp, $needle = $line.Split('|')
        $exe = Join-Path $SmokeDir "reject-$name.exe"
        Assert-Fresh $exe
        Write-Step "reject $name ($src)"
        $b = Invoke-EleImage $gen3 @('build', $src, '--target', $Target, '--output', $exe) $RepoRoot "reject-$name"
        $wrote = Test-Path -LiteralPath $exe
        $hasCode = $b.Stderr.Contains($needle)
        $ok = ($b.ExitCode -eq [int]$exp) -and $hasCode -and -not $wrote
        Write-Host ("    exit {0} (want {1}), stderr has {2}: {3}, image written: {4} -> {5}" -f $b.ExitCode, $exp, $needle, $hasCode, $wrote, $(if ($ok) { 'ok' } else { 'FAIL' }))
        if (-not $ok) { $rejectFailures++ }
        $state.reject = @($state.reject) + [ordered]@{ name = $name; source = $src; expected_exit = [int]$exp; actual_exit = $b.ExitCode; required_stderr = $needle; stderr_matched = $hasCode; image_written = $wrote; ok = $ok }
    }
    if (@($state.smoke).Count -eq 0 -or @($state.reject).Count -eq 0) { throw 'smoke or reject manifest is empty' }
    if ($smokeFailures -or $rejectFailures) { throw "smoke failures: $smokeFailures, reject failures: $rejectFailures" }

    # Manifest of produced images.
    $sums = New-Object System.Text.StringBuilder
    foreach ($f in @('seed.exe', 'gen1prime.exe', 'gen2.exe', 'gen3.exe')) {
        [void]$sums.Append("$(Get-Sha256 (Join-Path $OutDir $f))  $f`n")
    }
    $sumsPath = Join-Path $OutDir 'SHA256SUMS'
    Assert-Fresh $sumsPath
    [IO.File]::WriteAllText($sumsPath, $sums.ToString(), $Utf8NoBom)

    $state.status = 'ok'
    $exitCode = 0
    Write-Step "OK: Stage-0-free chain seed -> gen1prime -> gen2 -> gen3 is a bitwise fixpoint ($g3)"
} catch {
    $state.failure = "$($_.Exception.Message)"
    Write-Host "BOOTSTRAP FAILED: $($state.failure)" -ForegroundColor Red
} finally {
    Save-Provenance
    Write-Host "provenance: $ProvenancePath"
}
exit $exitCode
