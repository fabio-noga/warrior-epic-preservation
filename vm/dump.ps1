# Writes a small dump (threads, stacks, module list) of the running game to out\weshell.dmp,
# via dbghelp!MiniDumpWriteDump. Used by auto.cmd to see where a hung game is waiting.
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Dbg {
    [DllImport("dbghelp.dll", SetLastError = true)]
    public static extern bool MiniDumpWriteDump(IntPtr hProcess, uint pid, IntPtr hFile, uint type, IntPtr e, IntPtr u, IntPtr c);
}
'@
$p = Get-Process WEShell_TGI -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p) { 'game not running'; exit 1 }
$out = Join-Path $PSScriptRoot 'out\weshell.dmp'
$fs = [IO.File]::Create($out)
# MiniDumpWithFullMemory(2) | MiniDumpWithDataSegs(1) | MiniDumpWithHandleData(4) | MiniDumpWithThreadInfo(0x1000) | MiniDumpWithIndirectlyReferencedMemory(0x40)
$ok = [Dbg]::MiniDumpWriteDump($p.Handle, [uint32]$p.Id, $fs.SafeFileHandle.DangerousGetHandle(), 0x1047, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
$fs.Close()
"dump ok=$ok size=$((Get-Item $out).Length) threads=$($p.Threads.Count)"
