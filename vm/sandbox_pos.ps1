# Host-side helper (runs on your PC, only moves a window): remembers where the Windows Sandbox window goes.
#   save     record the current position/size/maximized state of the open sandbox window -> sandbox_pos.json
#   restore  wait for the sandbox window and put it there, only when 2+ monitors are connected
#   start    start a .wsb (default WarriorEpic_test1.wsb), then restore
param([ValidateSet('save', 'restore', 'start')][string]$Action = 'restore', [string]$Wsb = 'WarriorEpic_test1.wsb', [int]$WaitSeconds = 90)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class SbWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hgt, bool repaint);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    public static IntPtr Find() {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
            if (IsWindowVisible(h) && sb.ToString().StartsWith("Windows Sandbox")) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
[void][SbWin]::SetProcessDPIAware()   # real pixels, so positions match across monitors with different scaling
$file = Join-Path $PSScriptRoot 'sandbox_pos.json'

if ($Action -eq 'save') {
    $h = [SbWin]::Find()
    if ($h -eq [IntPtr]::Zero) { 'No "Windows Sandbox" window found: open the sandbox first.'; exit 1 }
    $max = [SbWin]::IsZoomed($h)
    if ($max) { [void][SbWin]::ShowWindow($h, 9); Start-Sleep -Milliseconds 300 }   # read the restored rect, then re-maximize
    $r = New-Object SbWin+R; [void][SbWin]::GetWindowRect($h, [ref]$r)
    if ($max) { [void][SbWin]::ShowWindow($h, 3) }
    [pscustomobject]@{ X = $r.L; Y = $r.T; W = $r.Rt - $r.L; H = $r.B - $r.T; Maximized = $max } | ConvertTo-Json | Set-Content $file
    "Saved: x=$($r.L) y=$($r.T) w=$($r.Rt - $r.L) h=$($r.B - $r.T) maximized=$max -> $file"
    exit 0
}

if ($Action -eq 'start') { Start-Process (Join-Path $PSScriptRoot $Wsb) }

if (-not (Test-Path $file)) { 'No saved position yet (run: sandbox_pos.cmd save).'; exit 0 }
if ([System.Windows.Forms.Screen]::AllScreens.Count -lt 2) { 'One monitor: leaving the sandbox window where Windows puts it.'; exit 0 }
$p = Get-Content $file -Raw | ConvertFrom-Json
$h = [IntPtr]::Zero
for ($i = 0; $i -lt $WaitSeconds -and $h -eq [IntPtr]::Zero; $i++) { $h = [SbWin]::Find(); if ($h -eq [IntPtr]::Zero) { Start-Sleep 1 } }
if ($h -eq [IntPtr]::Zero) { 'Sandbox window did not appear.'; exit 1 }
Start-Sleep 2   # let it finish its own initial placement first
[void][SbWin]::ShowWindow($h, 9)
[void][SbWin]::MoveWindow($h, $p.X, $p.Y, $p.W, $p.H, $true)
if ($p.Maximized) { [void][SbWin]::ShowWindow($h, 3) }   # maximize on the monitor it was moved to
"Sandbox window placed at x=$($p.X) y=$($p.Y) w=$($p.W) h=$($p.H) maximized=$($p.Maximized)"
