# In-memory patches of the running game (sandbox only, 32-bit PowerShell from SysWOW64). Nothing on disk changes.
# Waits for each target module to be loaded, checks the original bytes, writes the new ones. See CHANGES.md (M1).
param([int]$WaitSeconds = 180)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class Mem {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(int a, bool i, int pid);
    [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int r);
    [DllImport("kernel32.dll")] public static extern bool WriteProcessMemory(IntPtr h, IntPtr a, byte[] b, int n, out int w);
    [DllImport("kernel32.dll")] public static extern bool VirtualProtectEx(IntPtr h, IntPtr a, int n, uint p, out uint old);
    [DllImport("kernel32.dll")] public static extern bool FlushInstructionCache(IntPtr h, IntPtr a, int n);
}
'@
# module, VA, original bytes, new bytes, what it does
$patches = @(
    @('WEHallUI.dll', 0x6767eb1d, 'b8 01 00 00 00', 'e9 0b 00 00 00', 'M1a: 3D lobby stage first entry -> also run LobbyWorld init (jmp 0x6767eb2d)'),
    @('WEHallUI.dll', 0x6767eb24, 'b8 01 00 00 00', 'e9 04 00 00 00', 'M1b: same, town-connect-failed branch'),
    @('WEHallUI.dll', 0x676b7612, '74 5f', 'eb 5f', 'M2: lobby Join always does the CP JoinRoom (skip the direct town shortcut)')
)
$log = Join-Path $PSScriptRoot 'out\patchmem.txt'
. (Join-Path $PSScriptRoot 'gamepid.ps1')
function Hex($s) { [byte[]]($s -split ' ' | % { [Convert]::ToByte($_, 16) }) }
$end = (Get-Date).AddSeconds($WaitSeconds)
$done = @{}
while ((Get-Date) -lt $end -and $done.Count -lt $patches.Count) {
    $p = GameProcess
    if ($p) {
        $mods = try { $p.Modules | % { $_.ModuleName.ToLower() } } catch { @() }
        $h = [Mem]::OpenProcess(0x1F0FFF, $false, $p.Id)
        foreach ($x in $patches) {
            if ($done[$x[1]] -or $mods -notcontains $x[0].ToLower()) { continue }
            $orig = Hex $x[2]; $new = Hex $x[3]; $buf = New-Object byte[] $orig.Length; $n = 0
            [void][Mem]::ReadProcessMemory($h, [IntPtr]$x[1], $buf, $buf.Length, [ref]$n)
            if ((($buf | % { $_.ToString('x2') }) -join ' ') -ne $x[2]) { "{0:x8} unexpected bytes {1}, not patched" -f $x[1], (($buf | % { $_.ToString('x2') }) -join ' ') | Out-File $log -Append; $done[$x[1]] = 1; continue }
            $old = 0; [void][Mem]::VirtualProtectEx($h, [IntPtr]$x[1], $new.Length, 0x40, [ref]$old)
            $ok = [Mem]::WriteProcessMemory($h, [IntPtr]$x[1], $new, $new.Length, [ref]$n)
            [void][Mem]::VirtualProtectEx($h, [IntPtr]$x[1], $new.Length, $old, [ref]$old)
            [void][Mem]::FlushInstructionCache($h, [IntPtr]$x[1], $new.Length)
            "{0:HH:mm:ss} {1:x8} patched={2} {3}" -f (Get-Date), $x[1], $ok, $x[4] | Out-File $log -Append
            $done[$x[1]] = 1
        }
    }
    Start-Sleep -Milliseconds 500
}
