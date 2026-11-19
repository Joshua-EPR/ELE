# scripts/stage3_native_bootstrap_probe.ps1
#
# Stage 3 native bootstrap probe: how far the ELE-written backend
# (compiler-l/src/native_cfg_demo.l) gets on the REAL compiler components.
#
#   a. Stage 0 (target/debug/l.exe, Rust + Cranelift + MSVC link.exe) builds
#      the Stage 1 tools main, main_parser, main_sema, native_cfg_demo.
#   b. Stage 1 main_sema --emit-lir emits ELE-LIR for each component, twice;
#      the SHA-256 of both runs must match.
#   c. Stage 1 native_cfg_demo compiles that LIR to ELF64. On rejection a
#      locator (a patched COPY of compiler-l/src under the output dir) names
#      the function and the exact LIR line of the first unsupported construct.
#   d. Each produced ELF runs in WSL on a real input; stdout, stderr and exit
#      code are byte-compared with the Stage-0-built Stage 1 .exe on Windows.
#   e. Generation 2/3: the native backend ELF recompiles every accepted LIR
#      (and itself, twice) and the images are compared with the Stage 1 ones.
#
# Read-only on the repository: everything is written under
# <OutputDir>/run-<timestamp> (default target/stage3-probe). The script never
# deletes or overwrites files; a run directory that already exists is an error.
# Prints a table and writes artifacts.tsv (sha256 per artifact),
# components.tsv (first blocker per component) and processes.tsv (every
# executable launched, with the child processes observed while it ran).
#
# Usage (from any directory):
#   powershell -ExecutionPolicy Bypass -File scripts/stage3_native_bootstrap_probe.ps1 `
#       [-OutputDir target/stage3-probe] [-Compiler target/debug/l.exe] `
#       [-WslDistro Ubuntu] [-NoWsl] [-NoLocator]
# Stage 0 must already be built (cargo build -p project-l --bin l); the
# probe does not run cargo.

param(
    [string] $OutputDir = '',
    [string] $Compiler = '',
    [string] $WslDistro = 'Ubuntu',
    [switch] $NoWsl,
    [switch] $NoLocator
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = Join-Path $repoRoot 'target/stage3-probe' }
if (-not [IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $repoRoot $OutputDir }
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
$srcRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'compiler-l'))
if ($OutputDir.StartsWith($srcRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDir must not be inside compiler-l: $OutputDir"
}
if ([string]::IsNullOrWhiteSpace($Compiler)) { $Compiler = Join-Path $repoRoot 'target/debug/l.exe' }
if (-not (Test-Path -LiteralPath $Compiler)) {
    throw "Stage 0 not found at $Compiler; build it first: cargo build -p project-l --bin l"
}
$Compiler = (Resolve-Path -LiteralPath $Compiler).Path

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$run = Join-Path $OutputDir "run-$stamp"
if (Test-Path -LiteralPath $run) { throw "run directory already exists (refusing to overwrite): $run" }
[IO.Directory]::CreateDirectory($run) > $null
$utf8 = New-Object System.Text.UTF8Encoding($false)

function New-Dir([string] $path) { [IO.Directory]::CreateDirectory($path) > $null; return $path }
function Assert-Fresh([string] $path) {
    if (Test-Path -LiteralPath $path) { throw "refusing to overwrite existing file: $path" }
}
function Get-Sha([string] $path) {
    if (-not (Test-Path -LiteralPath $path)) { return '-' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
}
function Test-SameBytes([string] $a, [string] $b) {
    if (-not (Test-Path -LiteralPath $a) -or -not (Test-Path -LiteralPath $b)) { return $false }
    return (Get-Sha $a) -eq (Get-Sha $b)
}
function ConvertTo-WslPath([string] $path) {
    $full = [IO.Path]::GetFullPath($path) -replace '\\', '/'
    return '/mnt/' + $full.Substring(0, 1).ToLowerInvariant() + $full.Substring(2)
}
function Get-Rel([string] $path) {
    $full = [IO.Path]::GetFullPath($path)
    if ($full.StartsWith($repoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return ($full.Substring($repoRoot.Length).TrimStart('\', '/') -replace '\\', '/')
    }
    return $full
}

# ---------------------------------------------------------------- tracing --
$processLog = New-Object System.Collections.Generic.List[string]
$processLog.Add("stage`tcomponent`texecutable`targuments`texit`tms`tchildren_observed")
$artifacts = New-Object System.Collections.Generic.List[string]
$artifacts.Add("component`tartifact`tpath`tsha256`tbytes")

function Add-Artifact([string] $component, [string] $kind, [string] $path) {
    $size = if (Test-Path -LiteralPath $path) { (Get-Item -LiteralPath $path).Length } else { 0 }
    $artifacts.Add("$component`t$kind`t$(Get-Rel $path)`t$(Get-Sha $path)`t$size")
}

# Descendants of $rootId currently alive (one process snapshot).
function Get-Descendants([int] $rootId) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, ExecutablePath -ErrorAction SilentlyContinue)
    $ids = @{ $rootId = $true }
    $found = @()
    $grew = $true
    while ($grew) {
        $grew = $false
        foreach ($p in $all) {
            if ($ids.ContainsKey([int]$p.ParentProcessId) -and -not $ids.ContainsKey([int]$p.ProcessId)) {
                $ids[[int]$p.ProcessId] = $true
                $path = if ($p.ExecutablePath) { $p.ExecutablePath } else { $p.Name }
                $found += $path
                $grew = $true
            }
        }
    }
    return $found
}

# Runs $exe with $arguments in $cwd; stdout/stderr are copied byte for byte
# to $stdoutPath/$stderrPath. Returns @{ Exit; Ms; Children }.
function Invoke-Traced([string] $stage, [string] $component, [string] $exe, [string[]] $arguments,
                       [string] $cwd, [string] $stdoutPath, [string] $stderrPath, [switch] $Watch) {
    Assert-Fresh $stdoutPath
    Assert-Fresh $stderrPath
    $quoted = @($arguments | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($quoted -join ' ')
    $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $out = [IO.File]::Create($stdoutPath)
    $err = [IO.File]::Create($stderrPath)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $t1 = $p.StandardOutput.BaseStream.CopyToAsync($out)
    $t2 = $p.StandardError.BaseStream.CopyToAsync($err)
    $children = @{}
    while (-not $p.HasExited) {
        if ($Watch) { foreach ($c in (Get-Descendants $p.Id)) { $children[$c] = $true } }
        Start-Sleep -Milliseconds 50
    }
    $p.WaitForExit()
    $t1.Wait(); $t2.Wait()
    $out.Close(); $err.Close()
    $clock.Stop()
    $names = (@($children.Keys) | Sort-Object) -join ';'
    if (-not $names) { $names = '-' }
    $processLog.Add("$stage`t$component`t$exe`t$($arguments -join ' ')`t$($p.ExitCode)`t$($clock.ElapsedMilliseconds)`t$names")
    return @{ Exit = $p.ExitCode; Ms = $clock.ElapsedMilliseconds; Children = $names }
}

# Runs an ELF64 image in WSL from the repository root (same relative
# arguments as the Windows run); stdout/stderr/exit land in files. The
# streams go to a private Linux temp dir first and are copied afterwards:
# the native runtime writes unbuffered (two write(2) per printed line), and
# each write to /mnt/c costs a 9P round trip.
$runSh = Join-Path $run 'wsl-run.sh'
$runShText = @'
#!/bin/sh
# usage: wsl-run.sh <elf> <stdout> <stderr> <exitfile> <args...>
elf="$1"; out="$2"; err="$3"; code="$4"; shift 4
tmp=$(mktemp -d)
cp "$elf" "$tmp/prog" && chmod 700 "$tmp/prog"
start=$(date +%s%N)
"$tmp/prog" "$@" > "$tmp/out" 2> "$tmp/err"
status=$?
end=$(date +%s%N)
cp "$tmp/out" "$out"; cp "$tmp/err" "$err"
echo "$status $(( (end - start) / 1000000 ))" > "$code"
# The temp dir is left in place: the probe never deletes anything.
'@
[IO.File]::WriteAllText($runSh, ($runShText -replace "`r`n", "`n"), $utf8)
function Invoke-Elf([string] $stage, [string] $component, [string] $elf, [string[]] $arguments,
                    [string] $stdoutPath, [string] $stderrPath) {
    Assert-Fresh $stdoutPath
    Assert-Fresh $stderrPath
    $codeFile = "$stdoutPath.exit"
    Assert-Fresh $codeFile
    $wslArgs = @((ConvertTo-WslPath $elf), (ConvertTo-WslPath $stdoutPath), (ConvertTo-WslPath $stderrPath), (ConvertTo-WslPath $codeFile)) + $arguments
    $cmd = "cd '$(ConvertTo-WslPath $repoRoot)' && sh '$(ConvertTo-WslPath $runSh)' " + (($wslArgs | ForEach-Object { "'$_'" }) -join ' ')
    $r = Invoke-Traced $stage $component 'wsl.exe' @('-d', $WslDistro, '--exec', 'sh', '-c', $cmd) $repoRoot "$stdoutPath.wsl" "$stderrPath.wsl"
    $exit = $null
    $ms = $null
    if (Test-Path -LiteralPath $codeFile) {
        $fields = ([IO.File]::ReadAllText($codeFile)).Trim() -split '\s+'
        $exit = [int]$fields[0]
        if ($fields.Count -gt 1) { $ms = [long]$fields[1] }
    }
    # Ms: time of the ELF itself inside Linux; WslMs: including wsl.exe.
    return @{ Exit = $exit; Ms = $ms; WslMs = $r.Ms; WslExit = $r.Exit }
}

# ------------------------------------------------------- environment info --
$toolInfo = New-Object System.Collections.Generic.List[string]
$toolInfo.Add("stage0_compiler`t$Compiler`t$(Get-Sha $Compiler)")
foreach ($tool in @('rustc', 'cargo')) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if ($cmd) {
        $v = Invoke-Traced 'env' '-' $cmd.Source @('-V') $repoRoot (Join-Path $run "$tool-version.out") (Join-Path $run "$tool-version.err")
        $toolInfo.Add("$tool`t$($cmd.Source)`t$(([IO.File]::ReadAllText((Join-Path $run "$tool-version.out"))).Trim())")
    }
}
$lockText = [IO.File]::ReadAllText((Join-Path $repoRoot 'Cargo.lock'))
$cl = [regex]::Match($lockText, 'name = "cranelift-codegen"\r?\nversion = "([^"]+)"')
$toolInfo.Add("cranelift-codegen (Cargo.lock)`t-`t$(if ($cl.Success) { $cl.Groups[1].Value } else { 'not found' })")
if ($env:L_LINKER) {
    $toolInfo.Add("link.exe (L_LINKER)`t$env:L_LINKER`t-")
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path -LiteralPath $vswhere) {
        $r = Invoke-Traced 'env' '-' $vswhere @('-latest', '-products', '*', '-prerelease', '-requires', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath') $repoRoot (Join-Path $run 'vswhere.out') (Join-Path $run 'vswhere.err')
        $vs = ([IO.File]::ReadAllText((Join-Path $run 'vswhere.out'))).Trim()
        $toolInfo.Add("visual studio (vswhere -prerelease)`t$vs`t-")
    }
}

# ------------------------------------------------------- a. Stage 0 builds --
$components = @(
    @{ Name = 'main';            Role = 'lexer';   Args = @('compiler-l/src/main_sema.l') },
    @{ Name = 'main_parser';     Role = 'parser';  Args = @('compiler-l/src/main_parser.l') },
    @{ Name = 'main_sema';       Role = 'sema';    Args = @('compiler-l/src/main_sema.l', '--emit-lir') },
    @{ Name = 'native_cfg_demo'; Role = 'backend'; Args = @() }
)
$stage1 = @{}
Write-Host "Stage 3 native bootstrap probe -> $(Get-Rel $run)"
foreach ($c in $components) {
    $dir = New-Dir (Join-Path $run "stage1-build/$($c.Name)")
    $src = Join-Path $repoRoot "compiler-l/src/$($c.Name).l"
    $r = Invoke-Traced 'a:stage0-build' $c.Name $Compiler @('build', $src, '--backend', 'cranelift') $dir (Join-Path $dir 'build.out') (Join-Path $dir 'build.err') -Watch
    if ($r.Exit -ne 0) { throw "Stage 0 failed to build $($c.Name) (exit $($r.Exit)); see $dir" }
    $line = @([IO.File]::ReadAllLines((Join-Path $dir 'build.out')) | Where-Object { $_ -like 'Build: *' })[0]
    $exe = (Resolve-Path -LiteralPath (Join-Path $dir $line.Substring(7))).Path
    $stage1[$c.Name] = $exe
    Add-Artifact $c.Name 'stage1-exe(windows)' $exe
    Write-Host ("  a  {0,-16} Stage 0 build ok ({1} ms) children: {2}" -f $c.Name, $r.Ms, $r.Children)
}

# ----------------------------------------------------------- locator copy --
$locator = $null
if (-not $NoLocator) {
    $locSrc = Join-Path $run 'locator-src'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'compiler-l/src') -Destination $locSrc -Recurse
    $verify = Join-Path $locSrc 'codegen/native_cfg_verify.l'
    $text = [IO.File]::ReadAllText($verify)
    $text = $text -replace '(?m)^flow cfgCheckCalls\(', 'expose flow cfgCheckCalls(' -replace '(?m)^flow cfgCheckFunction\(', 'expose flow cfgCheckFunction('
    [IO.File]::WriteAllText($verify, $text, $utf8)
    $entry = @'
import codegen.native_cfg_emit
take codegen.native_cfg_ir
take codegen.native_cfg_verify
take codegen.native_cfg_loan

// Probe-only locator (a copy outside compiler-l/src): parse, verify and
// build an ELE-LIR file and report where the backend stops.
fn main() -> Int {
    match processArg(0) {
        Ok(path) => {
            match readText(path, cfgMaxSource()) {
                Ok(source) => {
                    hold p = cfgParse(view source)
                    let e = p.error
                    let nf = p.functions.length
                    let nb = p.blocks.length
                    let ni = p.insts.length
                    print("parse_error={e} funcs_parsed={nf} blocks_parsed={nb} insts_parsed={ni}")
                    if e != 0 { return 1 }
                    let calls = cfgCheckCalls(view p)
                    print("check_calls={calls}")
                    if calls != 0 { return 1 }
                    each f among 0..p.functions.length {
                        hold modes = cfgCheckLoanModes(view p, f)
                        when modes != 0 {
                            print("loan_modes_error={modes} func={f}")
                            give 1
                        }
                        hold r = cfgCheckFunction(view p, f)
                        when r != 0 {
                            print("check_function_error={r} func={f}")
                            give 1
                        }
                    }
                    hold img = cfgBuildFor(view p, 0)
                    let be = img.error
                    print("build_error={be}")
                    return 0
                }
                Err(code) => { return 4 }
            }
        }
        Err(code) => { return 6 }
    }
}
'@
    [IO.File]::WriteAllText((Join-Path $locSrc 'probe_cfg_locate.l'), $entry, $utf8)
    $dir = New-Dir (Join-Path $run 'stage1-build/probe_cfg_locate')
    $r = Invoke-Traced 'locator:stage0-build' 'probe_cfg_locate' $Compiler @('build', (Join-Path $locSrc 'probe_cfg_locate.l'), '--backend', 'cranelift') $dir (Join-Path $dir 'build.out') (Join-Path $dir 'build.err') -Watch
    if ($r.Exit -eq 0) {
        $line = @([IO.File]::ReadAllLines((Join-Path $dir 'build.out')) | Where-Object { $_ -like 'Build: *' })[0]
        $locator = (Resolve-Path -LiteralPath (Join-Path $dir $line.Substring(7))).Path
    } else {
        Write-Host "  locator build failed (exit $($r.Exit)); rejections will report codes only"
    }
}

function Get-DecodedName([string] $encoded) {
    $parts = $encoded.Split(':', 2)
    if ($parts.Count -ne 2) { return $encoded }
    return -join ($parts[1].Split(',') | ForEach-Object { [char][int]$_ })
}

# Exact LIR line of the first rejected construct, from the locator counters.
function Find-Blocker([string] $component, [string] $lir) {
    if (-not $locator) { return @{ Where = 'locator unavailable'; Line = '-' } }
    $base = Join-Path $run "locate-$component"
    Invoke-Traced 'c:locate' $component $locator @($lir) $repoRoot "$base.out" "$base.err" > $null
    $report = ([IO.File]::ReadAllText("$base.out")).Trim()
    $lines = [IO.File]::ReadAllLines($lir)
    $m = [regex]::Match($report, 'parse_error=(\d+) funcs_parsed=(\d+) blocks_parsed=(\d+) insts_parsed=(\d+)')
    if ($m.Success -and $m.Groups[1].Value -ne '0') {
        $func = [int]$m.Groups[2].Value - 1
        $want = [int]$m.Groups[4].Value
        $seen = 0; $funcLine = '-'
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i].StartsWith("func f$func ")) { $funcLine = $lines[$i] }
            if ($lines[$i].StartsWith('i ')) {
                if ($seen -eq $want) {
                    $fname = Get-DecodedName (($funcLine -split ' ')[2])
                    return @{ Where = "parse code $($m.Groups[1].Value) in f$func ($fname), LIR line $($i + 1)"; Line = $lines[$i] }
                }
                $seen++
            }
        }
        return @{ Where = "parse code $($m.Groups[1].Value) in f$func (header, block or terminator)"; Line = $report }
    }
    $v = [regex]::Match($report, '(check_function_error|loan_modes_error)=(\d+) func=(\d+)')
    if ($v.Success) {
        $f = $v.Groups[3].Value
        $hdr = @($lines | Where-Object { $_.StartsWith("func f$f ") })[0]
        return @{ Where = "verify code $($v.Groups[2].Value) in f$f ($(Get-DecodedName (($hdr -split ' ')[2])))"; Line = $hdr }
    }
    return @{ Where = $report -replace '\r?\n', ' | '; Line = '-' }
}

# ------------------------------------------- b./c./d. per component --------
$rows = @()
$sema = $stage1['main_sema']
$backend = $stage1['native_cfg_demo']
$nativeBackendElf = $null
foreach ($c in $components) {
    $name = $c.Name
    $dir = New-Dir (Join-Path $run "components/$name")
    $row = [ordered]@{ Component = $name; LirSha = '-'; LirStable = '-'; Backend = '-'; ElfSha = '-'; Exec = 'not run'; Gen2 = 'not run'; Blocker = '-'; BlockerLine = '-' }

    # b. LIR, twice.
    $lir = Join-Path $dir "$name.lir"
    $r1 = Invoke-Traced 'b:emit-lir' $name $sema @("compiler-l/src/$name.l", '--emit-lir') $repoRoot $lir (Join-Path $dir 'emit1.err')
    $r2 = Invoke-Traced 'b:emit-lir' $name $sema @("compiler-l/src/$name.l", '--emit-lir') $repoRoot (Join-Path $dir "$name.run2.lir") (Join-Path $dir 'emit2.err')
    Add-Artifact $name 'lir(run1)' $lir
    Add-Artifact $name 'lir(run2)' (Join-Path $dir "$name.run2.lir")
    $row.LirSha = Get-Sha $lir
    $row.LirStable = if ($r1.Exit -eq 0 -and $r2.Exit -eq 0 -and (Test-SameBytes $lir (Join-Path $dir "$name.run2.lir"))) { 'yes' } else { "no (exit $($r1.Exit)/$($r2.Exit))" }
    if ($r1.Exit -ne 0) { $row.Blocker = "sema --emit-lir exit $($r1.Exit)"; $rows += [pscustomobject]$row; continue }

    # c. ELE backend (Stage 1, Windows) -> ELF64.
    $elf = Join-Path $dir "$name.elf"
    $rb = Invoke-Traced 'c:ele-backend' $name $backend @($lir, $elf) $repoRoot (Join-Path $dir 'backend.out') (Join-Path $dir 'backend.err')
    if ($rb.Exit -ne 0 -or -not (Test-Path -LiteralPath $elf)) {
        $msg = ([IO.File]::ReadAllText((Join-Path $dir 'backend.err'))).Trim()
        $row.Backend = "rejected exit $($rb.Exit): $msg"
        $where = Find-Blocker $name $lir
        $row.Blocker = $where.Where
        $row.BlockerLine = $where.Line.Trim()
        $rows += [pscustomobject]$row
        continue
    }
    $row.Backend = 'ELF64'
    $row.ElfSha = Get-Sha $elf
    Add-Artifact $name 'elf(stage1-backend)' $elf
    if ($name -eq 'native_cfg_demo') { $nativeBackendElf = $elf }

    # d. Run the ELF on a real input and compare with the Windows Stage 1 exe.
    if ($NoWsl) { $row.Exec = 'skipped (-NoWsl)' }
    elseif ($name -ne 'native_cfg_demo') {
        $win = Invoke-Traced 'd:stage1-exe' $name $stage1[$name] $c.Args $repoRoot (Join-Path $dir 'win.out') (Join-Path $dir 'win.err')
        $nat = Invoke-Elf 'd:native-elf' $name $elf $c.Args (Join-Path $dir 'elf.out') (Join-Path $dir 'elf.err')
        Add-Artifact $name 'stdout(windows-stage1)' (Join-Path $dir 'win.out')
        Add-Artifact $name 'stdout(native-elf)' (Join-Path $dir 'elf.out')
        $same = ($win.Exit -eq $nat.Exit) -and (Test-SameBytes (Join-Path $dir 'win.out') (Join-Path $dir 'elf.out')) -and (Test-SameBytes (Join-Path $dir 'win.err') (Join-Path $dir 'elf.err'))
        $row.Exec = "{0} on '{1}' (exit win {2} / elf {3}; {4} ms / {5} ms)" -f ($(if ($same) { 'IDENTICAL' } else { 'DIFFERENT' }), ($c.Args -join ' '), $win.Exit, $nat.Exit, $win.Ms, $nat.Ms)
    }
    $rows += [pscustomobject]$row
}

# ------------------------------------------- d./e. native backend generations
if ($nativeBackendElf -and -not $NoWsl) {
    $gdir = New-Dir (Join-Path $run 'generations')
    foreach ($row in $rows) {
        $name = $row.Component
        $lir = Join-Path $run "components/$name/$name.lir"
        if (-not (Test-Path -LiteralPath $lir)) { continue }
        $out = Join-Path $gdir "$name.gen2.elf"
        $g = Invoke-Elf 'e:native-backend-gen2' $name $nativeBackendElf @((Get-Rel $lir), (Get-Rel $out)) (Join-Path $gdir "$name.gen2.out") (Join-Path $gdir "$name.gen2.err")
        $stage1Elf = Join-Path $run "components/$name/$name.elf"
        if (Test-Path -LiteralPath $out) {
            Add-Artifact $name 'elf(native-backend gen2)' $out
            $verdict = if (Test-SameBytes $out $stage1Elf) { 'IDENTICAL to Stage 1 backend image' } else { 'DIFFERENT from Stage 1 backend image' }
            $row.Gen2 = "native backend exit $($g.Exit): $verdict ($($g.Ms) ms)"
        } else {
            $err = ([IO.File]::ReadAllText((Join-Path $gdir "$name.gen2.err"))).Trim()
            $row.Gen2 = "native backend exit $($g.Exit), no image: $err"
        }
        if ($name -eq 'native_cfg_demo' -and (Test-Path -LiteralPath $out)) {
            # Generation 3: the gen2 backend rebuilds itself.
            $out3 = Join-Path $gdir 'native_cfg_demo.gen3.elf'
            $g3 = Invoke-Elf 'e:native-backend-gen3' $name $out @((Get-Rel $lir), (Get-Rel $out3)) (Join-Path $gdir 'gen3.out') (Join-Path $gdir 'gen3.err')
            Add-Artifact $name 'elf(native-backend gen3)' $out3
            $row.Gen2 += "; gen3 exit $($g3.Exit): " + $(if (Test-SameBytes $out $out3) { 'FIXPOINT (gen2 == gen3)' } else { 'gen2 != gen3' })
        }
        if ($name -eq 'main_parser' -and (Test-Path -LiteralPath $out)) { $row.Exec += '; also compiled by the native backend (see Gen2)' }
    }
    # d. for the backend itself: its ELF compiling another component's LIR
    # must reproduce the Windows Stage 1 backend's image byte for byte.
    $nrow = $rows | Where-Object { $_.Component -eq 'native_cfg_demo' }
    $prow = $rows | Where-Object { $_.Component -eq 'main_parser' }
    if ($nrow -and $prow -and $prow.Gen2 -ne 'not run') {
        $nrow.Exec = "native backend ELF on main_parser.lir: $($prow.Gen2)"
    }
}

# ---------------------------------------------------------------- outputs --
$comp = New-Object System.Collections.Generic.List[string]
$comp.Add("component`tlir_sha256`tlir_stable`tbackend`telf_sha256`texec_vs_reference`tgeneration2`tfirst_blocker`tfirst_blocker_lir_line")
foreach ($row in $rows) {
    $comp.Add(($row.Component, $row.LirSha, $row.LirStable, $row.Backend, $row.ElfSha, $row.Exec, $row.Gen2, $row.Blocker, $row.BlockerLine) -join "`t")
}
[IO.File]::WriteAllLines((Join-Path $run 'components.tsv'), $comp, $utf8)
[IO.File]::WriteAllLines((Join-Path $run 'artifacts.tsv'), $artifacts, $utf8)
[IO.File]::WriteAllLines((Join-Path $run 'processes.tsv'), $processLog, $utf8)
[IO.File]::WriteAllLines((Join-Path $run 'toolchain.tsv'), $toolInfo, $utf8)

Write-Host ''
Write-Host 'Toolchain (Stage 0):'
$toolInfo | ForEach-Object { Write-Host "  $_" }
Write-Host ''
$rows | Format-List | Out-String -Width 400 | Write-Host
Write-Host 'Executables launched:'
$processLog | Select-Object -Skip 1 | ForEach-Object { $f = $_ -split "`t"; "{0}|{1}|{2}|children={3}" -f $f[0], (Split-Path -Leaf $f[2]), $f[4], $f[6] } | Group-Object | ForEach-Object { Write-Host ("  {0,3}x {1}" -f $_.Count, $_.Name) }
Write-Host ''
Write-Host "Wrote $(Get-Rel (Join-Path $run 'components.tsv')), artifacts.tsv, processes.tsv, toolchain.tsv"
