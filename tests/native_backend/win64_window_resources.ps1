# Window resource audit (P0-D): builds tests/std/window_churn.l, lets it open
# and close 200 windows, then counts its GDI and USER objects while its last
# window is open. A leak of the back buffer, memory DC or font per window
# would show as hundreds of objects. Then closes the window with WM_CLOSE
# and expects a clean exit. Usage: ./win64_window_resources.ps1 -Ele <driver>
param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$driver = (Resolve-Path $Ele).Path
$outDir = Join-Path $root 'target\win64-window-resources'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$exe = Join-Path $outDir 'window-churn.exe'
& $driver build (Join-Path $root 'tests\std\window_churn.l') --lib $root --target pe --output $exe
if ($LASTEXITCODE -ne 0) { throw 'window_churn failed to compile' }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class EleGuiAudit {
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
}
'@

$psi = [Diagnostics.ProcessStartInfo]::new($exe)
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$p = [Diagnostics.Process]::Start($psi)
try {
    $line = $p.StandardOutput.ReadLine()
    if ($line -ne 'churn-done') { throw "unexpected output '$line' (exit $($p.ExitCode))" }
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 100 -and $hwnd -eq [IntPtr]::Zero; $i++) {
        Start-Sleep -Milliseconds 50
        $hwnd = [EleGuiAudit]::FindWindowW('ELEWindow', 'ELE churn')
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'the last window was not found' }
    $gdi = [EleGuiAudit]::GetGuiResources($p.Handle, 0)
    $user = [EleGuiAudit]::GetGuiResources($p.Handle, 1)
    Write-Output "after 200 windows: GDI objects $gdi, USER objects $user"
    [void][EleGuiAudit]::PostMessageW($hwnd, 16, [IntPtr]::Zero, [IntPtr]::Zero)
    if (-not $p.WaitForExit(15000)) { throw 'window_churn did not exit after WM_CLOSE' }
    if ($p.ExitCode -ne 0) { throw "window_churn exit $($p.ExitCode)" }
    # One open window needs a handful of objects; 200 leaked windows would
    # need at least 600 GDI objects.
    if ($gdi -gt 50) { throw "GDI objects leaked: $gdi" }
    if ($user -gt 50) { throw "USER objects leaked: $user" }
} finally {
    if (-not $p.HasExited) { $p.Kill() }
}
Write-Output 'win64-window-resources-ok'
