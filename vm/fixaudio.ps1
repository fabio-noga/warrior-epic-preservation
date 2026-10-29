# Sandbox-only workaround: the game's sound init calls winmm!midiOutGetNumDevs, which on current Windows goes
# through wdmaud2.drv (Windows MIDI Services) -> RPC to the midisrv service, and hangs forever if that service
# isn't answering. Try to start midisrv; if it won't run, point the MIDI driver entries back to classic wdmaud.drv.
# Only ever run inside the disposable sandbox/VM. Writes a report to out\fixaudio.txt.
$log = Join-Path $PSScriptRoot 'out\fixaudio.txt'
function Note($m) { $m; Add-Content -Path $log -Value $m }
Set-Content -Path $log -Value "fixaudio $(Get-Date)"
$svc = Get-Service midisrv -ErrorAction SilentlyContinue
Note "midisrv before: $(if ($svc) { $svc.Status } else { 'not installed' })"
if ($svc -and $svc.Status -ne 'Running') {
    try { Start-Service midisrv -ErrorAction Stop; Start-Sleep 2 } catch { Note "start failed: $($_.Exception.Message)" }
    $svc.Refresh(); Note "midisrv after start: $($svc.Status)"
}
if (-not $svc -or $svc.Status -ne 'Running') {
    foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Drivers32',
                   'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Drivers32') {
        $p = Get-ItemProperty $k -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($n in $p.PSObject.Properties.Name | Where-Object { $_ -like 'midi*' }) {
            $v = $p.$n
            Note "$k $n = $v"
            if ($v -like '*wdmaud2*') { Set-ItemProperty $k $n 'wdmaud.drv'; Note "  -> wdmaud.drv" }
        }
    }
}
