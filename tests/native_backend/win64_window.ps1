# P0-D: a real Win32 window whose WndProc is the ELE four-word callback
# adapter. The autonomous driver compiles the generator; the generated PE
# registers a class, creates and shows a window, paints it (and reads a
# painted pixel back), receives queued keyboard/mouse input, closes itself
# and leaves its message loop. Usage: ./win64_window.ps1 -Ele <driver.exe>
param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$driver = (Resolve-Path $Ele).Path
$outDir = Join-Path $root 'target\win64-window-test'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$generator = Join-Path $outDir 'window-generator.exe'
$program = Join-Path $outDir 'window-native.exe'

& $driver build (Join-Path $root 'compiler-l\src\native_win_window_probe.l') --target pe --output $generator
if ($LASTEXITCODE -ne 0) { throw 'Autonomous window generator failed to compile' }
if (Test-Path $program) { Remove-Item -LiteralPath $program -Force }
& $generator $program
if ($LASTEXITCODE -ne 0) { throw 'Window PE generation failed' }

$psi = [Diagnostics.ProcessStartInfo]::new($program)
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$p = [Diagnostics.Process]::Start($psi)
$stdout = $p.StandardOutput.ReadToEnd()
if (-not $p.WaitForExit(30000)) { $p.Kill(); throw 'Window probe did not leave its message loop' }
$status = $p.ExitCode
$actual = ($stdout -split "`r?`n" | Where-Object { $_ -ne '' }) -join "`n"
# Exit 2: user32/gdi32 missing; 3: RegisterClassExW failed; 4:
# CreateWindowExW failed; 5: an export was not found; 9: GetMessageW error.
$expected = @(
    'wm-create', 'wm-paint-pixel-ok', 'wm-keydown-a', 'wm-lbuttondown-30-40',
    'wm-close', 'wm-destroy', 'message-loop-done'
) -join "`n"
if ($status -ne 0 -or $actual -cne $expected) { throw "Native Win32 window failed (exit $status):`n$actual" }
Write-Output 'win64-window-ok'
