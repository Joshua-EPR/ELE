# Measure front-end plus CFG verification using two already built compilers.
param(
    [Parameter(Mandatory)][string]$Baseline,
    [string]$Current = 'target/debug/l.exe',
    [ValidateRange(1, 100)][int]$Runs = 15,
    [switch]$ReferenceReturns,
    [switch]$MultipleOrigins,
    [switch]$AggregateViews
)

$ErrorActionPreference = 'Stop'
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$old = (Resolve-Path -LiteralPath $Baseline).Path
$new = (Resolve-Path -LiteralPath $Current).Path
if ($MultipleOrigins) { $ReferenceReturns = $true }
if ($AggregateViews) { $MultipleOrigins = $true; $ReferenceReturns = $true }
$directory = if ($AggregateViews) { 'target/aggregate-profile' } elseif ($MultipleOrigins) { 'target/escape-profile' } elseif ($ReferenceReturns) { 'target/return-profile' } else { 'target/lifetime-profile' }
$work = Join-Path (Split-Path -Parent $PSScriptRoot) $directory
New-Item -ItemType Directory -Force $work | Out-Null

function Measure-Check($compiler, $source) {
    $psi = [Diagnostics.ProcessStartInfo]::new($compiler)
    $psi.ArgumentList.Add('check')
    $psi.ArgumentList.Add($source)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $proc = [Diagnostics.Process]::Start($psi)
    try {
        $out = $proc.StandardOutput.ReadToEndAsync()
        $err = $proc.StandardError.ReadToEndAsync()
        $peak = 0
        do {
            try { $proc.Refresh(); $peak = [Math]::Max($peak, $proc.PeakWorkingSet64) } catch {}
        } until ($proc.WaitForExit(1))
        $timer.Stop()
        if ($proc.ExitCode -ne 0) { throw "check de $source falló: $($err.Result)" }
        $null = $out.Result
        [pscustomobject]@{ Ms = $timer.Elapsed.TotalMilliseconds; PeakKiB = [math]::Round($peak / 1KB) }
    } finally { $proc.Dispose() }
}

$sizes = if ($AggregateViews) { @(1, 40) } else { @(1, 80) }
$rows = foreach ($n in $sizes) {
    foreach ($name in @('base', 'local', 'returns', 'multiple', 'views')) {
        if ($name -eq 'returns' -and -not $ReferenceReturns) { continue }
        if ($name -eq 'multiple' -and -not $MultipleOrigins) { continue }
        if ($name -eq 'views' -and -not $AggregateViews) { continue }
        $withLoans = $name -eq 'local'
        $source = Join-Path $work "$name-$n.l"
        $body = if ($withLoans) { 'let r = &x' + "`n print(r)" } else { 'print(x)' }
        $functions = for ($i = 0; $i -lt $n; $i++) {
            "fn sample_$i() {`n let x = 10`n $body`n}"
        }
        $main = 'fn main() { sample_0() }'
        if ($name -eq 'returns') {
            $functions = for ($i = 0; $i -lt $n; $i++) {
                if ($i -eq 0) { 'fn sample_0(x: &Int) -> &Int = x' }
                else { "fn sample_$i(x: &Int) -> &Int = sample_$($i - 1)(x)" }
            }
            $main = "fn main() { let x = 1`n let r = sample_$($n - 1)(x)`n print(r) }"
        }
        if ($name -eq 'multiple') {
            $functions = for ($i = 0; $i -lt $n; $i++) {
                if ($i -eq 0) { 'fn sample_0(a: &Int, b: &Int) -> &Int = a' }
                else { "fn sample_$i(a: &Int, b: &Int) -> &Int = sample_$($i - 1)(b, a)" }
            }
            $main = "fn main() { let x = 1`n let y = 2`n let r = sample_$($n - 1)(x, y)`n print(r) }"
        }
        if ($name -eq 'views') {
            $functions = @('struct Owned { n: Int }', 'struct View { a: &Int, b: &Int, owned: Owned }') + @(for ($i = 0; $i -lt $n; $i++) {
                "fn sample_$i() {`n let x = 1`n let y = 2`n let v = View(a: &x, b: &y, owned: Owned(n: x))`n let moved = v`n print(moved.a + moved.b + moved.owned.n)`n}"
            })
        }
        Set-Content -Encoding ascii -LiteralPath $source -Value (@($functions) + $main)
        $compilers = [ordered]@{ Current = $new }
        if ($name -eq 'base' -or ($withLoans -and $ReferenceReturns) -or ($MultipleOrigins -and $name -eq 'returns') -or ($AggregateViews -and $name -eq 'multiple')) { $compilers['Baseline'] = $old }
        $samples = @{}
        foreach ($key in $compilers.Keys) {
            $null = Measure-Check $compilers[$key] $source
            $samples[$key] = [Collections.Generic.List[object]]::new()
        }
        for ($i = 0; $i -lt $Runs; $i++) {
            foreach ($key in $compilers.Keys) {
                $samples[$key].Add((Measure-Check $compilers[$key] $source))
            }
        }
        foreach ($key in $compilers.Keys) {
            $times = @($samples[$key].Ms | Sort-Object)
            [pscustomobject]@{ Compiler = $key; Fixture = $name
                Functions = $n + 1; LoanSites = if ($withLoans) { $n } else { 0 }
                ReturnContracts = if ($name -in 'returns', 'multiple') { $n } else { 0 }
                ViewFieldLoans = if ($name -eq 'views') { 2 * $n } else { 0 }
                OriginEdges = if ($name -eq 'multiple') { 2 * $n } elseif ($name -eq 'returns') { $n } else { 0 }
                MedianMs = [math]::Round($times[[int][math]::Floor($Runs / 2)], 2)
                MinMs = [math]::Round($times[0], 2)
                MaxMs = [math]::Round($times[-1], 2)
                PeakKiB = ($samples[$key].PeakKiB | Measure-Object -Maximum).Maximum
            }
        }
    }
}
$rows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $work 'results.csv')
$rows | Format-Table -AutoSize
