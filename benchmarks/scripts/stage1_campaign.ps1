<#
.SYNOPSIS
    Measures compile time, executable size, run time and peak memory of an ELE
    compiler (Stage 1 driver or Stage 0 `l`) on a list of sources.

.DESCRIPTION
    For every source: 1 untimed warm-up compile, then -Runs timed compiles
    (wall clock, Stopwatch around Process.Start..WaitForExit). Peak memory is
    PeakWorkingSet64 read with GetProcessMemoryInfo on the process handle AFTER
    the process exited (exact, not sampled). With -RunPrograms the produced
    executable is also run 1 warm-up + -Runs times (stdout redirected and
    hashed, exit code recorded).

    Output: one CSV with one row per (program, phase, run) and one summary CSV
    with median/min/max. Nothing is extrapolated.

.EXAMPLE
    .\benchmarks\scripts\stage1_campaign.ps1 -Compiler gen2.exe -Kind stage1 `
        -Sources examples\hello.l,compiler-l\src\main_driver.l -OutDir out -Tag stage1 -RunPrograms
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Compiler,
    [ValidateSet('stage1', 'stage0', 'rustc')][string]$Kind = 'stage1',
    [Parameter(Mandatory = $true)][string[]]$Sources,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Tag = '',
    [int]$Runs = 5,
    [switch]$RunPrograms,
    [switch]$SkipCompileTiming,
    [string[]]$ExtraArgs = @()
)
$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
if (-not $Tag) { $Tag = $Kind }
New-Item -ItemType Directory -Force $OutDir | Out-Null

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PeakMem {
    [StructLayout(LayoutKind.Sequential)]
    public struct PMC { public uint cb; public uint PageFaultCount; public UIntPtr PeakWorkingSetSize; public UIntPtr WorkingSetSize;
        public UIntPtr QuotaPeakPagedPoolUsage; public UIntPtr QuotaPagedPoolUsage; public UIntPtr QuotaPeakNonPagedPoolUsage;
        public UIntPtr QuotaNonPagedPoolUsage; public UIntPtr PagefileUsage; public UIntPtr PeakPagefileUsage; }
    [DllImport("psapi.dll", SetLastError = true)]
    public static extern bool GetProcessMemoryInfo(IntPtr h, out PMC c, uint cb);
    public static long Peak(IntPtr h) { PMC c; c.cb = (uint)Marshal.SizeOf(typeof(PMC));
        if (!GetProcessMemoryInfo(h, out c, c.cb)) return -1; return (long)c.PeakWorkingSetSize.ToUInt64(); }
}
'@

function Invoke-Timed([string]$exe, [string[]]$argv, [string]$cwd) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($cwd) { $psi.WorkingDirectory = $cwd }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    $so = $p.StandardOutput.ReadToEndAsync()
    $se = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $sw.Stop()
    $peak = [PeakMem]::Peak($p.Handle)
    [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; PeakB = $peak; Code = $p.ExitCode; Out = $so.Result; Err = $se.Result }
}

function Get-Stats($vals) {
    $s = @($vals | Sort-Object)
    $n = $s.Count
    $med = if ($n % 2 -eq 1) { $s[($n - 1) / 2] } else { ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
    [pscustomobject]@{ Median = $med; Min = $s[0]; Max = $s[$n - 1] }
}
function Get-Sha([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') })
}

$raw = New-Object System.Collections.Generic.List[object]
$sum = New-Object System.Collections.Generic.List[object]
$work = Join-Path $OutDir "work_$Tag"
New-Item -ItemType Directory -Force $work | Out-Null

foreach ($src in $Sources) {
    $srcFull = (Resolve-Path -LiteralPath $src).Path
    $name = [IO.Path]::GetFileNameWithoutExtension($srcFull)
    $dir = Join-Path $work $name
    New-Item -ItemType Directory -Force $dir | Out-Null
    $exe = Join-Path $dir ($name + '.exe')
    if ($Kind -eq 'stage1') { $argv = @('build', $srcFull, '-o', $exe) + $ExtraArgs }
    elseif ($Kind -eq 'rustc') { $argv = @('-C', 'opt-level=3', '-o', $exe, $srcFull) + $ExtraArgs }
    else { $argv = @('build', $srcFull, '--backend', 'cranelift') + $ExtraArgs }

    $cms = @(); $cpeak = @(); $ok = $true; $cerr = ''
    $total = $Runs + 1
    for ($i = 0; $i -lt $total; $i++) {
        if ($Kind -eq 'stage0' -and (Test-Path $exe)) { Remove-Item $exe -Force }
        $r = Invoke-Timed $Compiler $argv $dir
        if ($r.Code -ne 0) { $ok = $false; $cerr = ($r.Err + $r.Out).Trim().Split("`n")[0]; break }
        if ($Kind -eq 'stage0') {
            $m = [regex]::Match($r.Out, '(?m)^Build: (.*)$')
            if ($m.Success) { $cand = Join-Path $dir $m.Groups[1].Value.Trim(); if (Test-Path $cand) { $exe = $cand } }
        }
        $phase = if ($i -eq 0) { 'compile_warmup' } else { 'compile' }
        $raw.Add([pscustomobject]@{ tag = $Tag; program = $name; phase = $phase; run = $i; ms = [math]::Round($r.Ms, 2); peak_b = $r.PeakB; exit = $r.Code; out_sha256 = '' })
        if ($i -gt 0) { $cms += $r.Ms; $cpeak += $r.PeakB }
        if ($SkipCompileTiming -and $i -eq 0) { $total = 1 }
    }
    $row = [ordered]@{ tag = $Tag; kind = $Kind; program = $name; source_b = (Get-Item $srcFull).Length; compile_ok = $ok; compile_error = $cerr }
    if ($ok) {
        $cs = if ($cms.Count) { Get-Stats $cms } else { $null }
        $row.compile_runs = $cms.Count
        $row.compile_ms_median = if ($cs) { [math]::Round($cs.Median, 1) } else { '' }
        $row.compile_ms_min = if ($cs) { [math]::Round($cs.Min, 1) } else { '' }
        $row.compile_ms_max = if ($cs) { [math]::Round($cs.Max, 1) } else { '' }
        $row.compile_peak_mib = if ($cpeak.Count) { [math]::Round((($cpeak | Measure-Object -Maximum).Maximum) / 1MB, 2) } else { '' }
        $row.exe_b = (Get-Item $exe).Length
        $row.exe_kib = [math]::Round($row.exe_b / 1KB, 1)
        $row.exe_sha256 = (Get-FileHash -Algorithm SHA256 $exe).Hash.ToLower()
        if ($RunPrograms) {
            $rms = @(); $rpeak = @(); $outs = @(); $codes = @()
            for ($i = 0; $i -lt ($Runs + 1); $i++) {
                $r = Invoke-Timed $exe @() $dir
                $h = Get-Sha ($r.Out)
                $phase = if ($i -eq 0) { 'run_warmup' } else { 'run' }
                $raw.Add([pscustomobject]@{ tag = $Tag; program = $name; phase = $phase; run = $i; ms = [math]::Round($r.Ms, 2); peak_b = $r.PeakB; exit = $r.Code; out_sha256 = $h })
                if ($i -gt 0) { $rms += $r.Ms; $rpeak += $r.PeakB; $outs += $h; $codes += $r.Code }
                if ($i -eq 0) { $firstOut = ($r.Out.Trim() -split "`n")[0] }
            }
            $rs = Get-Stats $rms
            $row.run_ms_median = [math]::Round($rs.Median, 1)
            $row.run_ms_min = [math]::Round($rs.Min, 1)
            $row.run_ms_max = [math]::Round($rs.Max, 1)
            $row.run_peak_mib = [math]::Round((($rpeak | Measure-Object -Maximum).Maximum) / 1MB, 2)
            $row.run_exit = ($codes | Select-Object -Unique) -join '/'
            $row.run_output_stable = (($outs | Select-Object -Unique).Count -eq 1)
            $row.run_first_line = $firstOut
        }
    }
    $sum.Add([pscustomobject]$row)
    Write-Host ("{0,-28} {1}" -f $name, (($row.GetEnumerator() | Where-Object { $_.Key -match 'ms_median|exe_b|peak|ok' } | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))
}

$raw | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $OutDir "raw_$Tag.csv")
# Summary rows can have different columns; normalise.
$cols = $sum | ForEach-Object { $_.PSObject.Properties.Name } | Select-Object -Unique
$sum | Select-Object $cols | Export-Csv -NoTypeInformation -Encoding utf8 (Join-Path $OutDir "summary_$Tag.csv")
