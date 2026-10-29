# Unattended combat probe for auto.cmd: in the dungeon, click at (fx, fy) of the client window several times (the
# Jungle Growth stands up-right of the spawn in "A Sea Dog's Treasure"), then press skill keys. Each step is logged with
# a timestamp so the wehost logs can be lined up with it.
param([double]$fx = 0.63, [double]$fy = 0.38, [int]$Clicks = 8)
. (Join-Path $PSScriptRoot 'gamepid.ps1')
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class C {
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, IntPtr e);
}
'@
[void][C]::SetProcessDPIAware()
$p = GameProcess
if (-not $p -or $p.MainWindowHandle -eq 0) { 'game window not found'; exit 1 }
$r = New-Object C+R
[void][C]::GetWindowRect($p.MainWindowHandle, [ref]$r)
$x = [int]($r.L + $fx * ($r.Rt - $r.L)); $y = [int]($r.T + $fy * ($r.B - $r.T))
# focus: a background PowerShell can't take it with SetForegroundWindow, WScript's AppActivate can (as in login.ps1);
# the game ignores in-dungeon input while its window isn't active
$w = New-Object -ComObject WScript.Shell
"$(Get-Date -f HH:mm:ss.fff) activate -> $($w.AppActivate($p.Id))"; Start-Sleep -Milliseconds 500
# the mission intro dialog ("A Sea Dog's Treasure ... OK") swallows input until dismissed
# (several pages: click OK a few times; extra clicks land on an empty dialog spot or the ground)
for ($i = 1; $i -le 4; $i++) {
    [void][C]::SetCursorPos([int]($r.L + 0.50 * ($r.Rt - $r.L)), [int]($r.T + 0.46 * ($r.B - $r.T))); Start-Sleep -Milliseconds 150
    [C]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80; [C]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
    "$(Get-Date -f HH:mm:ss.fff) clicked intro OK $i"; Start-Sleep -Milliseconds 1500
}
for ($i = 1; $i -le $Clicks; $i++) {
    [void][C]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 150
    [C]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 500; [C]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)   # held: action-game input
    "$(Get-Date -f HH:mm:ss.fff) click $i at $x,$y"
    Start-Sleep -Milliseconds 1500
}
# keys through keybd_event (hardware-like, also seen by DirectInput): W held to walk, then skill keys 1-3
function Key([byte]$vk, [byte]$scan, [int]$ms) {
    [C]::keybd_event($vk, $scan, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds $ms; [C]::keybd_event($vk, $scan, 2, [IntPtr]::Zero)
}
"$(Get-Date -f HH:mm:ss.fff) activate -> $($w.AppActivate($p.Id))"; Start-Sleep -Milliseconds 300
Key 0x57 0x11 1500; "$(Get-Date -f HH:mm:ss.fff) held W"
foreach ($k in @(@(0x31, 0x02), @(0x32, 0x03), @(0x33, 0x04))) {
    [void][C]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 200
    Key $k[0] $k[1] 200; "$(Get-Date -f HH:mm:ss.fff) key $([char]$k[0])"
    Start-Sleep -Milliseconds 2500
}
