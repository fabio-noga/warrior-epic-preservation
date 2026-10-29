# Breakpoint logger for the running game (sandbox only; run with the 32-bit PowerShell in SysWOW64).
# Attaches as a debugger, puts int3 on each address, and for every hit logs registers, 8 stack dwords and the
# return addresses found by walking the EBP chain. Detaches (restoring the original bytes) after $Seconds.
# usage: bp.ps1 -Seconds 60 0x47b200 0x47c0d0 ...
param([int]$Seconds = 60, [Parameter(ValueFromRemainingArguments)][string[]]$Addr)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic; using System.IO;
public static class Bp {
    [DllImport("kernel32.dll")] static extern bool DebugActiveProcess(int pid);
    [DllImport("kernel32.dll")] static extern bool DebugActiveProcessStop(int pid);
    [DllImport("kernel32.dll")] static extern bool DebugSetProcessKillOnExit(bool k);
    [DllImport("kernel32.dll")] static extern bool WaitForDebugEvent(byte[] ev, int ms);
    [DllImport("kernel32.dll")] static extern bool ContinueDebugEvent(int pid, int tid, uint status);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int acc, bool inh, int pid);
    [DllImport("kernel32.dll")] static extern IntPtr OpenThread(int acc, bool inh, int tid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll")] static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int r);
    [DllImport("kernel32.dll")] static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int w);
    [DllImport("kernel32.dll")] static extern bool FlushInstructionCache(IntPtr h, IntPtr a, int n);
    [DllImport("kernel32.dll")] static extern bool GetThreadContext(IntPtr t, byte[] c);
    [DllImport("kernel32.dll")] static extern bool SetThreadContext(IntPtr t, byte[] c);
    const uint DBG_CONTINUE = 0x00010002, DBG_NOT_HANDLED = 0x80010001;
    // x86 CONTEXT offsets
    const int EDI = 0x9c, ESI = 0xa0, EBX = 0xa4, EDX = 0xa8, ECX = 0xac, EAX = 0xb0, EBP = 0xb4, EIP = 0xb8, EFL = 0xc0, ESP = 0xc4;
    static IntPtr hp;
    static uint U(byte[] b, int o) { return BitConverter.ToUInt32(b, o); }
    static uint Rd(uint a) { var b = new byte[4]; int r; return ReadProcessMemory(hp, (IntPtr)a, b, 4, out r) ? U(b, 0) : 0xdeadbeef; }
    static void Wr(uint a, byte v) { int w; WriteProcessMemory(hp, (IntPtr)a, new byte[] { v }, 1, out w); FlushInstructionCache(hp, (IntPtr)a, 1); }
    public static void Run(int pid, uint[] addrs, int seconds, string log) {
        var w = new StreamWriter(log, true); w.AutoFlush = true;
        hp = OpenProcess(0x1F0FFF, false, pid);
        var orig = new Dictionary<uint, byte>();
        if (!DebugActiveProcess(pid)) { w.WriteLine("attach failed " + Marshal.GetLastWin32Error()); return; }
        DebugSetProcessKillOnExit(false);
        var ev = new byte[96]; var ctx = new byte[0x2cc];
        uint rearm = 0; var end = DateTime.Now.AddSeconds(seconds); bool armed = false;
        while (DateTime.Now < end) {
            if (!WaitForDebugEvent(ev, 200)) continue;
            int code = BitConverter.ToInt32(ev, 0), epid = BitConverter.ToInt32(ev, 4), tid = BitConverter.ToInt32(ev, 8);
            uint status = DBG_CONTINUE;
            if (code == 1) {   // EXCEPTION_DEBUG_EVENT: +12 ExceptionCode, +24 ExceptionAddress, +0x5c... firstChance at +0x58
                uint exc = U(ev, 12), at = U(ev, 24);
                if (exc == 0x80000003 && !armed) {          // attach breakpoint: arm ours now
                    foreach (var a in addrs) { var b = new byte[1]; int r; ReadProcessMemory(hp, (IntPtr)a, b, 1, out r); orig[a] = b[0]; Wr(a, 0xCC); }
                    armed = true; w.WriteLine("armed " + addrs.Length + " breakpoints");
                } else if (exc == 0x80000003 && orig.ContainsKey(at)) {
                    var ht = OpenThread(0x1F03FF, false, tid);
                    BitConverter.GetBytes(0x10007).CopyTo(ctx, 0); GetThreadContext(ht, ctx);
                    uint esp = U(ctx, ESP), ebp = U(ctx, EBP);
                    var s = string.Format("{0:HH:mm:ss.fff} HIT {1:x8} tid {2} eax={3:x8} ecx={4:x8} edx={5:x8} ebx={6:x8} esi={7:x8} edi={8:x8} ebp={9:x8} esp={10:x8}\n  stack:",
                        DateTime.Now, at, tid, U(ctx, EAX), U(ctx, ECX), U(ctx, EDX), U(ctx, EBX), U(ctx, ESI), U(ctx, EDI), ebp, esp);
                    for (int i = 0; i < 8; i++) s += string.Format(" {0:x8}", Rd(esp + (uint)(4 * i)));
                    s += "\n  calls:";
                    for (int i = 0; i < 16 && ebp > 0x10000 && ebp < 0x7fff0000; i++) { s += string.Format(" {0:x8}", Rd(ebp + 4)); ebp = Rd(ebp); }
                    w.WriteLine(s);
                    Wr(at, orig[at]);                                   // step over the original instruction
                    BitConverter.GetBytes(at).CopyTo(ctx, EIP);
                    BitConverter.GetBytes(U(ctx, EFL) | 0x100).CopyTo(ctx, EFL);
                    SetThreadContext(ht, ctx); CloseHandle(ht); rearm = at;
                } else if (exc == 0x80000004 && rearm != 0) {     // single step done: put the int3 back
                    Wr(rearm, 0xCC); rearm = 0;
                } else status = DBG_NOT_HANDLED;
            } else if (code == 5) { w.WriteLine("process exited"); break; }
            ContinueDebugEvent(epid, tid, status);
        }
        foreach (var kv in orig) Wr(kv.Key, kv.Value);
        DebugActiveProcessStop(pid); CloseHandle(hp); w.WriteLine("detached"); w.Close();
    }
}
'@
$p = $null
. (Join-Path $PSScriptRoot 'gamepid.ps1')
for ($t = 0; $t -lt 240 -and -not $p; $t++) {   # wait up to 2 min for the game
    $p = GameProcess
    if (-not $p) { Start-Sleep -Milliseconds 500 }
}
if (-not $p) { 'game not running'; exit 1 }
$log = Join-Path $PSScriptRoot 'out\bp.txt'
"=== $(Get-Date -f HH:mm:ss) bp on $($Addr -join ' ') for $Seconds s" | Out-File $log -Append -Encoding utf8
[Bp]::Run($p.Id, [uint32[]]($Addr | % { [Convert]::ToUInt32($_, 16) }), $Seconds, $log)
