# Unattended UI step for auto.cmd: left-click the game window at a fraction (fx, fy) of its window rect.
param([double]$fx, [double]$fy)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class U {
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[void][U]::SetProcessDPIAware()
$p = Get-Process WEShell_TGI -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $p -or $p.MainWindowHandle -eq 0) { 'game window not found'; exit 1 }
$r = New-Object U+R
[void][U]::GetWindowRect($p.MainWindowHandle, [ref]$r)
[void][U]::SetForegroundWindow($p.MainWindowHandle); Start-Sleep -Milliseconds 500
$x = [int]($r.L + $fx * ($r.Rt - $r.L)); $y = [int]($r.T + $fy * ($r.B - $r.T))
[void][U]::SetCursorPos($x, $y); Start-Sleep -Milliseconds 300
[U]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero); Start-Sleep -Milliseconds 80; [U]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)
"clicked ($fx, $fy) -> $x,$y in window $($r.L),$($r.T)-$($r.Rt),$($r.B)"
