# Loads vm\wehost.dll into the running game (sandbox only). Must run in the 32-bit PowerShell (SysWOW64) so that
# kernel32!LoadLibraryW has the same address in both processes. Waits up to 2 minutes for the game.
param([int]$ProcId)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Inj {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(int a, bool i, int pid);
    [DllImport("kernel32.dll")] public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr a, int n, int t, int p);
    [DllImport("kernel32.dll")] public static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int w);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandleW(string m);
    [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] public static extern IntPtr GetProcAddress(IntPtr m, string f);
    [DllImport("kernel32.dll")] public static extern IntPtr CreateRemoteThread(IntPtr h, IntPtr a, int s, IntPtr f, IntPtr p, int fl, IntPtr id);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
}
'@
$dll = Join-Path $PSScriptRoot 'wehost.dll'
$log = Join-Path $PSScriptRoot 'out\inject.txt'
$p = $null
for ($t = 0; $t -lt 240 -and -not $p; $t++) {
    $p = if ($ProcId) { Get-Process -Id $ProcId -ErrorAction SilentlyContinue } else { Get-Process WEShell_TGI -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $p) { Start-Sleep -Milliseconds 500 }
}
if (-not $p) { 'game not running' | Out-File $log -Append; exit 1 }
$h = [Inj]::OpenProcess(0x1F0FFF, $false, $p.Id)
$bytes = [Text.Encoding]::Unicode.GetBytes($dll + [char]0)
$mem = [Inj]::VirtualAllocEx($h, [IntPtr]::Zero, $bytes.Length, 0x3000, 4)
$w = 0; [void][Inj]::WriteProcessMemory($h, $mem, $bytes, $bytes.Length, [ref]$w)
$ll = [Inj]::GetProcAddress([Inj]::GetModuleHandleW('kernel32.dll'), 'LoadLibraryW')
if ($ll -eq [IntPtr]::Zero) { 'LoadLibraryW not found, not injecting' | Out-File $log -Append; exit 1 }   # never start a thread at 0
$th = [Inj]::CreateRemoteThread($h, [IntPtr]::Zero, 0, $ll, $mem, 0, [IntPtr]::Zero)
[void][Inj]::WaitForSingleObject($th, 10000)
"$(Get-Date -f HH:mm:ss) injected $dll into pid $($p.Id), thread $th" | Out-File $log -Append
