param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$driver = (Resolve-Path $Ele).Path
$outDir = Join-Path $root 'target\win64-callback-test'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$generator = Join-Path $outDir 'callback-generator.exe'
$program = Join-Path $outDir 'callback-native.exe'

& $driver build (Join-Path $root 'compiler-l\src\native_win_callback_probe.l') --target pe --output $generator
if ($LASTEXITCODE -ne 0) { throw 'Autonomous callback generator failed to compile' }
$negative = & $generator --self-check
if ($LASTEXITCODE -ne 0 -or $negative -cne 'callback-negative-ok') { throw 'Callback target rejection failed' }
& $generator $program
if ($LASTEXITCODE -ne 0) { throw 'Callback PE generation failed' }
$actual = (& $program) -join "`n"
$status = $LASTEXITCODE
# Exit 7: RDI/RSI/RBX not preserved across a callback; 8: CallWindowProcW
# did not return the callback's LRESULT; 2/6: a DLL or export is missing.
$expected = "callback4-wndproc-ok`ncallback-ok`ncallback4-enum-ok`ncallback4-wndproc-ok"
if ($status -ne 0 -or $actual -cne $expected) { throw "Native Win32 callbacks failed (exit $status): $actual" }
Write-Output 'win64-callback-ok'
