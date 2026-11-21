# Windows real-console ELEPad test. Requires a compiled terminal.exe with
# writeConsoleBytes, plus a path to an existing UTF-8 .l file to edit.
param(
    [Parameter(Mandatory=$true)][string]$Exe,
    [Parameter(Mandatory=$true)][string]$File
)
$ErrorActionPreference = 'Stop'
$exePath = (Resolve-Path $Exe).Path
$filePath = (Resolve-Path $File).Path
$beforeFile = [IO.File]::ReadAllText($filePath, [Text.UTF8Encoding]::new($false))
$log = Join-Path ([IO.Path]::GetTempPath()) ('elepad-console-' + [guid]::NewGuid().ToString('N') + '.log')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ElePadConsoleHarness {
    [StructLayout(LayoutKind.Explicit, Size=20)]
    public struct InputRecord {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort VirtualKey;
        [FieldOffset(12)] public ushort ScanCode;
        [FieldOffset(14)] public ushort Unicode;
        [FieldOffset(16)] public uint KeyControl;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StartupInfo {
        public uint cb; public string reserved; public string desktop; public string title;
        public uint x,y,xSize,ySize,xCountChars,yCountChars,fillAttribute,flags;
        public ushort showWindow,cbReserved2;
        public IntPtr reserved2,standardInput,standardOutput,standardError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo {
        public IntPtr process,thread; public uint processId,threadId;
    }
    [DllImport("kernel32.dll")] static extern bool FreeConsole();
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool AllocConsole();
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode)]
    static extern IntPtr CreateFileW(string path,uint access,uint share,IntPtr sa,uint disposition,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetConsoleMode(IntPtr h,out uint mode);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetConsoleMode(IntPtr h,uint mode);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool FlushConsoleInputBuffer(IntPtr h);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteConsoleInputW(IntPtr h,InputRecord[] records,uint count,out uint written);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool DuplicateHandle(IntPtr source,IntPtr original,IntPtr target,out IntPtr copy,uint access,bool inherit,uint options);
    [DllImport("kernel32.dll",SetLastError=true,CharSet=CharSet.Unicode,EntryPoint="CreateProcessW")]
    static extern bool CreateProcess(string app,string command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string cwd,ref StartupInfo start,out ProcessInfo info);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr h,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr h,out uint code);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool TerminateProcess(IntPtr h,uint code);

    static InputRecord Key(ushort vk,ushort unit,uint control) {
        InputRecord r=new InputRecord(); r.EventType=1; r.KeyDown=1;
        r.Repeat=1; r.VirtualKey=vk; r.Unicode=unit; r.KeyControl=control;
        return r;
    }

    public static string Run(string exe,string file,string log) {
        FreeConsole();
        if (!AllocConsole()) return "AllocConsole error="+Marshal.GetLastWin32Error();
        IntPtr input=CreateFileW("CONIN$",0xC0000000,3,IntPtr.Zero,3,0,IntPtr.Zero);
        if (input==new IntPtr(-1)) return "CONIN error="+Marshal.GetLastWin32Error();
        uint before;
        if (!GetConsoleMode(input,out before)) return "GetConsoleMode error="+Marshal.GetLastWin32Error();
        System.Threading.Thread.Sleep(300);
        if (!FlushConsoleInputBuffer(input)) return "FlushInput error="+Marshal.GetLastWin32Error();
        // Feed the same edit as terminal.ps1: Right, é, Down, Backspace,
        // Ctrl+S, Ctrl+Q. Raw mode prevents the host from consuming Ctrl+S.
        InputRecord[] keys=new InputRecord[] {
            Key(39,0,0),Key(0,233,0),Key(40,0,0),Key(8,8,0),
            Key(83,19,8),Key(81,17,8)
        };
        if (!SetConsoleMode(input,(before & ~0xDFu)|0x98u)) return "SetRaw error="+Marshal.GetLastWin32Error();
        uint written;
        bool queued=WriteConsoleInputW(input,keys,(uint)keys.Length,out written);
        int queueError=Marshal.GetLastWin32Error();
        if (!SetConsoleMode(input,before)) return "RestoreBeforeStart error="+Marshal.GetLastWin32Error();
        if (!queued || written!=keys.Length) return "WriteConsoleInput error="+queueError+" written="+written;
        IntPtr process=GetCurrentProcess();
        IntPtr childInput,childOutput;
        if (!DuplicateHandle(process,input,process,out childInput,0,true,2)) return "DuplicateInput error="+Marshal.GetLastWin32Error();
        IntPtr output=CreateFileW(log,0x40000000,3,IntPtr.Zero,2,0,IntPtr.Zero);
        if (output==new IntPtr(-1)) return "CreateLog error="+Marshal.GetLastWin32Error();
        if (!DuplicateHandle(process,output,process,out childOutput,0,true,2)) return "DuplicateOutput error="+Marshal.GetLastWin32Error();
        CloseHandle(output);
        StartupInfo start=new StartupInfo(); start.cb=(uint)Marshal.SizeOf(typeof(StartupInfo));
        start.flags=0x100; start.standardInput=childInput;
        start.standardOutput=childOutput; start.standardError=childOutput;
        ProcessInfo info;
        if (!CreateProcess(exe,"\""+exe+"\" \""+file+"\"",IntPtr.Zero,IntPtr.Zero,true,0,IntPtr.Zero,null,ref start,out info))
            return "CreateProcess error="+Marshal.GetLastWin32Error();
        uint wait=WaitForSingleObject(info.process,20000);
        if (wait!=0) { TerminateProcess(info.process,124); return "timeout="+wait; }
        uint code;
        if (!GetExitCodeProcess(info.process,out code)) return "GetExitCode error="+Marshal.GetLastWin32Error();
        uint after;
        if (!GetConsoleMode(input,out after)) return "GetModeAfter error="+Marshal.GetLastWin32Error();
        CloseHandle(info.thread); CloseHandle(info.process);
        CloseHandle(childInput); CloseHandle(childOutput); CloseHandle(input);
        FreeConsole();
        return "exit="+code+" before="+before+" after="+after;
    }
}
'@
try {
    $result = [ElePadConsoleHarness]::Run($exePath,$filePath,$log)
    if ($result -notmatch '^exit=(\d+) before=(\d+) after=(\d+)$') { throw $result }
    if ([int]$Matches[1] -ne 0) { throw "ELEPad exited $($Matches[1]); log: $([IO.File]::ReadAllText($log))" }
    if ([long]$Matches[2] -ne [long]$Matches[3]) { throw 'console input mode was not restored' }
    $expected = "aéb`r`nc"
    if ([IO.File]::ReadAllText($filePath,[Text.UTF8Encoding]::new($false)) -cne $expected) { throw "file mismatch; before=$beforeFile" }
    Write-Host 'PASS real Windows console ELEPad edit/save/reopen and mode restoration'
} finally {
    if (Test-Path $log) { Remove-Item -LiteralPath $log -Force }
}
