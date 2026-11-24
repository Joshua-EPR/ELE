<#
.SYNOPSIS
  Native conformance corpus runner for Windows PE32+ images.

.DESCRIPTION
  Needs ONLY an ELE compiler binary that implements
  `<compiler> build <file.l> --target pe --output <path>` (the ELE-written
  driver compiler-l/src/main_driver.l). No cargo, rustc or Stage 0.

  Positive case  <name>.l + <name>.stdout + <name>.exit (corpus root):
    compiled, executed with stdin at EOF (a pipe closed before the program
    starts) and a timeout, in a fresh temporary working directory; stdout
    must equal <name>.stdout byte for byte and the exit status must equal
    <name>.exit.
  Reject case    reject/<name>.l + reject/<name>.diag:
    the compiler must exit non-zero, print every non-empty line of
    <name>.diag (stdout + stderr, decoded as UTF-8) and produce no output.
  Known gaps     known_gaps.txt lists `<case> <targets>` (targets: pe, elf
    or all, comma separated). A listed case that fails is XFAIL; one that
    passes is XPASS and fails the run, so a fixed gap must be unlisted.

  Nothing is normalized: stdout is compared as raw bytes. Expected files are
  stored with LF line ends and tests/native_corpus/.gitattributes disables
  end-of-line conversion, and the ELE runtimes write LF on every target, so
  no CRLF -> LF rewriting is needed or performed.

  Exit status: 0 when every case is PASS or XFAIL; 1 otherwise; 2 on usage
  or corpus layout errors.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tests/native_corpus/run.ps1 path\to\ele.exe
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Compiler,
    [string]$Corpus = '',
    [string[]]$Case = @(),
    [int]$TimeoutSeconds = 20,
    [int]$CompileTimeoutSeconds = 300,
    [switch]$KeepTemp
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$Target = 'pe'
if ($Corpus -eq '') { $Corpus = Split-Path -Parent $MyInvocation.MyCommand.Path }
# `-File` passes `-Case a,b` as one string: accept comma-separated names.
$Case = @($Case | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

function Fail-Usage([string]$message) {
    [Console]::Error.WriteLine("run.ps1: $message")
    exit 2
}

if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) { Fail-Usage "compiler not found: $Compiler" }
$Compiler = (Resolve-Path -LiteralPath $Compiler).Path
if (-not (Test-Path -LiteralPath $Corpus -PathType Container)) { Fail-Usage "corpus not found: $Corpus" }
$Corpus = (Resolve-Path -LiteralPath $Corpus).Path

# Quote one argument with the rules of CommandLineToArgvW / the MSVC runtime.
function Quote-Argument([string]$value) {
    $escaped = [regex]::Replace($value, '(\\*)"', { param($m) $m.Groups[1].Value * 2 + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

# Runs a process with stdin at EOF, captures raw stdout/stderr bytes and kills
# it after $timeoutSeconds.
function Invoke-Limited([string]$file, [string[]]$arguments, [string]$cwd, [int]$timeoutSeconds) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $file
    $psi.Arguments = (($arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $psi.WorkingDirectory = $cwd
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()
    $stdout = New-Object System.IO.MemoryStream
    $stderr = New-Object System.IO.MemoryStream
    $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $copyErr = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $timedOut = $false
    if (-not $process.WaitForExit($timeoutSeconds * 1000)) {
        $timedOut = $true
        try { $process.Kill() } catch { }
        $process.WaitForExit()
    }
    [void]$copyOut.Wait(10000)
    [void]$copyErr.Wait(10000)
    $result = [pscustomobject]@{
        Code     = $process.ExitCode
        Stdout   = $stdout.ToArray()
        Stderr   = $stderr.ToArray()
        TimedOut = $timedOut
    }
    $process.Dispose()
    return $result
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
function Get-Text([byte[]]$bytes) { return $utf8.GetString($bytes) }
function First-Line([string]$text) {
    foreach ($line in ($text -split "`n")) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -gt 0) { return $trimmed }
    }
    return ''
}
function Bytes-Equal([byte[]]$a, [byte[]]$b) {
    if ($a.Length -ne $b.Length) { return $false }
    for ($i = 0; $i -lt $a.Length; $i++) { if ($a[$i] -ne $b[$i]) { return $false } }
    return $true
}
function Describe-Difference([byte[]]$expected, [byte[]]$actual) {
    $limit = [Math]::Min($expected.Length, $actual.Length)
    $at = $limit
    for ($i = 0; $i -lt $limit; $i++) { if ($expected[$i] -ne $actual[$i]) { $at = $i; break } }
    $line = 1
    for ($i = 0; $i -lt $at; $i++) { if ($expected[$i] -eq 10) { $line++ } }
    $e = (Get-Text $expected).Split("`n")
    $g = (Get-Text $actual).Split("`n")
    $el = if ($line -le $e.Length) { $e[$line - 1] } else { '<eof>' }
    $gl = if ($line -le $g.Length) { $g[$line - 1] } else { '<eof>' }
    return "stdout differs at byte $at (line $line): expected '$el' got '$gl' ($($expected.Length) vs $($actual.Length) bytes)"
}

# ---- corpus layout ---------------------------------------------------------
$layoutErrors = New-Object System.Collections.Generic.List[string]
$positive = @()
foreach ($source in (Get-ChildItem -LiteralPath $Corpus -Filter '*.l' -File | Sort-Object Name)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($source.Name)
    $stdoutFile = Join-Path $Corpus "$name.stdout"
    $exitFile = Join-Path $Corpus "$name.exit"
    if (-not (Test-Path -LiteralPath $stdoutFile) -or -not (Test-Path -LiteralPath $exitFile)) {
        $layoutErrors.Add("$($source.Name): a positive case needs $name.stdout and $name.exit")
        continue
    }
    $positive += $name
}
$rejectDir = Join-Path $Corpus 'reject'
$reject = @()
if (Test-Path -LiteralPath $rejectDir) {
    foreach ($source in (Get-ChildItem -LiteralPath $rejectDir -Filter '*.l' -File | Sort-Object Name)) {
        $name = [System.IO.Path]::GetFileNameWithoutExtension($source.Name)
        if (-not (Test-Path -LiteralPath (Join-Path $rejectDir "$name.diag"))) {
            $layoutErrors.Add("reject/$($source.Name): a reject case needs $name.diag")
            continue
        }
        $reject += $name
    }
}
$gaps = @{}
$gapFile = Join-Path $Corpus 'known_gaps.txt'
if (Test-Path -LiteralPath $gapFile) {
    foreach ($raw in [System.IO.File]::ReadAllLines($gapFile)) {
        $line = ($raw -replace '#.*$', '').Trim()
        if ($line.Length -eq 0) { continue }
        $fields = $line -split '\s+'
        if ($fields.Count -ne 2) { $layoutErrors.Add("known_gaps.txt: malformed line '$raw'"); continue }
        $known = ($positive -contains $fields[0]) -or ($fields[0] -like 'reject/*' -and $reject -contains $fields[0].Substring(7))
        if (-not $known) { $layoutErrors.Add("known_gaps.txt: unknown case '$($fields[0])'"); continue }
        $targets = $fields[1].Split(',')
        foreach ($t in $targets) {
            if (@('pe', 'elf', 'all') -notcontains $t) { $layoutErrors.Add("known_gaps.txt: unknown target '$t' in '$raw'") }
        }
        if (($targets -contains 'all') -or ($targets -contains $Target)) { $gaps[$fields[0]] = $true }
    }
}
if ($layoutErrors.Count -gt 0) {
    foreach ($e in $layoutErrors) { [Console]::Error.WriteLine("run.ps1: $e") }
    exit 2
}
if ($Case.Count -gt 0) {
    $positive = @($positive | Where-Object { $Case -contains $_ })
    $reject = @($reject | Where-Object { $Case -contains "reject/$_" })
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("ele-native-corpus-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $work | Out-Null

$rows = New-Object System.Collections.Generic.List[object]
function Add-Row([string]$name, [string]$kind, [bool]$passed, [string]$detail) {
    $gap = $gaps.ContainsKey($name)
    $result = if ($gap) { if ($passed) { 'XPASS' } else { 'XFAIL' } } else { if ($passed) { 'PASS' } else { 'FAIL' } }
    if ($result -eq 'XPASS') { $detail = 'listed in known_gaps.txt but passes: remove it from the list' }
    $detail = $detail.Replace($Corpus + [System.IO.Path]::DirectorySeparatorChar, '')
    $rows.Add([pscustomobject]@{ Case = $name; Kind = $kind; Result = $result; Detail = $detail })
}

foreach ($name in $positive) {
    $dir = Join-Path $work $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $image = Join-Path $dir "$name.exe"
    $source = Join-Path $Corpus "$name.l"
    $build = Invoke-Limited $Compiler @('build', $source, '--target', $Target, '--output', $image) $dir $CompileTimeoutSeconds
    if ($build.TimedOut) { Add-Row $name 'run' $false "compile timed out after $CompileTimeoutSeconds s"; continue }
    if ($build.Code -ne 0 -or -not (Test-Path -LiteralPath $image)) {
        $why = First-Line ((Get-Text $build.Stderr) + "`n" + (Get-Text $build.Stdout))
        Add-Row $name 'run' $false "compile exit $($build.Code): $why"
        continue
    }
    $run = Invoke-Limited $image @() $dir $TimeoutSeconds
    if ($run.TimedOut) { Add-Row $name 'run' $false "timed out after $TimeoutSeconds s"; continue }
    $expectedStdout = [System.IO.File]::ReadAllBytes((Join-Path $Corpus "$name.stdout"))
    $expectedCode = [int]::Parse(([System.IO.File]::ReadAllText((Join-Path $Corpus "$name.exit"))).Trim())
    $problems = @()
    if ($run.Code -ne $expectedCode) { $problems += "exit $($run.Code), expected $expectedCode" }
    if (-not (Bytes-Equal $expectedStdout $run.Stdout)) { $problems += (Describe-Difference $expectedStdout $run.Stdout) }
    Add-Row $name 'run' ($problems.Count -eq 0) ($problems -join '; ')
}

foreach ($name in $reject) {
    $dir = Join-Path $work "reject-$name"
    New-Item -ItemType Directory -Path $dir | Out-Null
    $image = Join-Path $dir "$name.exe"
    $source = Join-Path $rejectDir "$name.l"
    $build = Invoke-Limited $Compiler @('build', $source, '--target', $Target, '--output', $image) $dir $CompileTimeoutSeconds
    $label = "reject/$name"
    if ($build.TimedOut) { Add-Row $label 'reject' $false "compile timed out after $CompileTimeoutSeconds s"; continue }
    $text = (Get-Text $build.Stdout) + "`n" + (Get-Text $build.Stderr)
    $problems = @()
    if ($build.Code -eq 0) { $problems += 'compiler exited 0' }
    if (Test-Path -LiteralPath $image) { $problems += 'an output image was produced' }
    foreach ($raw in [System.IO.File]::ReadAllLines((Join-Path $rejectDir "$name.diag"), $utf8)) {
        $needle = $raw.TrimEnd("`r")
        if ($needle.Length -gt 0 -and -not $text.Contains($needle)) { $problems += "missing diagnostic '$needle' (got: $(First-Line $text))" }
    }
    Add-Row $label 'reject' ($problems.Count -eq 0) ($problems -join '; ')
}

# ---- report ----------------------------------------------------------------
$width = 12
foreach ($r in $rows) { if ($r.Case.Length -gt $width) { $width = $r.Case.Length } }
Write-Output ("{0}  {1,-6}  {2,-6}  {3}" -f 'CASE'.PadRight($width), 'KIND', 'RESULT', 'DETAIL')
foreach ($r in $rows) {
    Write-Output ("{0}  {1,-6}  {2,-6}  {3}" -f $r.Case.PadRight($width), $r.Kind, $r.Result, $r.Detail)
}
$count = @{ PASS = 0; FAIL = 0; XFAIL = 0; XPASS = 0 }
foreach ($r in $rows) { $count[$r.Result]++ }
$bad = $count.FAIL + $count.XPASS
Write-Output ''
Write-Output ("target={0} cases={1} pass={2} fail={3} xfail={4} xpass={5}" -f $Target, $rows.Count, $count.PASS, $count.FAIL, $count.XFAIL, $count.XPASS)
if ($bad -gt 0 -or $KeepTemp) {
    Write-Output "work directory kept: $work"
} else {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($rows.Count -eq 0) { [Console]::Error.WriteLine('run.ps1: no cases selected'); exit 2 }
if ($bad -gt 0) { exit 1 }
exit 0
