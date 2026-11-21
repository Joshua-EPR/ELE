# Tests of std/io/console.l and the consoleInputMode/readConsoleEvent
# platform operations on Windows. The programs under test are ELE compiled by
# the autonomous driver; this script only builds them, feeds input and checks
# exit codes and console state.
#
#   .\tests\std\console_input.ps1 -Ele <path to ele.exe or main_driver.exe>
#
# 1. Decoder over redirected bytes (positive, and a negative mismatch).
# 2. Real console: a console is allocated, INPUT_RECORDs are written with
#    WriteConsoleInputW, the ELE program reads them through
#    ReadConsoleInputW, and the console input mode must be restored.
# 3. The interactive test refuses redirected input (not a console).
param(
    [Parameter(Mandatory = $true)][string]$Ele,
    [string]$OutDir = (Join-Path ([IO.Path]::GetTempPath()) 'ele-console-input-tests')
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$src = Join-Path $root 'std\io'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$failures = 0
# .NET Framework creates the child's stdin writer with Console.InputEncoding
# and writes its preamble: without this, every byte test would start with a
# UTF-8 BOM (U+FEFF), which the decoder rightly reports as a character.
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

function Build-Ele([string]$name) {
    $out = Join-Path $OutDir ($name + '.exe')
    if (Test-Path $out) { Remove-Item $out -Force }
    Push-Location $src
    try { & $Ele build ($name + '.l') -o $out | Out-Host } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "build of $name.l failed" }
    return $out
}

function Invoke-WithBytes([string]$exe, [byte[]]$bytes) {
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $p.StandardInput.Close()
    $null = $p.StandardOutput.ReadToEnd()
    $p.WaitForExit()
    return $p.ExitCode
}

function Check([string]$what, [int]$actual, [int]$expected) {
    if ($actual -eq $expected) {
        Write-Host "PASS $what"
    } else {
        Write-Host "FAIL $what (exit $actual, expected $expected)"
        $script:failures++
    }
}

$decoder = Build-Ele 'console_test'
$interactive = Build-Ele 'console_interactive_test'
$demo = Build-Ele 'console_keys'

# 1. Bytes: a, é, ESC[A, ESC[1;5C, ESC[3~, Ctrl+S, DEL, CR, TAB, ESC ESC,
#    ESC O P, ESC[15~, U+1F600, 0xFF, ESC x.
$seq = [byte[]](0x61, 0xC3, 0xA9, 0x1B, 0x5B, 0x41, 0x1B, 0x5B, 0x31, 0x3B, 0x35, 0x43,
    0x1B, 0x5B, 0x33, 0x7E, 0x13, 0x7F, 0x0D, 0x09, 0x1B, 0x1B, 0x1B, 0x4F, 0x50,
    0x1B, 0x5B, 0x31, 0x35, 0x7E, 0xF0, 0x9F, 0x98, 0x80, 0xFF, 0x1B, 0x78)
Check 'decoder: byte sequence' (Invoke-WithBytes $decoder $seq) 0
Check 'decoder: mismatch is reported' (Invoke-WithBytes $decoder ([byte[]](0x62))) 2
Check 'decoder: truncated UTF-8 then end' (Invoke-WithBytes $decoder ([byte[]](0x61, 0xC3))) 3
Check 'decoder: empty input' (Invoke-WithBytes $decoder ([byte[]]@())) 2
Check 'demo: redirected input ends cleanly' (Invoke-WithBytes $demo ([byte[]](0x61, 0x13, 0x1B, 0x5B, 0x41))) 0
# 3. Not a console.
Check 'interactive test: redirected input is not a console' (Invoke-WithBytes $interactive ([byte[]](0x61))) 1

# 2. Real console.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class EleConsoleHarness {
    [StructLayout(LayoutKind.Explicit, Size = 20)]
    public struct InputRecord {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort VirtualKey;
        [FieldOffset(12)] public ushort ScanCode;
        [FieldOffset(14)] public ushort Unicode;
        [FieldOffset(16)] public uint KeyControl;
        [FieldOffset(4)] public short X;
        [FieldOffset(6)] public short Y;
        [FieldOffset(8)] public uint Buttons;
        [FieldOffset(12)] public uint MouseControl;
        [FieldOffset(16)] public uint MouseFlags;
    }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AllocConsole();
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteConsoleInputW(IntPtr h, InputRecord[] records, uint count, out uint written);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleMode(IntPtr h, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DuplicateHandle(IntPtr sourceProcess, IntPtr sourceHandle,
        IntPtr targetProcess, out IntPtr targetHandle, uint desiredAccess,
        bool inheritHandle, uint options);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
    static extern bool CreateProcess(string appName, string commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint creationFlags, IntPtr environment, string currentDirectory,
        ref StartupInfo startupInfo, out ProcessInformation processInfo);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct StartupInfo {
        public uint cb;
        public string reserved;
        public string desktop;
        public string title;
        public uint x; public uint y; public uint xSize; public uint ySize;
        public uint xCountChars; public uint yCountChars; public uint fillAttribute;
        public uint flags; public ushort showWindow; public ushort cbReserved2;
        public IntPtr reserved2;
        public IntPtr standardInput;
        public IntPtr standardOutput;
        public IntPtr standardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInformation {
        public IntPtr process;
        public IntPtr thread;
        public uint processId;
        public uint threadId;
    }

    // Explicit STARTF_USESTDHANDLES is needed when a runner (such as Actions)
    // has launched PowerShell with stdin redirected. Changing the parent's
    // GetStdHandle slot alone does not guarantee that Process.Start inherits it.
    static string RunConsoleChild(string exe, IntPtr input) {
        IntPtr proc = GetCurrentProcess();
        IntPtr childInput;
        if (!DuplicateHandle(proc, input, proc, out childInput, 0, true, 2))
            return "DuplicateHandle input failed " + Marshal.GetLastWin32Error();
        IntPtr output = CreateFileW("CONOUT$", 0x40000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (output == new IntPtr(-1)) {
            CloseHandle(childInput);
            return "CONOUT$ failed " + Marshal.GetLastWin32Error();
        }
        IntPtr childOutput;
        if (!DuplicateHandle(proc, output, proc, out childOutput, 0, true, 2)) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(output);
            CloseHandle(childInput);
            return "DuplicateHandle output failed " + error;
        }
        CloseHandle(output);
        try {
            StartupInfo si = new StartupInfo();
            si.cb = (uint)Marshal.SizeOf(typeof(StartupInfo));
            si.flags = 0x00000100; // STARTF_USESTDHANDLES
            si.standardInput = childInput;
            si.standardOutput = childOutput;
            si.standardError = childOutput;
            ProcessInformation pi;
            if (!CreateProcess(exe, "\"" + exe + "\"", IntPtr.Zero, IntPtr.Zero,
                    true, 0, IntPtr.Zero, null, ref si, out pi))
                return "CreateProcessW failed " + Marshal.GetLastWin32Error();
            try {
                uint wait = WaitForSingleObject(pi.process, 20000);
                if (wait != 0) {
                    TerminateProcess(pi.process, 124);
                    return "child wait failed or timed out " + wait;
                }
                uint status;
                if (!GetExitCodeProcess(pi.process, out status))
                    return "GetExitCodeProcess failed " + Marshal.GetLastWin32Error();
                return "exit=" + status;
            } finally {
                CloseHandle(pi.thread);
                CloseHandle(pi.process);
            }
        } finally {
            CloseHandle(childOutput);
            CloseHandle(childInput);
        }
    }
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();

    static InputRecord Key(ushort vk, ushort unit, uint control, bool down, ushort repeat) {
        InputRecord r = new InputRecord();
        r.EventType = 1; r.KeyDown = down ? 1 : 0; r.Repeat = repeat;
        r.VirtualKey = vk; r.Unicode = unit; r.KeyControl = control;
        return r;
    }

    // Returns "exit=<code> before=<mode> after=<mode>" or an error text.
    public static string Run(string exe) {
        FreeConsole();
        if (!AllocConsole()) return "AllocConsole failed " + Marshal.GetLastWin32Error();
        ShowWindow(GetConsoleWindow(), 0);
        IntPtr input = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (input == new IntPtr(-1)) return "CONIN$ failed " + Marshal.GetLastWin32Error();
        uint before;
        if (!GetConsoleMode(input, out before)) return "GetConsoleMode failed";
        InputRecord resize = new InputRecord(); resize.EventType = 4; resize.X = 100; resize.Y = 30;
        InputRecord click = new InputRecord(); click.EventType = 2; click.X = 5; click.Y = 7; click.Buttons = 1;
        InputRecord[] records = new InputRecord[] {
            Key(65, 97, 0, true, 1),
            Key(83, 19, 8, true, 1),
            Key(38, 0, 0x100, true, 1),
            Key(16, 0, 16, true, 1),
            Key(65, 65, 16, true, 1),
            Key(65, 65, 16, false, 1),
            Key(0, 0xD83D, 0, true, 1),
            Key(0, 0xDE00, 0, true, 1),
            Key(50, 64, 1 + 8, true, 1),
            resize,
            click,
            Key(116, 0, 0, true, 3),
            Key(27, 27, 0, true, 1),
        };
        // A successful console write can still report fewer records than
        // requested. Finish the batch, but never accept a zero-progress write.
        int offset = 0;
        int attempts = 0;
        while (offset < records.Length && attempts < 32) {
            int remaining = records.Length - offset;
            InputRecord[] batch = new InputRecord[remaining];
            Array.Copy(records, offset, batch, 0, remaining);
            uint written;
            bool ok = WriteConsoleInputW(input, batch, (uint)remaining, out written);
            int error = ok ? 0 : Marshal.GetLastWin32Error();
            if (!ok || written == 0 || written > remaining)
                return "WriteConsoleInputW failed ok=" + ok + " written=" + written +
                    " remaining=" + remaining + " error=" + error;
            offset += (int)written;
            attempts++;
        }
        if (offset != records.Length)
            return "WriteConsoleInputW incomplete written=" + offset +
                " expected=" + records.Length;
        string result = RunConsoleChild(exe, input);
        uint after;
        GetConsoleMode(input, out after);
        CloseHandle(input);
        FreeConsole();
        return result + " before=" + before + " after=" + after;
    }
}
'@
$result = [EleConsoleHarness]::Run($interactive)
Write-Host "console run: $result"
if ($result -match '^exit=(\d+) before=(\d+) after=(\d+)$') {
    Check 'interactive: ReadConsoleInputW events decoded' ([int]$Matches[1]) 0
    Check 'interactive: console input mode restored' ([int]([long]$Matches[2] -eq [long]$Matches[3])) 1
} else {
    Write-Host "FAIL interactive harness: $result"
    $failures++
}

if ($failures -ne 0) { Write-Host "$failures failure(s)"; exit 1 }
Write-Host 'all console input tests passed'
exit 0
