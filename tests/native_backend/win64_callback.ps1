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
$actual = & $program
if ($LASTEXITCODE -ne 0 -or $actual -cne 'callback-ok') { throw "Native Win32 callback failed: $actual" }
Write-Output 'win64-callback-ok'
