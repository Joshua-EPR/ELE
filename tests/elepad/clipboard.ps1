param([Parameter(Mandatory=$true)][string]$Ele)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$driver = (Resolve-Path $Ele).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('elepad-clipboard-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$exe = Join-Path $work 'elepad-gui.exe'
$file = Join-Path $work 'sample.l'
$original = "ASCII café 😀`r`nsecond line"
$external = "VS Code / browser text: ñ 🧪 漢字`nfinal line"
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText($file, $original, $utf8)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClipboardGuiDriver {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessageW(IntPtr hwnd, uint msg, IntPtr w, IntPtr l);
}
'@

function Send-Char([IntPtr]$hwnd, [int]$code) {
    if (-not [ClipboardGuiDriver]::PostMessageW($hwnd, 258, [IntPtr]$code, [IntPtr]::Zero)) { throw "WM_CHAR $code failed" }
    Start-Sleep -Milliseconds 120
}
function Assert-File([string]$wanted) {
    $actual = [IO.File]::ReadAllText($file, $utf8)
    if ($actual -cne $wanted) { throw "File mismatch: '$actual'" }
}

$oldClipboard = Get-Clipboard -Raw -ErrorAction SilentlyContinue
$p = $null
try {
    & $driver build (Join-Path $root 'apps/elepad/src/gui.l') --lib $root --target pe --output $exe
    if ($LASTEXITCODE -ne 0) { throw 'ELEPad build failed' }
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.Arguments = '"' + $file + '"'
    $psi.UseShellExecute = $false
    $p = [Diagnostics.Process]::Start($psi)
    $title = 'ELEPad - ' + $file
    $hwnd = [IntPtr]::Zero
    for ($i = 0; $i -lt 200; $i++) {
        $hwnd = [ClipboardGuiDriver]::FindWindowW('ELEWindow', $title)
        if ($hwnd -ne [IntPtr]::Zero) { break }
        if ($p.HasExited) { throw "ELEPad exited early: $($p.ExitCode)" }
        Start-Sleep -Milliseconds 25
    }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'ELEPad window not found' }

    Send-Char $hwnd 1  # Ctrl+A
    Send-Char $hwnd 3  # Ctrl+C
    $copied = Get-Clipboard -Raw
    if ($copied -cne $original) { throw "ELEPad -> OS clipboard mismatch: '$copied'" }

    Send-Char $hwnd 24 # Ctrl+X: must copy before deleting
    Send-Char $hwnd 19 # Ctrl+S
    Assert-File ''
    if ((Get-Clipboard -Raw) -cne $original) { throw 'Cut lost the clipboard text' }
    Send-Char $hwnd 26 # Ctrl+Z
    Send-Char $hwnd 19
    Assert-File $original

    # A competing process owns the clipboard: cut must preserve the document.
    Send-Char $hwnd 1
    $holder = Join-Path $work 'holder.ps1'
    $marker = Join-Path $work 'locked.txt'
    @'
param([string]$Marker)
Add-Type -TypeDefinition 'using System; using System.IO; using System.Threading; using System.Runtime.InteropServices; public class Holder { [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h); [DllImport("user32.dll")] public static extern bool CloseClipboard(); [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow(); public static void Hold(string marker) { bool ok=OpenClipboard(GetDesktopWindow()); File.WriteAllText(marker, ok.ToString()); Thread.Sleep(4000); if(ok) CloseClipboard(); } }'
[Holder]::Hold($Marker)
'@ | Set-Content -LiteralPath $holder -Encoding utf8
    $locker = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoProfile', '-File', ('"' + $holder + '"'), '-Marker', ('"' + $marker + '"')) -WindowStyle Hidden -PassThru
    try {
        for ($i = 0; $i -lt 100 -and -not (Test-Path $marker); $i++) { Start-Sleep -Milliseconds 25 }
        if (-not (Test-Path $marker) -or (Get-Content $marker) -ne 'True') { throw 'Could not lock clipboard for failure test' }
        Send-Char $hwnd 24
    } finally {
        if (-not $locker.WaitForExit(5000)) { $locker.Kill(); $locker.WaitForExit() }
    }
    Send-Char $hwnd 19
    Assert-File $original

    Set-Clipboard -Value $external # Written by an external process
    Send-Char $hwnd 1
    Send-Char $hwnd 22 # Ctrl+V
    Send-Char $hwnd 19
    Assert-File $external
    Send-Char $hwnd 26 # Undo replacement
    Send-Char $hwnd 19
    Assert-File $original
    Send-Char $hwnd 25 # Redo replacement
    Send-Char $hwnd 19
    Assert-File $external
    if ((Get-Clipboard -Raw) -cne $external) { throw 'Paste changed the OS clipboard' }

    Send-Char $hwnd 17 # Ctrl+Q
    if (-not $p.WaitForExit(5000)) { throw 'ELEPad did not close' }
    if ($p.ExitCode -ne 0) { throw "ELEPad exit $($p.ExitCode)" }
    'elepad-clipboard-ok'
} finally {
    if ($p -and -not $p.HasExited) { $p.Kill(); $p.WaitForExit() }
    if ($null -ne $oldClipboard) { Set-Clipboard -Value $oldClipboard }
    Remove-Item -LiteralPath $work -Recurse -Force
}
